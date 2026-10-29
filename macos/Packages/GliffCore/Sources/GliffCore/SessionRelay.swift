import Dispatch
import os

/// Input for the video decoder, in wire order, on the session's delivery thread.
public enum VideoItem: Sendable {
    /// Precedes the frames it describes; `rebuild` replaces the decoder session.
    case config(VideoConfig)
    /// Report it with `GliffSession.reportDecode` once the decoder completes it.
    case frame(EncodedFrame)
}

/// What the interface observes, on the main actor, in wire order.
public enum SessionEvent: Sendable {
    case connected(ServerHello)
    case videoConfig(VideoConfig)
    case cursorShape(CursorShape)
    /// Coalesced: consecutive positions waiting for the main actor collapse to
    /// the latest; positions never move across another event.
    case cursorPosition(CursorPosition)
    case serverError(code: UInt16, message: String)
    /// The last event; the session releases this relay right after.
    case ended(SessionEnd)
}

/// Splits a session's callbacks by owner.
///
/// - `video` runs on the session's delivery thread, never the main thread or
///   the network thread. It must hand frames to the decoder without blocking
///   for long: while it runs, the next callback waits and, once the in-flight
///   budget is used, the session stops reading from the network.
/// - `events` runs on the main actor, for SwiftUI state. Video configurations
///   go to both. Cursor positions are coalesced, so a busy main thread cannot
///   queue them without bound; the other events are rare.
///
/// The relay holds no reference to the session. Capture interface models
/// weakly in `events`: the session keeps the relay until `.ended`.
public final class SessionRelay: SessionDelegate {
    private let video: @Sendable (VideoItem) -> Void
    private let events: @MainActor @Sendable (SessionEvent) -> Void
    private let pendingPosition = OSAllocatedUnfairLock<CursorPosition?>(initialState: nil)

    public init(
        video: @escaping @Sendable (VideoItem) -> Void,
        events: @escaping @MainActor @Sendable (SessionEvent) -> Void
    ) {
        self.video = video
        self.events = events
    }

    public func onConnected(hello: ServerHello) {
        post(.connected(hello))
    }

    public func onVideoConfig(config: VideoConfig) {
        video(.config(config))
        post(.videoConfig(config))
    }

    public func onFrame(frame: EncodedFrame) {
        video(.frame(frame))
    }

    public func onCursorShape(shape: CursorShape) {
        post(.cursorShape(shape))
    }

    public func onCursorPosition(position: CursorPosition) {
        let scheduled = pendingPosition.withLock { pending in
            defer { pending = position }
            return pending != nil
        }
        if scheduled { return }
        let events = self.events
        DispatchQueue.main.async { [pendingPosition] in
            guard let latest = pendingPosition.withLock({ $0.take() }) else { return }
            MainActor.assumeIsolated { events(.cursorPosition(latest)) }
        }
    }

    public func onServerError(code: UInt16, message: String) {
        post(.serverError(code: code, message: message))
    }

    public func onEnded(end: SessionEnd) {
        post(.ended(end))
    }

    private func post(_ event: SessionEvent) {
        let events = self.events
        // A position still waiting is delivered just before this event, so
        // coalescing never reorders positions across other events. The main
        // queue is FIFO: the already scheduled position block finds nothing.
        let position = pendingPosition.withLock { $0.take() }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if let position { events(.cursorPosition(position)) }
                events(event)
            }
        }
    }
}

extension Optional {
    fileprivate mutating func take() -> Wrapped? {
        defer { self = nil }
        return self
    }
}
