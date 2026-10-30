import CoreMedia
import Foundation
import GliffCore
import VideoToolbox
import os

/// Reports one delivered frame's outcome to the session. Called from the
/// decoder's queue or from VideoToolbox's output thread, never the main thread.
typealias DecodeReporter = @Sendable (_ frameID: UInt64, _ outcome: DecodeOutcome) -> Void

/// Decodes a session's Single420 H.264 frames with VideoToolbox and posts
/// the pictures to a `VideoDisplay`.
///
/// One serial queue owns the `VTDecompressionSession`, the format and the
/// configuration; `handle` only enqueues, so the bridge's delivery thread
/// never waits for VideoToolbox. Decoding is asynchronous: a frame is
/// reported `decoded` or `failed` from its own output callback, as soon as
/// VideoToolbox completes it, before and independently of presentation.
/// Every delivered frame is reported exactly once.
///
/// - A configuration with `rebuild` (new generation) drains and replaces the
///   decoder; frames of older generations are reported `discarded` and their
///   late pictures are never shown. A pace-only configuration (frame rate,
///   same generation) only updates the geometry of later frames.
/// - New SPS/PPS are a material format change: the session is kept when
///   VideoToolbox accepts the new format, replaced otherwise.
/// - A failed frame loses the reference: the picture freezes on the last
///   good one, frames are `discarded` until a keyframe, and the session is
///   recreated at that keyframe. The bridge requests the keyframe from the
///   `failed` report.
final class H264Decoder: @unchecked Sendable {
    let display: VideoDisplay

    private let queue = DispatchQueue(label: "com.remi-b.gliff-mac.decoder", qos: .userInteractive)
    private let report: DecodeReporter
    private let log = Logger(subsystem: "com.remi-b.gliff-mac", category: "video")

    // Owned by `queue`.
    private var config: VideoConfig?
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var parameterSets: [Data] = []
    private var needsKeyframe = true
    private var resetSession = false
    private var closed = false

    /// Shared with output callbacks.
    private struct Shared {
        /// Bumped by every failure and decoder replacement: a picture whose
        /// frame was submitted in an older epoch is not shown.
        var epoch: UInt64 = 0
        /// A frame failed since `queue` last looked.
        var lostReference = false
    }
    private let shared = OSAllocatedUnfairLock(initialState: Shared())

    /// Tests only: runs on the decoder's queue after a frame was admitted,
    /// just before it is submitted, to interleave a failure callback there.
    var afterAdmission: (@Sendable () -> Void)?

    init(display: VideoDisplay, report: @escaping DecodeReporter) {
        self.display = display
        self.report = report
    }

    /// Takes a configuration or frame from the session, in wire order.
    func handle(_ item: VideoItem) {
        queue.async { [self] in
            switch item {
            case .config(let config): apply(config)
            case .frame(let frame): decode(frame)
            }
        }
    }

    /// Ends decoding: waits for frames still in VideoToolbox (each is
    /// reported), releases the session and the pictures. Later frames are
    /// reported `discarded`. Idempotent.
    func invalidate() {
        queue.async { [self] in close() }
    }

    /// `invalidate`, waiting until it is done. Not on the decoder's queue.
    func invalidateAndWait() {
        queue.sync { close() }
    }

    /// Waits until every frame handed over so far has been reported.
    func waitUntilIdle() {
        queue.sync {
            if let session { VTDecompressionSessionWaitForAsynchronousFrames(session) }
        }
    }

    // MARK: Queue-confined

    private func apply(_ new: VideoConfig) {
        guard !closed else { return }
        if new.rebuild || config.map({ $0.generation != new.generation }) ?? true {
            replaceSession(keepFormat: false)
            needsKeyframe = true
        }
        config = new
    }

