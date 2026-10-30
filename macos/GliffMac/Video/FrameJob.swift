import CoreMedia
import CoreVideo
import Foundation
import os

/// One delivered frame inside VideoToolbox: its main picture and, for
/// Dual420, its auxiliary picture, each decoded by its own session.
///
/// Each output callback captures its own job, so a half can only land in
/// the frame (ID and generation) it was submitted for: pictures are never
/// paired by arrival order. The job settles exactly once, whichever comes
/// first:
///
/// - every expected half arrived: `decoded`, with both pictures;
/// - one half failed (callback or synchronous submission): `failed` at once,
///   without waiting for the partner;
/// - the deadline passed or the decoder closed with a half still missing:
///   `failed`. A half arriving after that is ignored and its picture released.
final class FrameJob: @unchecked Sendable {
    enum Half: Sendable { case main, aux }

    /// What one VideoToolbox output callback produced.
    enum Result: @unchecked Sendable {
        /// Decoded; `image` is nil when VideoToolbox dropped the picture.
        case image(CVPixelBuffer?)
        case failed(OSStatus)
    }

    /// How the job settled. Returned once, to the caller that settled it.
    enum Outcome: @unchecked Sendable {
        case decoded(main: CVPixelBuffer?, aux: CVPixelBuffer?)
        case failed(OSStatus, half: Half?)
        case expired(missing: [Half])
    }

    let frameID: UInt64
    let generation: UInt32
    let ptsMicros: UInt64
    let keyframe: Bool
    let geometry: FrameGeometry
    /// Pictures of an older epoch are reported but not shown.
    let epoch: UInt64
    /// Whether an auxiliary half is expected (Dual420).
    let dual: Bool
    let submitted: ContinuousClock.Instant
    /// The main stream's format: its VUI decides the colour matrix. Set
    /// before submission, read once settled.
    var format: CMFormatDescription?

    private struct Parts: @unchecked Sendable {
        var main: Result?
        var aux: Result?
        var settled = false
    }
    private let parts = OSAllocatedUnfairLock(initialState: Parts())

    init(
        frameID: UInt64, generation: UInt32, ptsMicros: UInt64, keyframe: Bool, geometry: FrameGeometry,
        epoch: UInt64, dual: Bool, submitted: ContinuousClock.Instant = .now
    ) {
        self.frameID = frameID
        self.generation = generation
        self.ptsMicros = ptsMicros
        self.keyframe = keyframe
        self.geometry = geometry
        self.epoch = epoch
        self.dual = dual
        self.submitted = submitted
    }

    var isSettled: Bool { parts.withLock { $0.settled } }

    /// Records one half. Returns the outcome when this call settles the job,
    /// `nil` while the partner is still missing or when it already settled.
    func record(_ half: Half, _ result: Result) -> Outcome? {
        parts.withLock { parts -> Outcome? in
            guard !parts.settled else { return nil }
            if case .failed(let status) = result {
                parts.settled = true
                parts.main = nil
                parts.aux = nil
                return .failed(status, half: half)
            }
            switch half {
            case .main: parts.main = result
            case .aux: parts.aux = result
            }
            guard case .image(let main)? = parts.main else { return nil }
            guard dual else {
                parts.settled = true
                parts.main = nil
                return .decoded(main: main, aux: nil)
            }
            guard case .image(let aux)? = parts.aux else { return nil }
            parts.settled = true
            parts.main = nil
            parts.aux = nil
            return .decoded(main: main, aux: aux)
        }
    }

    /// Settles a job still missing a half: the deadline passed or the
    /// decoder closed. `nil` when it already settled.
    func expire() -> Outcome? {
        parts.withLock { parts -> Outcome? in
            guard !parts.settled else { return nil }
            parts.settled = true
            var missing: [Half] = []
            if parts.main == nil { missing.append(.main) }
            if dual, parts.aux == nil { missing.append(.aux) }
            parts.main = nil
            parts.aux = nil
            return .expired(missing: missing)
        }
    }
}
