//! The UniFFI facade from Rust, with a Rust delegate standing in for Swift:
//! validation errors, replay delivery and acks, delivery thread ownership,
//! and teardown (exactly one `on_ended`, nothing after it, delegate released).

use std::path::PathBuf;
use std::sync::{Arc, Condvar, Mutex};
use std::time::Duration;

use gliff_mac_core::*;

fn fixture(name: &str) -> Vec<u8> {
    let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures/streams");
    std::fs::read(dir.join(format!("{name}.gliffstream"))).unwrap()
}

fn options(chroma: Vec<ChromaMode>) -> SessionOptions {
    SessionOptions {
        chroma,
        keymap: String::new(),
        max_in_flight_frames: 4,
        min_in_flight_bytes: 8 << 20,
    }
}

#[derive(Default)]
struct State {
    frames: Vec<u64>,
    configs: Vec<u32>,
    callbacks: usize,
    wrong_thread: usize,
    ended: Option<SessionEnd>,
    ends: usize,
}

/// Records callbacks; reports each frame from another thread when `session`
/// is set.
#[derive(Default)]
struct Recorder {
    state: Mutex<State>,
    done: Condvar,
    session: Mutex<Option<std::sync::Weak<GliffSession>>>,
}

impl Recorder {
    fn note(&self, f: impl FnOnce(&mut State)) {
        let mut s = self.state.lock().unwrap();
        s.callbacks += 1;
        if std::thread::current().name() != Some("gliff-delivery") {
            s.wrong_thread += 1;
        }
        f(&mut s);
    }

    fn wait_end(&self) -> SessionEnd {
        let s = self.state.lock().unwrap();
        let (s, timeout) = self
            .done
            .wait_timeout_while(s, Duration::from_secs(10), |s| s.ended.is_none())
            .unwrap();
        assert!(!timeout.timed_out(), "no on_ended");
        s.ended.clone().unwrap()
    }
}

impl SessionDelegate for Recorder {
    fn on_connected(&self, _: ServerHello) {
        self.note(|_| {});
    }
    fn on_video_config(&self, config: VideoConfig) {
        self.note(|s| s.configs.push(config.revision));
    }
    fn on_frame(&self, frame: EncodedFrame) {
        self.note(|s| s.frames.push(frame.frame_id));
        if let Some(session) = self
            .session
            .lock()
            .unwrap()
            .as_ref()
            .and_then(|w| w.upgrade())
        {
            std::thread::spawn(move || {
                session
                    .report_decode(frame.frame_id, DecodeOutcome::Decoded)
                    .unwrap();
            });
        }
    }
    fn on_cursor_shape(&self, _: CursorShape) {
        self.note(|_| {});
    }
    fn on_cursor_position(&self, _: CursorPosition) {
        self.note(|_| {});
    }
    fn on_server_error(&self, _: u16, _: String) {
        self.note(|_| {});
    }
    fn on_ended(&self, end: SessionEnd) {
        self.note(|s| {
            s.ended = Some(end);
            s.ends += 1;
        });
        self.done.notify_all();
    }
}

#[test]
fn invalid_targets_and_options_are_typed_errors() {
    let ssh = |host: &str, user: Option<&str>, port| ConnectionTarget::Ssh {
        host: host.into(),
        user: user.map(Into::into),
        port,
        server_path: None,
    };
    let single = options(vec![ChromaMode::Single420]);
    for target in [
        ssh("", None, None),
        ssh("-oProxyCommand=x", None, None),
        ssh("a b", None, None),
        ssh("host", Some("-l"), None),
        ssh("host", Some("me@x"), None),
        ssh("host", None, Some(0)),
        ConnectionTarget::Replay { stream: vec![] },
    ] {
        assert!(matches!(
            GliffSession::new(target, single.clone()),
            Err(GliffError::InvalidOptions { .. })
        ));
    }
    let replay = || ConnectionTarget::Replay { stream: vec![0] };
    for bad in [
        options(vec![]),
        options(vec![ChromaMode::Dual420, ChromaMode::Dual420]),
        SessionOptions {
            max_in_flight_frames: 0,
            ..single.clone()
        },
        SessionOptions {
            min_in_flight_bytes: 1,
            ..single.clone()
        },
    ] {
        assert!(matches!(
            GliffSession::new(replay(), bad),
            Err(GliffError::InvalidOptions { .. })
        ));
    }
    let session = GliffSession::new(ssh("host", Some("me"), Some(22)), single).unwrap();
    let recorder = Arc::new(Recorder::default());
    assert!(matches!(
        session.start(recorder.clone()),
        Err(GliffError::Unsupported { .. })
    ));
    // A refused start does not consume the session's delegate.
    assert_eq!(Arc::strong_count(&recorder), 1);
}

#[test]
fn replay_delivers_on_the_delivery_thread_and_acks_every_frame() {
    for (name, chroma) in [
        ("synthetic-single420", ChromaMode::Single420),
        ("synthetic-dual420", ChromaMode::Dual420),
        ("live-cpu-single420", ChromaMode::Single420),
    ] {
        let stream = fixture(name);
        let session =
            GliffSession::new(ConnectionTarget::Replay { stream }, options(vec![chroma])).unwrap();
        let recorder = Arc::new(Recorder::default());
        *recorder.session.lock().unwrap() = Some(Arc::downgrade(&session));
        session.start(recorder.clone()).unwrap();
        assert!(matches!(
            session.start(recorder.clone()),
            Err(GliffError::AlreadyStarted)
        ));
        assert_eq!(recorder.wait_end(), SessionEnd::Closed, "{name}");
        let stats = session.stats();
        let s = recorder.state.lock().unwrap();
        assert_eq!(s.wrong_thread, 0, "{name}");
        assert_eq!(s.ends, 1);
        assert!(s.frames.windows(2).all(|w| w[0] < w[1]));
        assert_eq!(stats.frames_delivered, s.frames.len() as u64);
        assert_eq!(
            stats.acks_sent,
            stats.frames_delivered + stats.frames_dropped
        );
        assert!(stats.peak_in_flight_frames <= 4);
        assert!(matches!(
            session.send_input(InputEvent::PointerMotion { x: 0.0, y: 0.0 }),
            Err(GliffError::NotRunning)
        ));
    }
}