    private func decode(_ frame: EncodedFrame) {
        guard !closed, let config, frame.generation == config.generation else {
            return discard(frame)
        }
        if shared.withLock({ state in defer { state.lostReference = false }; return state.lostReference }) {
            needsKeyframe = true
            resetSession = true
        }
        let unit: AccessUnit
        do {
            unit = try AccessUnit(annexB: frame.main)
        } catch {
            log.error("frame \(frame.frameId) is not valid Annex B: \(String(describing: error), privacy: .public)")
            return fail(frame, status: nil)
        }
        if needsKeyframe, !(frame.keyframe && unit.hasIDR) {
            return discard(frame)
        }
        if !unit.sps.isEmpty || !unit.pps.isEmpty {
            let status = adopt(parameterSets: unit.sps + unit.pps)
            guard status == noErr else { return fail(frame, status: status) }
        }
        if resetSession, frame.keyframe {
            replaceSession(keepFormat: true)
        }
        guard let format else { return fail(frame, status: kVTParameterErr) }
        if session == nil {
            let status = createSession(format)
            guard status == noErr else { return fail(frame, status: status) }
        }
        guard let session else { return fail(frame, status: kVTInvalidSessionErr) }
        var sample: CMSampleBuffer?
        let status = makeSample(unit.sample, format: format, pts: frame.ptsUs, &sample)
        guard status == noErr, let sample else { return fail(frame, status: status) }
        afterAdmission?()
        submit(frame, sample: sample, session: session, geometry: FrameGeometry(config))
    }

