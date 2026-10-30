import AppKit
import CoreVideo
import Foundation
import GliffCore
import QuartzCore
import Testing
import VideoToolbox
import os
@testable import GliffMac

/// Concatenates byte runs; explicit types keep Swift 6.1's type checker fast.
private func bytes(_ parts: [UInt8]...) -> Data { Data(parts.joined()) }

@Suite struct AccessUnitTests {
    static let sps: [UInt8] = [0x67, 0x42, 0xc0, 0x1e]
    static let pps: [UInt8] = [0x68, 0xce, 0x3c, 0x80]
    static let idr: [UInt8] = [0x65, 0x88, 0x84, 0x21]

    @Test func splitsParameterSetsAndLengthPrefixesTheRest() throws {
        // 4-byte start codes, a 3-byte one, and an access unit delimiter.
        let stream = bytes(
            [0, 0, 0, 1, 0x09, 0xf0], [0, 0, 0, 1], Self.sps, [0, 0, 1], Self.pps,
            [0, 0, 0, 1], Self.idr, [0, 0, 1, 0x06, 0x05, 0x01])
        let unit = try AccessUnit(annexB: stream)
        #expect(unit.sps == [Data(Self.sps)])
        #expect(unit.pps == [Data(Self.pps)])
        #expect(unit.nalTypes == [9, 7, 8, 5, 6])
        #expect(unit.hasIDR)
        #expect(unit.sample == bytes([0, 0, 0, 4], Self.idr, [0, 0, 0, 3, 0x06, 0x05, 0x01]))
    }

    @Test func rejectsWhatIsNotAnAccessUnit() {
        #expect(throws: AccessUnit.ParseError.noStartCode) { try AccessUnit(annexB: Data([0x65, 1, 2])) }
        #expect(throws: AccessUnit.ParseError.leadingBytes(2)) {
            try AccessUnit(annexB: bytes([7, 7, 0, 0, 1], Self.idr))
        }
        #expect(throws: AccessUnit.ParseError.emptyUnit(at: 3)) {
            try AccessUnit(annexB: bytes([0, 0, 1, 0, 0, 1], Self.idr))
        }
        #expect(throws: AccessUnit.ParseError.forbiddenBit(at: 3)) {
            try AccessUnit(annexB: Data([0, 0, 1, 0xe5, 1]))
        }
        // A frame cut after its parameter sets has nothing to decode.
        #expect(throws: AccessUnit.ParseError.noSlice) {
            try AccessUnit(annexB: bytes([0, 0, 0, 1], Self.sps, [0, 0, 0, 1], Self.pps))
        }
        #expect(throws: AccessUnit.ParseError.noStartCode) { try AccessUnit(annexB: Data()) }
    }
}

@Suite struct FrameGeometryTests {
    @Test func fitsWithLetterboxingOnWholePixels() {
        let stream = FrameGeometry(width: 1920, height: 1080)
        // A 1000×600-point window on a 2× Retina display.
        #expect(stream.fit(in: CGSize(width: 2000, height: 1200)) == CGRect(x: 0, y: 37, width: 2000, height: 1125))
        // Taller than wide: pillarbox instead.
        #expect(stream.fit(in: CGSize(width: 1000, height: 1000)) == CGRect(x: 0, y: 218, width: 1000, height: 563))
        #expect(stream.fit(in: CGSize(width: 3840, height: 2160)) == CGRect(x: 0, y: 0, width: 3840, height: 2160))
    }

    @Test func snapsToOneToOneWhenTheWindowMatches() {
        let stream = FrameGeometry(width: 1920, height: 1080)
        #expect(stream.fit(in: CGSize(width: 1920, height: 1090)) == CGRect(x: 0, y: 5, width: 1920, height: 1080))
        #expect(stream.fit(in: CGSize(width: 1915, height: 1080)) == CGRect(x: -3, y: 0, width: 1920, height: 1080))
        #expect(stream.fit(in: CGSize(width: 1900, height: 1080)).width == 1900)
    }