#[test]
fn a_session_ended_with_a_contract_error_is_fatal() {
    // A Dual420 stream offered to a Single420-only decoder.
    let session = GliffSession::new(
        ConnectionTarget::Replay {
            stream: fixture("synthetic-dual420"),
        },
        options(vec![ChromaMode::Single420]),
    )
    .unwrap();
    let recorder = Arc::new(Recorder::default());
    session.start(recorder.clone()).unwrap();
    let SessionEnd::Failed { error } = recorder.wait_end() else {
        panic!("expected a failure");
    };
    assert!(matches!(error, GliffError::Contract { .. }), "{error}");
    assert!(is_fatal_incompatibility(&error));
}

#[test]
fn cancel_and_drop_cycles_end_once_and_release_the_delegate() {
    let stream = fixture("live-gpu-dual420");
    for cycle in 0..200 {
        let session = GliffSession::new(
            ConnectionTarget::Replay {
                stream: stream.clone(),
            },
            options(vec![ChromaMode::Dual420]),
        )
        .unwrap();
        let recorder = Arc::new(Recorder::default());
        // No decode reports: the session stalls at its budget until stopped.
        session.start(recorder.clone()).unwrap();
        match cycle % 3 {
            0 => {
                session.cancel();
                session.cancel();
            }
            1 => std::thread::sleep(Duration::from_micros(200)),
            _ => {}
        }
        drop(session);
        assert_eq!(recorder.wait_end(), SessionEnd::Cancelled);
        let callbacks = recorder.state.lock().unwrap().callbacks;
        // The delivery thread drops its reference right after on_ended.
        for _ in 0..1000 {
            if Arc::strong_count(&recorder) == 1 {
                break;
            }
            std::thread::sleep(Duration::from_millis(1));
        }
        assert_eq!(
            Arc::strong_count(&recorder),
            1,
            "delegate kept after on_ended"
        );
        let s = recorder.state.lock().unwrap();
        assert_eq!(s.callbacks, callbacks, "a callback followed on_ended");
        assert_eq!(s.ends, 1);
    }
}

/// Fails one frame from inside the callback, as a synchronous decoder
/// error would, and reports the others.
struct FailOnce {
    inner: Recorder,
    fail: u64,
    keyframes: Mutex<Vec<u64>>,
}

impl SessionDelegate for FailOnce {
    fn on_connected(&self, hello: ServerHello) {
        self.inner.on_connected(hello);
    }
    fn on_video_config(&self, config: VideoConfig) {
        self.inner.on_video_config(config);
    }
    fn on_frame(&self, frame: EncodedFrame) {
        self.inner.note(|s| s.frames.push(frame.frame_id));
        if frame.keyframe {
            self.keyframes.lock().unwrap().push(frame.frame_id);
        }
        let session = self
            .inner
            .session
            .lock()
            .unwrap()
            .as_ref()
            .unwrap()
            .upgrade();
        let outcome = if frame.frame_id == self.fail {
            DecodeOutcome::Failed
        } else {
            DecodeOutcome::Decoded
        };
        session
            .unwrap()
            .report_decode(frame.frame_id, outcome)
            .unwrap();
    }
    fn on_cursor_shape(&self, shape: CursorShape) {
        self.inner.on_cursor_shape(shape);
    }
    fn on_cursor_position(&self, position: CursorPosition) {
        self.inner.on_cursor_position(position);
    }
    fn on_server_error(&self, code: u16, message: String) {
        self.inner.on_server_error(code, message);
    }
    fn on_ended(&self, end: SessionEnd) {
        self.inner.on_ended(end);
    }
}

#[test]
fn queued_predicted_frames_after_a_decode_failure_never_reach_the_decoder() {
    // synthetic-single420: IDRs at frames 0, 6 and 10 (rebuild).
    for _ in 0..20 {
        let session = GliffSession::new(
            ConnectionTarget::Replay {
                stream: fixture("synthetic-single420"),
            },
            options(vec![ChromaMode::Single420]),
        )
        .unwrap();
        let delegate = Arc::new(FailOnce {
            inner: Recorder::default(),
            fail: 1,
            keyframes: Mutex::new(Vec::new()),
        });
        *delegate.inner.session.lock().unwrap() = Some(Arc::downgrade(&session));
        session.start(delegate.clone()).unwrap();
        assert_eq!(delegate.inner.wait_end(), SessionEnd::Closed);
        let frames = delegate.inner.state.lock().unwrap().frames.clone();
        let after: Vec<u64> = frames.iter().copied().filter(|&id| id > 1).collect();
        // The next frame the decoder sees is a keyframe.
        assert!(
            delegate.keyframes.lock().unwrap().contains(&after[0]),
            "predicted frame {} delivered after the failure: {frames:?}",
            after[0]
        );
        let stats = session.stats();
        assert_eq!(stats.frames_failed, 1);
        assert_eq!(stats.keyframe_requests, 1, "{frames:?}");
        assert_eq!(stats.acks_sent, 16);
    }
}