    private func submit(
        _ frame: EncodedFrame, sample: CMSampleBuffer, session: VTDecompressionSession,
        geometry: FrameGeometry
    ) {
        // A frame may fail in VideoToolbox since this one was admitted: look
        // again, in the same lock that gives this frame its epoch, so a
        // predicted frame decoded from a lost reference is never shown.
        let (epoch, lost) = shared.withLock { state in
            defer { state.lostReference = false }
            return (state.epoch, state.lostReference)
        }
        if lost {
            needsKeyframe = true
            resetSession = true
            if !frame.keyframe { return discard(frame) }
        }
        let once = ReportOnce()
        let (id, generation, pts, keyframe) = (frame.frameId, frame.generation, frame.ptsUs, frame.keyframe)
        var info = VTDecodeInfoFlags()
        let status = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sample, flags: [._EnableAsynchronousDecompression], infoFlagsOut: &info
        ) { [self] status, flags, image, _, _ in
            once.run {
                completed(
                    id, status: status, flags: flags, image: image, epoch: epoch, keyframe: keyframe,
                    makeFrame: { image in
                        DecodedFrame(
                            pixelBuffer: image, geometry: geometry, color: ColorConversion(image),
                            generation: generation, frameID: id, ptsMicros: pts)
                    })
            }
        }
        if status != noErr {
            once.run { failed(id, status: status) }
        } else if keyframe {
            needsKeyframe = false
            resetSession = false
        }
    }

    /// The output callback, on VideoToolbox's thread: report first, then show.
    private func completed(
        _ id: UInt64, status: OSStatus, flags: VTDecodeInfoFlags, image: CVImageBuffer?, epoch: UInt64,
        keyframe: Bool, makeFrame: (CVPixelBuffer) -> DecodedFrame
    ) {
        guard status == noErr else { return failed(id, status: status) }
        report(id, .decoded)
        let current = shared.withLock { $0.epoch } == epoch
        display.update {
            $0.decoded += 1
            if current, keyframe { $0.recovering = false }
        }
        // A frame VideoToolbox dropped has no picture; it still decoded.
        guard current, let image, !flags.contains(.frameDropped) else { return }
        display.post(makeFrame(image))
    }

    /// A frame failed: reported, and the reference counts as lost. Internal
    /// for tests that interleave a failure callback.
    func failed(_ id: UInt64, status: OSStatus) {
        shared.withLock {
            $0.epoch += 1
            $0.lostReference = true
        }
        report(id, .failed)
        display.update {
            $0.failed += 1
            $0.recovering = true
            $0.lastError = status
        }
        log.error("frame \(id) failed to decode: \(status)")
    }

    private func fail(_ frame: EncodedFrame, status: OSStatus?) {
        failed(frame.frameId, status: status ?? kVTVideoDecoderBadDataErr)
    }

    private func discard(_ frame: EncodedFrame) {
        report(frame.frameId, .discarded)
        display.update { $0.discarded += 1 }
    }

    /// Makes `sets` the format of the next frames. Keeps the session when
    /// VideoToolbox can decode the new format with it.
    private func adopt(parameterSets sets: [Data]) -> OSStatus {
        guard sets != parameterSets || format == nil else { return noErr }
        var new: CMFormatDescription?
        let status = Self.makeFormat(sets, &new)
        guard status == noErr, let new else { return status == noErr ? kVTParameterErr : status }
        if let session, !VTDecompressionSessionCanAcceptFormatDescription(session, formatDescription: new) {
            replaceSession(keepFormat: false)
        }
        format = new
        parameterSets = sets
        return noErr
    }

    private func createSession(_ format: CMVideoFormatDescription) -> OSStatus {
        let decoder = [kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true] as CFDictionary
        let output = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [String: Any](),
        ] as CFDictionary
        var created: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault, formatDescription: format, decoderSpecification: decoder,
            imageBufferAttributes: output, outputCallback: nil, decompressionSessionOut: &created)
        guard status == noErr, let created else { return status == noErr ? kVTInvalidSessionErr : status }
        VTSessionSetProperty(created, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        // A copied (+1) CFBoolean, released with the variable.
        var hardware: CFBoolean?
        withUnsafeMutablePointer(to: &hardware) {
            _ = VTSessionCopyProperty(
                created, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
                allocator: kCFAllocatorDefault, valueOut: $0)
        }
        let accelerated = hardware.map { CFBooleanGetValue($0) } ?? false
        session = created
        display.update {
            $0.decoderSessions += 1
            $0.hardwareAccelerated = accelerated
        }
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        log.info("decoder session \(dimensions.width)x\(dimensions.height), hardware \(accelerated)")
        return noErr
    }

    /// Drains and releases the session. Pictures completed while draining
    /// are still valid and shown; anything later is not.
    private func replaceSession(keepFormat: Bool) {
        if let session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
        }
        shared.withLock { $0.epoch += 1 }
        session = nil
        if !keepFormat {
            format = nil
            parameterSets = []
        }
    }

    private func close() {
        guard !closed else { return }
        closed = true
        replaceSession(keepFormat: false)
        config = nil
        display.clear()
    }

    private static func makeFormat(_ sets: [Data], _ format: inout CMFormatDescription?) -> OSStatus {
        // Parameter sets live in `blob`; the pointers below stay valid while it does.
        let blob = sets.reduce(into: Data()) { $0.append($1) }
        let sizes = sets.map(\.count)
        guard sets.count >= 2, !sizes.contains(0) else { return kVTParameterErr }
        return blob.withUnsafeBytes { raw -> OSStatus in
            let base = raw.bindMemory(to: UInt8.self).baseAddress!
            var offset = 0
            let pointers = sizes.map { size -> UnsafePointer<UInt8> in
                defer { offset += size }
                return base + offset
            }
            return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: sets.count, parameterSetPointers: pointers,
                parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &format)
        }
    }

    private func makeSample(
        _ bytes: Data, format: CMVideoFormatDescription, pts: UInt64, _ sample: inout CMSampleBuffer?
    ) -> OSStatus {
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: bytes.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        guard status == noErr, let block else { return status }
        status = bytes.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(
                with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes.count)
        }
        guard status == noErr else { return status }
        var timing = CMSampleTimingInfo(
            duration: .invalid, presentationTimeStamp: CMTime(value: Int64(clamping: pts), timescale: 1_000_000),
            decodeTimeStamp: .invalid)
        var size = bytes.count
        return CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
            sampleSizeArray: &size, sampleBufferOut: &sample)
    }
}

/// Runs its body at most once, from whichever thread gets there first: a
/// frame's output callback, or the failed submission that may replace it.
private final class ReportOnce: Sendable {
    private let done = OSAllocatedUnfairLock(initialState: false)

    func run(_ body: () -> Void) {
        let first = done.withLock { done in
            defer { done = true }
            return !done
        }
        if first { body() }
    }
}
