import GliffCore
import os

/// One remote session as the view model sees it. `LiveSession` wraps the
/// bridge's `GliffSession`; tests substitute a fake.
@MainActor
protocol RemoteSession: AnyObject {
    /// Starts once. `events` runs on the main actor in wire order and ends with
    /// exactly one `.ended`, after which the session holds no callbacks.
    func start(events: @escaping @MainActor @Sendable (SessionEvent) -> Void) throws
    /// Idempotent and non-blocking; `.ended` follows once teardown completes.
    func cancel()
    /// Where the session's decoded pictures appear; `nil` without a decoder.
    var videoDisplay: VideoDisplay? { get }
}

extension RemoteSession {
    var videoDisplay: VideoDisplay? { nil }
}

/// Builds sessions for the view model.
@MainActor
protocol SessionFactory {
    func makeSession(for request: ConnectionRequest) throws -> any RemoteSession
}

/// The real session: system OpenSSH and the bridge's protocol driver.
struct LiveSessionFactory: SessionFactory {
    func makeSession(for request: ConnectionRequest) throws -> any RemoteSession {
        try LiveSession(target: request.target(), options: SessionOptions(chroma: LiveSession.chroma))
    }
}

/// Adapts `GliffSession` and `SessionRelay` to `RemoteSession`, with the
/// VideoToolbox decoder on the video side.
///
/// Configurations and frames go from the bridge's delivery thread straight
/// to the decoder, which reports each frame to the session from VideoToolbox's
/// output callback: acknowledgements never wait for the main thread or the
/// window. The decoder is invalidated on cancel and when the session ends.
final class LiveSession: RemoteSession {
    /// What `H264Decoder` and `VideoRenderer` implement, preferred first:
    /// full chroma, and Single420 for the server's low-bandwidth rungs.
    /// Native 4:4:4, H.265 and AV1 are not implemented and never advertised.
    nonisolated static let chroma: [ChromaMode] = [.dual420, .single420]

    private let session: GliffSession
    private let decoder: H264Decoder

    var videoDisplay: VideoDisplay? { decoder.display }

    init(target: ConnectionTarget, options: SessionOptions) throws {
        let session = try GliffSession(target: target, options: options)
        self.session = session
        decoder = H264Decoder(display: VideoDisplay()) { [weak session] frameID, outcome in
            // `NotRunning` once the session ended: nothing left to acknowledge.
            try? session?.reportDecode(frameId: frameID, outcome: outcome)
        }
    }

    func start(events: @escaping @MainActor @Sendable (SessionEvent) -> Void) throws {
        let decoder = self.decoder
        let relay = SessionRelay(
            video: { item in decoder.handle(item) },
            events: { [weak self] event in
                if case .ended = event {
                    decoder.invalidate()
                    self?.logSummary()
                }
                events(event)
            })
        try session.start(delegate: relay)
    }

    func cancel() {
        session.cancel()
        decoder.invalidate()
    }

    /// The bridge's counters: frames delivered, acknowledgements, keyframe requests.
    var stats: SessionStats { session.stats() }

    /// Counters only: no host, user or picture content.
    private func logSummary() {
        let s = stats
        let v = decoder.display.diagnostics
        Logger(subsystem: "com.remi-b.gliff-mac", category: "video").info(
            "session video: delivered \(s.framesDelivered) dropped \(s.framesDropped) acks \(s.acksSent) keyframe requests \(s.keyframeRequests); decoded \(v.decoded) pairs \(v.pairsDecoded) failed \(v.failed) half failures \(v.halfFailures) expired \(v.expired) discarded \(v.discarded) presented \(v.presented) replaced \(v.droppedBeforeDisplay) out of order \(v.outOfOrder) decoders \(v.decoderSessions) hardware \(v.hardwareAccelerated.map { $0 ? "yes" : "no" } ?? "unknown", privacy: .public) max pending \(v.maxPending) completion max \(v.completionMicrosMax) us picture bytes \(v.pictureBytes)")
    }
}