    @Test func emptySurfacesAndStreamsDrawNothing() {
        #expect(FrameGeometry(width: 1920, height: 1080).fit(in: .zero) == .zero)
        #expect(FrameGeometry(width: 0, height: 1080).fit(in: CGSize(width: 10, height: 10)) == .zero)
    }

    @Test func referenceColourIsUpstreamFixedPoint() {
        let k = ColorConversion.reference.coefficients
        #expect(k == .init(yOffset: 16, ky: 9539, krv: 14686, kgu: -1747, kgv: -4366, kbu: 17305))
        // The derived tables agree with the reference within rounding.
        let derived = ColorConversion(matrix: .bt601, fullRange: true).coefficients
        #expect(derived.ky == 8192 && derived.yOffset == 0 && derived.krv == 11485)
    }
}

/// VideoToolbox on the committed fixtures, through the real bridge's
/// ordering, compared with upstream's reference decoder.
@MainActor
@Suite(.serialized) struct H264DecoderTests {
    /// Every frame decodes; the CPU port and the GPU conversion of each
    /// picture both equal upstream's reference output byte for byte.
    @Test(arguments: ["synthetic-single420", "live-cpu-single420"])
    func decodesFixturesExactlyLikeUpstream(_ name: String) async throws {
        let items = try await VideoFixtures.items(name)
        let hashes = try VideoFixtures.referenceHashes(name)
        let renderer = try #require(VideoRenderer())
        let log = ReportLog()
        let decoder = H264Decoder(display: VideoDisplay(), report: log.reporter)
        var checked = 0
        for item in items {
            decoder.handle(item)
            guard let frame = item.frame else { continue }
            decoder.waitUntilIdle()
            let picture = try #require(decoder.display.latest)
            #expect(picture.frameID == frame.frameId)
            let (width, height) = (picture.geometry.width, picture.geometry.height)
            #expect(CVPixelBufferGetWidth(picture.pixelBuffer) == width)
            #expect(CVPixelBufferGetHeight(picture.pixelBuffer) == height)
            #expect(picture.color == .reference)
            #expect(sha256(referenceBGRA(picture.pixelBuffer, width: width, height: height)) == hashes[frame.frameId])
            let rgba = try #require(renderer.convertedPixels(picture))
            var bgra = rgba
            for i in stride(from: 0, to: bgra.count, by: 4) { bgra.swapAt(i, i + 2) }
            #expect(sha256(bgra) == hashes[frame.frameId], "GPU conversion of frame \(frame.frameId)")
            checked += 1
        }
        decoder.invalidateAndWait()
        // The bridge discards frames of a replaced generation that are still
        // queued when the rebuild arrives, so a fast replay may skip a few.
        let delivered = items.compactMap(\.frame).count
        #expect(checked == delivered && delivered >= hashes.count * 3 / 4, "\(delivered) of \(hashes.count)")
        #expect(log.all.count == delivered)
        #expect(log.all.allSatisfy { $0.outcome == .decoded })
        #expect(log.all.map(\.id) == log.all.map(\.id).sorted())
        let diagnostics = decoder.display.diagnostics
        // One decoder per generation: SPS/PPS changes and rebuilds replace
        // it, the synthetic stream's pace-only update does not.
        #expect(diagnostics.decoderSessions == 2)
        #expect(diagnostics.failed == 0 && diagnostics.discarded == 0 && !diagnostics.recovering)
        #expect(diagnostics.hardwareAccelerated != nil)
    }

    @Test func aPaceOnlyConfigurationKeepsTheDecoder() async throws {
        let items = try await VideoFixtures.items("synthetic-single420")
        let decoder = H264Decoder(display: VideoDisplay(), report: ReportLog().reporter)
        let pace = try #require(items.compactMap(\.config).first { !$0.rebuild })
        let firstGeneration = items.prefix { $0.config?.generation != 2 }
        firstGeneration.forEach(decoder.handle)
        decoder.waitUntilIdle()
        #expect(decoder.display.diagnostics.decoderSessions == 1)
        #expect(pace.fpsCap == 15)
        #expect(decoder.display.diagnostics.failed == 0)
        decoder.invalidateAndWait()
    }

