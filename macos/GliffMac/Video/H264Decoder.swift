import CoreMedia
import Foundation
import GliffCore
import VideoToolbox
import os

/// Reports one delivered frame's outcome to the session. Called from the
/// decoder's queue or from VideoToolbox's output thread, never the main thread.
typealias DecodeReporter = @Sendable (_ frameID: UInt64, _ outcome: DecodeOutcome) -> Void

/// Decodes a session's H.264 frames with VideoToolbox and posts the pictures
/// to a `VideoDisplay`: Single420 (one stream) and Dual420 (a main and an
/// auxiliary stream, each an ordinary 4:2:0 H.264 stream with its own
/// `VTDecompressionSession`, recombined to 4:4:4 by `VideoRenderer`).
///
/// One serial queue owns the sessions, the formats and the configuration;
/// `handle` only enqueues, so the bridge's delivery thread never waits for
/// VideoToolbox. Decoding is asynchronous: each frame becomes a `FrameJob`
/// that its output callbacks complete. A frame is reported `decoded` once
/// every half decoded, `failed` as soon as either half fails or when a half
/// is still missing after `completionTimeout`, from whichever thread settles
/// it, before and independently of presentation. Every delivered frame is
/// reported exactly once.
///
/// - A configuration with `rebuild` (new generation) or another chroma mode
///   drains and replaces the decoders; frames of older generations are
///   reported `discarded` and their late pictures are never shown. A
///   pace-only configuration (frame rate, same generation) only updates the
///   geometry of later frames.
/// - New SPS/PPS are a material format change: a session is kept when
///   VideoToolbox accepts the new format, replaced otherwise.
/// - A failed frame loses the reference: the picture freezes on the last
///   good one, frames are `discarded` until a keyframe (an IDR in main and,
///   for Dual420, in aux), and the sessions are recreated at that keyframe.
///   The bridge requests the keyframe from the `failed` report.
final class H264Decoder: @unchecked Sendable {
    let display: VideoDisplay
    /// A frame with a half still inside VideoToolbox after this long fails:
    /// a lost callback becomes a keyframe request, well before the bridge's
    /// 15-second stall limit ends the session.
    let completionTimeout: Duration
    /// Frames inside VideoToolbox at once. The bridge's in-flight budget
    /// (at most 64 frames) keeps below it; past it, the oldest frame fails.
    static let maxPending = 64

    private let queue = DispatchQueue(label: "com.remi-b.gliff-mac.decoder", qos: .userInteractive)
    private let pendingLimit: Int
    private let report: DecodeReporter
    private let log = Logger(subsystem: "com.remi-b.gliff-mac", category: "video")

