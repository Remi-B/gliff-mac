import Foundation
import os

/// Hands decoded pictures from the decoder to the remote surface, latest
/// wins, and keeps the counters the status bar shows.
///
/// The decoder posts from VideoToolbox's output thread; the surface takes
/// on the main thread. At most one picture waits: a newer one replaces it
/// and counts as dropped before display, so a slow or hidden window never
/// queues pictures, and never delays decode reports or the server's pacing.
/// The last picture stays available, so the surface keeps a still image
/// while the desktop is static, across resizes and during recovery.
final class VideoDisplay: Sendable {
    struct Diagnostics: Equatable, Sendable {
        /// Frames VideoToolbox completed, reported `decoded` to the session.
        var decoded: UInt64 = 0
        /// Frames VideoToolbox rejected or could not take, reported `failed`.
        var failed: UInt64 = 0
        /// Frames not decoded: stale generation, no decoder yet, or after
        /// a failure until the next keyframe.
        var discarded: UInt64 = 0
        /// Pictures the surface took for display.
        var presented: UInt64 = 0
        /// Pictures replaced by a newer one before the surface took them.
        var droppedBeforeDisplay: UInt64 = 0
        /// Pictures completed after a newer one and so never shown.
        var outOfOrder: UInt64 = 0
        /// Decoder sessions created (one per stream format).
        var decoderSessions: UInt64 = 0
        /// Whether the current decoder session uses the media engine.
        var hardwareAccelerated: Bool?
        /// A decode failed: the picture is frozen until the next keyframe.
        var recovering = false
        /// The last VideoToolbox or CoreMedia status that failed a frame.
        var lastError: OSStatus?

        // Dual420 pairing and native cost, for diagnostics and task 12.
        /// Dual420 frames whose main and auxiliary pictures both decoded.
        var pairsDecoded: UInt64 = 0
        /// Frames failed because one half (main or aux) failed; the partner
        /// was not waited for.
        var halfFailures: UInt64 = 0
        /// Frames failed because a half never came back before the deadline
        /// (or before the decoder closed).
        var expired: UInt64 = 0
        /// Most frames inside VideoToolbox at once (the bridge bounds them).
        var maxPending: Int = 0
        /// Submission to settlement of each frame (both halves for Dual420).
        var completionMicrosTotal: UInt64 = 0
        var completionMicrosMax: UInt64 = 0
        /// IOSurface bytes of the last decoded picture (main + aux).
        var pictureBytes: Int = 0
        /// Whether the last decoded picture has full chroma (Dual420).
        var fullChroma: Bool?
    }

    private struct State {
        var latest: DecodedFrame?
        var waiting = false
        var sequence: UInt64 = 0
        var diagnostics = Diagnostics()
        var onFrame: (@Sendable () -> Void)?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    init() {}

    /// Called, from the decoder's thread, when a picture starts waiting for
    /// the surface. Not called again until the surface took it.
    func setObserver(_ observer: (@Sendable () -> Void)?) {
        let wake = state.withLock { state in
            state.onFrame = observer
            return state.waiting ? observer : nil
        }
        wake?()
    }

    /// Makes `frame` the latest picture, unless a newer frame is already
    /// there: output callbacks may complete out of order, and frame IDs
    /// increase across generations.
    func post(_ frame: DecodedFrame) {
        postDeferred(frame)?()
    }

    /// Installs a picture without invoking the observer until the caller releases its lock.
    func postDeferred(_ frame: DecodedFrame) -> (@Sendable () -> Void)? {
        state.withLock { state -> (@Sendable () -> Void)? in
            if let latest = state.latest, latest.frameID >= frame.frameID {
                state.diagnostics.outOfOrder += 1
                return nil
            }
            var frame = frame
            state.sequence += 1
            frame.sequence = state.sequence
            state.latest = frame
            if state.waiting {
                state.diagnostics.droppedBeforeDisplay += 1
                return nil
            }
            state.waiting = true
            return state.onFrame
        }
    }

    /// The latest picture, for drawing. Marks a waiting picture taken.
    func take() -> DecodedFrame? {
        state.withLock { state in
            if state.waiting {
                state.waiting = false
                state.diagnostics.presented += 1
            }
            return state.latest
        }
    }

    var latest: DecodedFrame? { state.withLock { $0.latest } }

    var diagnostics: Diagnostics { state.withLock { $0.diagnostics } }

    func update(_ body: @Sendable (inout Diagnostics) -> Void) {
        state.withLock { body(&$0.diagnostics) }
    }

    /// Drops the pictures and the observer: the session ended.
    func clear() {
        state.withLock { state in
            state.latest = nil
            state.waiting = false
            state.onFrame = nil
        }
    }
}