    @Test func aFailedFrameFreezesThePictureUntilTheNextKeyframe() async throws {
        let items = try await VideoFixtures.items("synthetic-single420")
        let frames = items.compactMap(\.frame)
        let config = try #require(items.first?.config)
        let keyframes = frames.filter(\.keyframe).map(\.frameId)
        #expect(keyframes.count >= 2)
        let log = ReportLog()
        let decoder = H264Decoder(display: VideoDisplay(), report: log.reporter)
        decoder.handle(.config(config))
        decoder.handle(.frame(frames[0]))
        decoder.handle(.frame(frames[1]))
        decoder.waitUntilIdle()
        #expect(decoder.display.latest?.frameID == 1)

        // A frame truncated before its slices fails without reaching VideoToolbox.
        var broken = frames[2]
        broken.main = Data([0, 0, 0, 1, 0x67, 0x42])
        decoder.handle(.frame(broken))
        // Predicted frames already sent are not decoded: their reference is gone.
        decoder.handle(.frame(frames[3]))
        let recovery = try #require(frames.first { $0.keyframe && $0.frameId > 3 && $0.generation == 1 })
        decoder.waitUntilIdle()
        #expect(log.outcome(of: 2) == [.failed])
        #expect(log.outcome(of: 3) == [.discarded])
        #expect(decoder.display.diagnostics.recovering)
        #expect(decoder.display.latest?.frameID == 1, "the last good picture stays")

        decoder.handle(.frame(recovery))
        decoder.waitUntilIdle()
        #expect(log.outcome(of: recovery.frameId) == [.decoded])
        #expect(decoder.display.latest?.frameID == recovery.frameId)
        let diagnostics = decoder.display.diagnostics
        #expect(!diagnostics.recovering && diagnostics.failed == 1 && diagnostics.discarded == 1)
        // The decoder session is recreated at the recovery keyframe.
        #expect(diagnostics.decoderSessions == 2)
        decoder.invalidateAndWait()
    }