    // Owned by `queue`.
    private var config: VideoConfig?
    private let main = StreamDecoder(.main)
    private let aux = StreamDecoder(.aux)
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
        /// A successful newer IDR replaces older reference dependencies even
        /// when the configuration generation did not change.
        var latestIDR: UInt64?
        /// Frames inside VideoToolbox, by frame ID.
        var jobs: [UInt64: FrameJob] = [:]
        /// Tests only: drop the aux output callbacks, as if VideoToolbox
        /// never returned them.
        var ignoreAuxOutput = false
    }
    private let shared = OSAllocatedUnfairLock(initialState: Shared())

    /// Tests only: runs on the decoder's queue after a frame was admitted,
    /// just before it is submitted, to interleave a failure callback there.
    var afterAdmission: (@Sendable () -> Void)?
    var beforePublication: (@Sendable () -> Void)?

    init(display: VideoDisplay, completionTimeout: Duration = .seconds(3), pendingLimit: Int = maxPending, report: @escaping DecodeReporter) {
        self.display = display
        self.pendingLimit = pendingLimit
        precondition(pendingLimit > 0)
        self.completionTimeout = completionTimeout
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
    /// reported), releases the sessions and the pictures. Later frames are
    /// reported `discarded`. Idempotent.
    func invalidate() {
        queue.async { [self] in close() }
    }

    /// `invalidate`, waiting until it is done. Not on the decoder's queue.
    func invalidateAndWait() {
        queue.sync { close() }
    }

    /// Waits until VideoToolbox returned every frame handed over so far.
    /// A frame missing a half settles later, at its deadline.
    func waitUntilIdle() {
        queue.sync {
            main.waitForFrames()
            aux.waitForFrames()
        }
    }

    /// Tests only: VideoToolbox's aux output callbacks are dropped.
    func ignoreAuxOutput(_ ignore: Bool) {
        shared.withLock { $0.ignoreAuxOutput = ignore }
    }

    /// Frames inside VideoToolbox now.
    var pendingCount: Int { shared.withLock { $0.jobs.count } }

    // MARK: Queue-confined

    private func apply(_ new: VideoConfig) {
        guard !closed else { return }
        if new.rebuild || config.map({ $0.generation != new.generation || $0.chroma != new.chroma }) ?? true {
            replaceSessions(keepFormat: false)
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
        let dual = config.chroma == .dual420
        let mainUnit: AccessUnit
        var auxUnit: AccessUnit?
        do {
            mainUnit = try AccessUnit(annexB: frame.main)
            switch (dual, frame.aux) {
            case (true, let bytes?): auxUnit = try AccessUnit(annexB: bytes)
            case (false, nil): break
            case (true, nil), (false, _?):
                log.error("frame \(frame.frameId): auxiliary stream does not match the chroma mode")
                return fail(frame, status: nil)
            }
        } catch {
            log.error("frame \(frame.frameId) is not valid Annex B: \(String(describing: error), privacy: .public)")
            return fail(frame, status: nil)
        }
        let idr = mainUnit.hasIDR && (auxUnit?.hasIDR ?? true)
        if needsKeyframe, !(frame.keyframe && idr) {
            // A keyframe pair whose halves are not both IDR cannot restart
            // decoding: fail it, so the bridge asks for another keyframe.
            if frame.keyframe, mainUnit.hasIDR { return fail(frame, status: nil) }
            return discard(frame)
        }
        var units: [(StreamDecoder, AccessUnit)] = [(main, mainUnit)]
        if let auxUnit { units.append((aux, auxUnit)) }
        for (stream, unit) in units where !unit.sps.isEmpty || !unit.pps.isEmpty {
            let status = adopt(unit.sps + unit.pps, in: stream)
            guard status == noErr else { return fail(frame, status: status) }
        }
        if resetSession, frame.keyframe {
            replaceSessions(keepFormat: true)
        }
        var halves: [(FrameJob.Half, VTDecompressionSession, CMSampleBuffer)] = []
        for (stream, unit) in units {
            guard let format = stream.format else { return fail(frame, status: kVTParameterErr) }
            if stream.session == nil {
                let status = createSession(stream, format)
                guard status == noErr else { return fail(frame, status: status) }
            }
            guard let session = stream.session else { return fail(frame, status: kVTInvalidSessionErr) }
            var sample: CMSampleBuffer?
            let status = Self.makeSample(unit.sample, format: format, pts: frame.ptsUs, &sample)
            guard status == noErr, let sample else { return fail(frame, status: status) }
            halves.append((stream.half, session, sample))
        }
        afterAdmission?()
        submit(frame, halves: halves, geometry: FrameGeometry(config), format: main.format, dual: dual)
    }

    private func submit(
        _ frame: EncodedFrame, halves: [(FrameJob.Half, VTDecompressionSession, CMSampleBuffer)],
        geometry: FrameGeometry, format: CMFormatDescription?, dual: Bool
    ) {
        // Make room before admitting another sample. Losing a pending frame
        // invalidates the reference chain, so this sample must not be submitted.
        let oldest = shared.withLock { state -> FrameJob? in
            guard state.jobs.count >= pendingLimit, let id = state.jobs.keys.min() else { return nil }
            return state.jobs.removeValue(forKey: id)
        }
        if let oldest, let outcome = oldest.expire() {
            settle(oldest, outcome)
            needsKeyframe = true
            resetSession = true
            return discard(frame)
        }
        let admission = shared.withLock { state -> (FrameJob?, Int) in
            if state.lostReference {
                state.lostReference = false
                return (nil, state.jobs.count)
            }
            let job = FrameJob(
                frameID: frame.frameId, generation: frame.generation, ptsMicros: frame.ptsUs, keyframe: frame.keyframe,
                geometry: geometry, epoch: state.epoch, dual: dual)
            job.format = format
            state.jobs[job.frameID] = job
            return (job, state.jobs.count)
        }
        guard let job = admission.0 else {
            needsKeyframe = true
            resetSession = true
            return discard(frame)
        }
        display.update { $0.maxPending = max($0.maxPending, admission.1) }
        var submitted = true
        for (half, session, sample) in halves {
            var info = VTDecodeInfoFlags()
            let status = VTDecompressionSessionDecodeFrame(
                session, sampleBuffer: sample, flags: [._EnableAsynchronousDecompression], infoFlagsOut: &info
            ) { [self] status, flags, image, _, _ in
                if half == .aux, shared.withLock({ $0.ignoreAuxOutput }) { return }
                let result: FrameJob.Result =
                    status != noErr ? .failed(status) : .image(flags.contains(.frameDropped) ? nil : image)
                if let outcome = job.record(half, result) { settle(job, outcome) }
            }
            if status != noErr {
                // Rejected synchronously: the frame fails now, its partner
                // is not submitted, and a late callback is ignored.
                if let outcome = job.record(half, .failed(status)) { settle(job, outcome) }
                submitted = false
                break
            }
        }
        if submitted, frame.keyframe {
            needsKeyframe = false
            resetSession = false
        }
        queue.asyncAfter(deadline: .now() + completionTimeout.timeInterval) { [weak self] in
            if let outcome = job.expire() { self?.settle(job, outcome) }
        }
    }

    /// Reports a settled frame and shows its picture. Runs on VideoToolbox's
    /// thread (output callback) or the decoder's queue (synchronous
    /// rejection, deadline, overflow); `FrameJob` guarantees one call per frame.
    private func settle(_ job: FrameJob, _ outcome: FrameJob.Outcome) {
        shared.withLock { state in
            if state.jobs[job.frameID] === job { state.jobs[job.frameID] = nil }
        }
        let micros = UInt64(clamping: (ContinuousClock.now - job.submitted).microseconds)
        switch outcome {
        case .failed(let status, let half):
            failed(job.frameID, status: status, epoch: job.epoch)
            if job.dual, half != nil { display.update { $0.halfFailures += 1 } }
        case .expired(let missing):
            log.error("frame \(job.frameID): no picture from \(missing.map { "\($0)" }.joined(separator: "+"), privacy: .public) in time")
            failed(job.frameID, status: kVTVideoDecoderMalfunctionErr, epoch: job.epoch)
            display.update { $0.expired += 1 }
        case .decoded(let main, let aux):
            if job.dual, let main, let aux, !Self.isPair(main, aux, job.geometry) {
                log.error("frame \(job.frameID): main and auxiliary pictures differ in size or format")
                return failed(job.frameID, status: kVTVideoDecoderBadDataErr, epoch: job.epoch)
            }
            report(job.frameID, .decoded)
            beforePublication?()
            // Install the picture while the epoch is locked, but invoke the
            // display observer only after unlocking: observers may reenter us.
            let picture = main.flatMap { main -> DecodedFrame? in
                guard !job.dual || aux != nil else { return nil }
                return DecodedFrame(
                    pixelBuffer: main, geometry: job.geometry, color: ColorConversion(main, format: job.format),
                    generation: job.generation, frameID: job.frameID, ptsMicros: job.ptsMicros, aux: aux)
            }
            let bytes = picture.map { Self.surfaceBytes($0.pixelBuffer) + ($0.aux.map(Self.surfaceBytes) ?? 0) }
            let wake = shared.withLock { state -> (@Sendable () -> Void)? in
                let current = state.epoch == job.epoch
                if current, job.keyframe {
                    state.latestIDR = max(state.latestIDR ?? job.frameID, job.frameID)
                }
                let wake = current ? picture.flatMap { display.postDeferred($0) } : nil
                display.update {
                    $0.decoded += 1
                    if job.dual { $0.pairsDecoded += 1 }
                    $0.completionMicrosTotal += micros
                    $0.completionMicrosMax = max($0.completionMicrosMax, micros)
                    if current, job.keyframe { $0.recovering = false }
                    if current, let bytes {
                        $0.pictureBytes = bytes
                        $0.fullChroma = job.dual
                    }
                }
                return wake
            }
            wake?()
        }
    }

    /// A frame failed: reported, and the reference counts as lost. Internal
    /// for tests that interleave a failure callback.
    func failed(_ id: UInt64, status: OSStatus, epoch: UInt64? = nil) {
        shared.withLock { state in
            let current = (epoch == nil || epoch == state.epoch)
                && (state.latestIDR.map { id >= $0 } ?? true)
            if current {
                state.epoch += 1
                state.lostReference = true
            }
            display.update {
                $0.failed += 1
                if current {
                    $0.recovering = true
                    $0.lastError = status
                }
            }
        }
        report(id, .failed)
        log.error("frame \(id) failed to decode: \(status)")
    }

    private func fail(_ frame: EncodedFrame, status: OSStatus?) {
        failed(frame.frameId, status: status ?? kVTVideoDecoderBadDataErr)
    }

    private func discard(_ frame: EncodedFrame) {
        discard(frame.frameId)
    }

    private func discard(_ id: UInt64) {
        report(id, .discarded)
        display.update { $0.discarded += 1 }
    }

    /// Makes `sets` the format of the stream's next frames. Keeps its session
    /// when VideoToolbox can decode the new format with it.
    private func adopt(_ sets: [Data], in stream: StreamDecoder) -> OSStatus {
        guard sets != stream.parameterSets || stream.format == nil else { return noErr }
        var new: CMFormatDescription?
        let status = Self.makeFormat(sets, &new)
        guard status == noErr, let new else { return status == noErr ? kVTParameterErr : status }
        if let session = stream.session, !VTDecompressionSessionCanAcceptFormatDescription(session, formatDescription: new) {
            stream.replace(keepFormat: false)
            shared.withLock { $0.epoch += 1 }
        }
        stream.format = new
        stream.parameterSets = sets
        return noErr
    }

    private func createSession(_ stream: StreamDecoder, _ format: CMVideoFormatDescription) -> OSStatus {
        let status = stream.create(format)
        guard status == noErr else { return status }
        // Dual420: hardware only when both sessions use it.
        let dual = config?.chroma == .dual420
        let accelerated = main.hardware && (!dual || aux.session == nil || aux.hardware)
        display.update {
            $0.decoderSessions += 1
            $0.hardwareAccelerated = accelerated
        }
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        log.info("\(stream.half == .main ? "main" : "aux", privacy: .public) decoder session \(dimensions.width)x\(dimensions.height), hardware \(stream.hardware)")
        return noErr
    }

    /// Drains and releases both sessions. Pictures completed while draining
    /// are still valid and shown; anything later is not.
    private func replaceSessions(keepFormat: Bool) {
        main.replace(keepFormat: keepFormat)
        aux.replace(keepFormat: keepFormat)
        shared.withLock { $0.epoch += 1 }
    }

    private func close() {
        guard !closed else { return }
        closed = true
        replaceSessions(keepFormat: false)
        // Every callback has run: what is still missing a half never comes.
        let left = shared.withLock { state in
            defer { state.jobs = [:] }
            return state.jobs.values.sorted { $0.frameID < $1.frameID }
        }
        for job in left where job.expire() != nil {
            discard(job.frameID)
        }
        config = nil
        display.clear()
    }

    /// Main and aux pictures recombine only when they have the same layout
    /// and cover the configured size.
    private static func isPair(_ main: CVPixelBuffer, _ aux: CVPixelBuffer, _ geometry: FrameGeometry) -> Bool {
        let (width, height) = (CVPixelBufferGetWidth(main), CVPixelBufferGetHeight(main))
        return CVPixelBufferGetPixelFormatType(main) == CVPixelBufferGetPixelFormatType(aux)
            && CVPixelBufferGetPlaneCount(main) == 2 && CVPixelBufferGetPlaneCount(aux) == 2
            && (width, height) == (CVPixelBufferGetWidth(aux), CVPixelBufferGetHeight(aux))
            && width >= geometry.width & ~1 && height >= geometry.height & ~1
    }

    private static func surfaceBytes(_ buffer: CVPixelBuffer) -> Int {
        guard let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() else {
            return CVPixelBufferGetDataSize(buffer)
        }
        return IOSurfaceGetAllocSize(surface)
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

    private static func makeSample(
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

/// One H.264 stream's VideoToolbox session and format: main, or Dual420's
/// aux. Confined to the decoder's queue.
private final class StreamDecoder {
    let half: FrameJob.Half
    var session: VTDecompressionSession?
    var format: CMVideoFormatDescription?
    var parameterSets: [Data] = []
    /// Whether the current session uses the media engine.
    private(set) var hardware = false

    init(_ half: FrameJob.Half) { self.half = half }

    func create(_ format: CMVideoFormatDescription) -> OSStatus {
        let decoder = [kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true] as CFDictionary
        // Both streams decode to the same 8-bit video-range biplanar layout,
        // which is what the encoder signals: no range conversion touches the
        // auxiliary stream's samples, which are chroma carried as luma.
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
        var accelerated: CFBoolean?
        withUnsafeMutablePointer(to: &accelerated) {
            _ = VTSessionCopyProperty(
                created, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
                allocator: kCFAllocatorDefault, valueOut: $0)
        }
        hardware = accelerated.map { CFBooleanGetValue($0) } ?? false
        session = created
        return noErr
    }

    func waitForFrames() {
        if let session { VTDecompressionSessionWaitForAsynchronousFrames(session) }
    }

    /// Drains and releases the session: every frame inside it is called back.
    func replace(keepFormat: Bool) {
        if let session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
        hardware = false
        if !keepFormat {
            format = nil
            parameterSets = []
        }
    }
}

extension Duration {
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }

    var microseconds: Int64 {
        let (seconds, attoseconds) = components
        return seconds * 1_000_000 + attoseconds / 1_000_000_000_000
    }
}
