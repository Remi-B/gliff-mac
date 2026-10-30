import CoreVideo
import CryptoKit
import Foundation
import GliffCore
import os
@testable import GliffMac

/// The committed contract fixtures (`tests/fixtures/streams`).
enum VideoFixtures {
    static func stream(_ name: String) throws -> Data {
        try Data(contentsOf: root.appending(path: "tests/fixtures/streams/\(name).gliffstream"))
    }

    /// `decoded_bgra_sha256` per frame id: upstream's OpenH264 decode and
    /// fixed-point conversion of every frame.
    static func referenceHashes(_ name: String) throws -> [UInt64: String] {
        let data = try Data(contentsOf: root.appending(path: "tests/fixtures/streams/\(name).json"))
        let manifest = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var hashes: [UInt64: String] = [:]
        for frame in manifest["frames"] as! [[String: Any]] {
            hashes[(frame["frame_id"] as! NSNumber).uint64Value] = frame["decoded_bgra_sha256"] as? String
        }
        return hashes
    }

    /// The configurations and frames a recorded stream delivers through the
    /// real bridge, in wire order. Each frame is reported decoded at once.
    static func items(_ name: String) async throws -> [VideoItem] {
        let session = try GliffSession(
            target: .replay(stream: try stream(name)), options: SessionOptions(chroma: [.single420]))
        let collected = OSAllocatedUnfairLock(initialState: (items: [VideoItem](), ended: false))
        let relay = SessionRelay(
            video: { [weak session] item in
                collected.withLock { $0.items.append(item) }
                if case .frame(let frame) = item {
                    try? session?.reportDecode(frameId: frame.frameId, outcome: .decoded)
                }
            },
            events: { event in
                if case .ended = event { collected.withLock { $0.ended = true } }
            })
        try session.start(delegate: relay)
        let deadline = ContinuousClock.now + .seconds(10)
        while !collected.withLock({ $0.ended }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        return collected.withLock { $0.items }
    }

    // GliffMacTests/VideoFixtures.swift → repository root.
    private static var root: URL {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }
        return root
    }
}

extension VideoItem {
    var frame: EncodedFrame? {
        if case .frame(let frame) = self { return frame }
        return nil
    }

    var config: VideoConfig? {
        if case .config(let config) = self { return config }
        return nil
    }
}

/// Upstream's reference conversion (`gliff-sw` `convert::i420_to_bgra`,
/// scalar), ported to read a biplanar 4:2:0 buffer: BGRA bytes.
func referenceBGRA(_ buffer: CVPixelBuffer, width: Int, height: Int) -> [UInt8] {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
    let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!.assumingMemoryBound(to: UInt8.self)
    let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
    let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
    func clamp(_ v: Int32) -> UInt8 { UInt8(max(0, min(255, v))) }
    var out = [UInt8](repeating: 0, count: width * height * 4)
    for row in 0..<height {
        for col in 0..<width {
            let y = Int32(luma[row * lumaStride + col]) - 16
            let c = (row / 2) * chromaStride + (col / 2) * 2
            let cb = Int32(chroma[c]) - 128
            let cr = Int32(chroma[c + 1]) - 128
            let r = (9539 * y + 14686 * cr + 4096) >> 13
            let g = (9539 * y - 1747 * cb - 4366 * cr + 4096) >> 13
            let b = (9539 * y + 17305 * cb + 4096) >> 13
            let i = (row * width + col) * 4
            out[i] = clamp(b)
            out[i + 1] = clamp(g)
            out[i + 2] = clamp(r)
            out[i + 3] = 255
        }
    }
    return out
}

func sha256(_ bytes: [UInt8]) -> String {
    SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
}

/// Records decode reports, from any thread.
final class ReportLog: Sendable {
    private let reports = OSAllocatedUnfairLock(initialState: [(UInt64, DecodeOutcome)]())

    var reporter: DecodeReporter {
        { [reports] id, outcome in reports.withLock { $0.append((id, outcome)) } }
    }

    var all: [(id: UInt64, outcome: DecodeOutcome)] { reports.withLock { $0.map { ($0.0, $0.1) } } }

    func outcome(of id: UInt64) -> [DecodeOutcome] { all.filter { $0.id == id }.map(\.outcome) }
}