    /// A failure callback landing between a predicted frame's admission and
    /// its submission: that frame is not decoded from the lost reference.
    @Test func aFailureDuringAdmissionStopsThePredictedFrame() async throws {
        let items = try await VideoFixtures.items("synthetic-single420")
        let frames = items.compactMap(\.frame)
        let log = ReportLog()
        let decoder = H264Decoder(display: VideoDisplay(), report: log.reporter)
        decoder.handle(try #require(items.first))
        decoder.handle(.frame(frames[0]))
        decoder.waitUntilIdle()
        decoder.afterAdmission = { [weak decoder] in
            decoder?.afterAdmission = nil
            decoder?.failed(999, status: kVTVideoDecoderBadDataErr)
        }
        decoder.handle(.frame(frames[1]))
        decoder.handle(.frame(frames[2]))
        decoder.waitUntilIdle()
        #expect(log.outcome(of: frames[1].frameId) == [.discarded])
        #expect(log.outcome(of: frames[2].frameId) == [.discarded])
        #expect(decoder.display.latest?.frameID == frames[0].frameId)
        #expect(decoder.display.diagnostics.recovering)
        decoder.invalidateAndWait()
    }

    @Test func truncatedAndCorruptSamplesAreReportedOnce() async throws {
        let items = try await VideoFixtures.items("live-cpu-single420")
        let frames = items.compactMap(\.frame)
        let log = ReportLog()
        let decoder = H264Decoder(display: VideoDisplay(), report: log.reporter)
        decoder.handle(try #require(items.first))
        var truncated = frames[0]
        truncated.main = truncated.main.prefix(truncated.main.count * 2 / 5)
        var corrupt = frames[0]
        corrupt.frameId = 1
        corrupt.main = bytes([UInt8](corrupt.main.prefix(64)), [UInt8](repeating: 0x5a, count: 4096))
        var garbage = frames[1]
        garbage.frameId = 2
        let noise: [UInt8] = (0..<2048).map { (i: Int) -> UInt8 in UInt8(truncatingIfNeeded: i &* 37) }
        garbage.main = bytes([0, 0, 0, 1, 0x41], noise)
        for frame in [truncated, corrupt, garbage] { decoder.handle(.frame(frame)) }
        decoder.waitUntilIdle()
        decoder.invalidateAndWait()
        for id in 0...2 as ClosedRange<UInt64> {
            #expect(log.outcome(of: id).count == 1, "frame \(id) reported once")
        }
    }

    @Test func staleGenerationsAreDiscardedAndNeverShown() async throws {
        let items = try await VideoFixtures.items("live-cpu-single420")
        let configs = items.compactMap(\.config)
        let frames = items.compactMap(\.frame)
        let log = ReportLog()
        let decoder = H264Decoder(display: VideoDisplay(), report: log.reporter)
        decoder.handle(.config(configs[0]))
        decoder.handle(.frame(frames[0]))
        decoder.handle(.config(configs[1]))
        // A frame of generation 1 arriving after the rebuild.
        decoder.handle(.frame(frames[1]))
        decoder.waitUntilIdle()
        #expect(log.outcome(of: frames[1].frameId) == [.discarded])
        // Until generation 2's keyframe, the last picture is generation 1's.
        #expect(decoder.display.latest?.generation == 1)
        let next = try #require(frames.first { $0.generation == 2 })
        decoder.handle(.frame(next))
        decoder.waitUntilIdle()
        #expect(decoder.display.latest?.generation == 2)
        #expect(decoder.display.latest?.geometry == FrameGeometry(width: 800, height: 600))
        decoder.invalidateAndWait()
    }

    /// A display nobody draws keeps one picture; decoding and reports go on.
    @Test func aSlowDisplayNeverHoldsBackDecoding() async throws {
        let items = try await VideoFixtures.items("live-cpu-single420")
        let log = ReportLog()
        let display = VideoDisplay()
        let wakes = OSAllocatedUnfairLockCounter()
        display.setObserver { wakes.increment() }
        let decoder = H264Decoder(display: display, report: log.reporter)
        items.forEach(decoder.handle)
        decoder.waitUntilIdle()
        let frames = items.compactMap(\.frame)
        #expect(log.all.count == frames.count)
        #expect(log.all.allSatisfy { $0.outcome == .decoded })
        let diagnostics = display.diagnostics
        #expect(wakes.value == 1, "one wake-up until the surface takes a picture")
        #expect(diagnostics.droppedBeforeDisplay == UInt64(frames.count - 1))
        #expect(display.take()?.frameID == frames.last?.frameId)
        // A static desktop: no new picture, the same one is drawn again.
        #expect(display.take()?.frameID == frames.last?.frameId)
        #expect(display.diagnostics.presented == 1)
        decoder.invalidateAndWait()
    }

    /// Output callbacks may complete out of order: an older picture never
    /// replaces a newer one.
    @Test func aLateOlderPictureNeverReplacesANewerOne() throws {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &buffer)
        let pixels = try #require(buffer)
        func picture(_ id: UInt64, generation: UInt32 = 1) -> DecodedFrame {
            DecodedFrame(
                pixelBuffer: pixels, geometry: FrameGeometry(width: 16, height: 16), color: .reference,
                generation: generation, frameID: id, ptsMicros: id)
        }
        let display = VideoDisplay()
        display.post(picture(5))
        display.post(picture(4))
        display.post(picture(5))
        #expect(display.take()?.frameID == 5)
        #expect(display.diagnostics.outOfOrder == 2)
        display.post(picture(6, generation: 2))
        #expect(display.take()?.frameID == 6)
        #expect(display.diagnostics.presented == 2)
    }

    /// Disconnecting with frames inside VideoToolbox: each is reported once,
    /// later ones are discarded, and the pictures are released.
    @Test func invalidatingWithWorkInFlightReportsEveryFrameOnce() async throws {
        let items = try await VideoFixtures.items("live-cpu-single420")
        let frames = items.compactMap(\.frame)
        for cut in [1, 5, 20] {
            let log = ReportLog()
            let decoder = H264Decoder(display: VideoDisplay(), report: log.reporter)
            let before = items.prefix(cut + 1)
            let handed = before.compactMap(\.frame).count
            before.forEach(decoder.handle)
            decoder.invalidate()
            items.dropFirst(cut + 1).forEach(decoder.handle)
            decoder.invalidateAndWait()
            #expect(log.all.count == frames.count, "cut \(cut)")
            #expect(Set(log.all.map(\.id)).count == frames.count)
            #expect(log.all.dropFirst(handed).allSatisfy { $0.outcome == .discarded })
            #expect(decoder.display.latest == nil)
        }
    }

    @Test func theRendererDrawsAndRedrawsAtAnySize() async throws {
        let items = try await VideoFixtures.items("synthetic-single420")
        let decoder = H264Decoder(display: VideoDisplay(), report: ReportLog().reporter)
        items.prefix(3).forEach(decoder.handle)
        decoder.waitUntilIdle()
        let renderer = try #require(VideoRenderer())
        let layer = CAMetalLayer()
        renderer.configure(layer)
        for size in [CGSize(width: 640, height: 384), CGSize(width: 333, height: 777), CGSize(width: 1, height: 1), .zero] {
            layer.drawableSize = size
            renderer.draw(decoder.display.take(), in: layer)
            renderer.draw(decoder.display.take(), in: layer)
        }
        renderer.draw(nil, in: layer)
        decoder.invalidateAndWait()
    }
}

/// The surface draws each new picture from the display's wake-up, on the
/// main thread, and redraws the last one when resized.
@MainActor
@Suite(.serialized) struct RemoteSurfaceTests {
    @Test func theSurfaceTakesEachNewPictureAndSurvivesResizes() async throws {
        let items = try await VideoFixtures.items("synthetic-single420")
        let decoder = H264Decoder(display: VideoDisplay(), report: ReportLog().reporter)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled, .resizable],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let surface = RemoteSurface.SurfaceView(frame: window.contentLayoutRect)
        window.contentView = surface
        surface.display = decoder.display
        defer {
            surface.display = nil
            window.close()
            decoder.invalidateAndWait()
        }

        decoder.handle(items[0])
        decoder.handle(items[1])
        decoder.waitUntilIdle()
        try await waitUntil { decoder.display.diagnostics.presented == 1 }
        for size in [NSSize(width: 900, height: 200), NSSize(width: 120, height: 640)] {
            window.setContentSize(size)
            surface.layoutSubtreeIfNeeded()
        }
        decoder.handle(items[2])
        decoder.waitUntilIdle()
        try await waitUntil { decoder.display.diagnostics.presented == 2 }

        // No drawable for the next picture: the surface tries again by
        // itself, although the static desktop sends nothing more.
        let attempts = OSAllocatedUnfairLockCounter()
        let renderer = try #require(surface.renderer)
        renderer.nextDrawable = { layer in
            attempts.increment()
            return attempts.value == 1 ? nil : layer.nextDrawable()
        }
        decoder.handle(items[3])
        decoder.waitUntilIdle()
        try await waitUntil { attempts.value >= 2 }
        renderer.nextDrawable = { $0.nextDrawable() }
        #expect(decoder.display.diagnostics.presented == 3)

        // Detached: the display no longer wakes this surface.
        surface.display = nil
        decoder.handle(items[4])
        decoder.waitUntilIdle()
        try await Task.sleep(for: .milliseconds(50))
        #expect(decoder.display.diagnostics.presented == 3)
    }
}

@MainActor
private func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition(), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(condition())
}

/// A thread-safe counter for observer wake-ups.
final class OSAllocatedUnfairLockCounter: Sendable {
    private let count = OSAllocatedUnfairLock(initialState: 0)
    func increment() { count.withLock { $0 += 1 } }
    var value: Int { count.withLock { $0 } }
}
