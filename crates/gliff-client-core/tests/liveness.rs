//! Liveness of a streaming session: a quiet server gets `Ping`s, a server
//! that answers stays connected, and one silent while the client reads
//! ends the session with a timeout the app treats as a lost link.

mod common;

use std::time::Duration;

use common::*;
use gliff_client_core::events::SessionError;
use gliff_client_core::session::{
    run, Control, Delivery, FrameBudget, SessionConfig, PING_AFTER, SILENCE_LIMIT,
};
use gliff_proto::{
    ChromaMode, ClientMsg, Codec, Greeting, OutputInfo, ServerMsg, SessionInfo, VideoPipeline,
    PROTOCOL_VERSION,
};
use gliff_transport::Framed;
use tokio::io::{AsyncWriteExt, DuplexStream};
use tokio::sync::mpsc;

fn handshake() -> Vec<u8> {
    let mut out = raw_frame(
        &encode(&ServerMsg::HelloAck {
            version: PROTOCOL_VERSION,
            session: SessionInfo {
                headless: true,
                output: "gliff-1".into(),
            },
            outputs: vec![OutputInfo {
                name: "gliff-1".into(),
                width: 64,
                height: 64,
                scale_milli: 1000,
            }],
            features: vec![],
        }),
        &[],
    );
    out.extend(raw_frame(
        &encode(&ServerMsg::StreamConfig {
            codec: Codec::H264,
            chroma: ChromaMode::Single420,
            pipeline: Some(VideoPipeline::Cpu),
            width: 64,
            height: 64,
            scale_milli: 1000,
            extradata: vec![],
            aux_extradata: None,
            view_width: 64,
            view_height: 64,
            fps_cap: 60,
        }),
        &[],
    ));
    out
}

fn pong(t: u64) -> Vec<u8> {
    raw_frame(
        &encode(&ServerMsg::Pong {
            t,
            server_now_ms: 0,
        }),
        &[],
    )
}

/// Streams the handshake, then counts `Ping`s; with `answer`, replies to
/// each with a `Pong` like `gliff-server`. Returns the pings seen.
async fn server(stream: DuplexStream, answer: bool) -> usize {
    let (rd, mut wr) = tokio::io::split(stream);
    let mut input = Framed::new(rd);
    assert!(matches!(
        input.read_msg::<Greeting>().await.unwrap(),
        Greeting::Hello { .. }
    ));
    wr.write_all(&handshake()).await.unwrap();
    let mut pings = 0;
    loop {
        match input.read_msg::<ClientMsg>().await {
            Ok(ClientMsg::Ping { t }) => {
                pings += 1;
                if answer {
                    wr.write_all(&pong(t)).await.unwrap();
                }
            }
            Ok(ClientMsg::Bye) | Err(_) => return pings,
            Ok(other) => panic!("unexpected {other:?}"),
        }
    }
}

fn config() -> SessionConfig {
    SessionConfig {
        support: both_chroma(),
        keymap: String::new(),
        budget: FrameBudget::default(),
        drain_on_close: false,
    }
}

#[tokio::test(start_paused = true)]
async fn a_silent_server_is_pinged_then_times_out() {
    let (a, b) = tokio::io::duplex(4096);
    let server = tokio::spawn(server(a, false));
    let (rd, wr) = tokio::io::split(b);
    let (control, driver) = Control::new(FrameBudget::default());
    let (tx, mut rx) = mpsc::channel::<Delivery>(32);
    tokio::spawn(async move { while rx.recv().await.is_some() {} });
    let start = tokio::time::Instant::now();
    let error = run(rd, wr, config(), driver, tx).await.unwrap_err();
    assert!(
        matches!(error, SessionError::Transport(gliff_transport::Error::Io(ref e)) if e.kind() == std::io::ErrorKind::TimedOut),
        "{error}"
    );
    assert!(error.to_string().contains("stopped responding"), "{error}");
    let elapsed = start.elapsed();
    assert!(elapsed >= SILENCE_LIMIT, "{elapsed:?}");
    assert!(
        elapsed < SILENCE_LIMIT + Duration::from_secs(1),
        "{elapsed:?}"
    );
    // One ping per PING_AFTER of silence until the limit (5 s and 10 s,
    // and possibly 15 s as the watchdog fires).
    let pings = control.stats().pings_sent;
    let expected = SILENCE_LIMIT.as_secs() / PING_AFTER.as_secs();
    assert!((expected - 1..=expected).contains(&pings), "{pings}");
    assert!(!control.is_running());
    drop(server);
}

#[tokio::test(start_paused = true)]
async fn a_server_answering_pings_stays_connected() {
    let (a, b) = tokio::io::duplex(4096);
    let server = tokio::spawn(server(a, true));
    let (rd, wr) = tokio::io::split(b);
    let (control, driver) = Control::new(FrameBudget::default());
    let (tx, mut rx) = mpsc::channel::<Delivery>(32);
    tokio::spawn(async move { while rx.recv().await.is_some() {} });
    let cancel = control.clone();
    tokio::spawn(async move {
        tokio::time::sleep(Duration::from_secs(120)).await;
        cancel.cancel();
    });
    let end = run(rd, wr, config(), driver, tx).await.unwrap();
    assert_eq!(end, gliff_client_core::session::SessionEnd::Cancelled);
    let pings = server.await.unwrap();
    assert!((20..=24).contains(&pings), "{pings} pings in 120 s");
    assert_eq!(control.stats().pings_sent as usize, pings);
}

#[tokio::test(start_paused = true)]
async fn no_ping_before_the_first_configuration() {
    // A server still creating its output says nothing for a while; only the
    // existing 20-second startup deadline applies.
    let (a, b) = tokio::io::duplex(4096);
    let (rd, wr) = tokio::io::split(b);
    let (control, driver) = Control::new(FrameBudget::default());
    let (tx, _rx) = mpsc::channel::<Delivery>(32);
    let error = run(rd, wr, config(), driver, tx).await.unwrap_err();
    assert!(error.to_string().contains("startup"), "{error}");
    assert_eq!(control.stats().pings_sent, 0);
    drop(a);
}

#[tokio::test(start_paused = true)]
async fn a_large_frame_arriving_slowly_is_not_silence() {
    // A 64 KiB keyframe arriving at 2 KiB/s takes 32 s: the bytes keep the
    // session alive although no complete message arrives for longer than
    // the silence limit.
    // SPS, PPS and an IDR slice padded without start codes.
    let mut payload = vec![0, 0, 0, 1, 0x67, 1, 0, 0, 0, 1, 0x68, 2, 0, 0, 1, 0x65];
    payload.resize(64 << 10, 0x55);
    let mut frame = raw_frame(
        &encode(&ServerMsg::VideoFrame {
            frame_id: 0,
            pts_us: 0,
            keyframe: true,
            damage: vec![],
            data_len: payload.len() as u32,
            aux_len: 0,
        }),
        &payload,
    );
    let (a, b) = tokio::io::duplex(1 << 20);
    let (srd, mut swr) = tokio::io::split(a);
    let server = tokio::spawn(async move {
        let mut input = Framed::new(srd);
        assert!(matches!(
            input.read_msg::<Greeting>().await.unwrap(),
            Greeting::Hello { .. }
        ));
        swr.write_all(&handshake()).await.unwrap();
        let rest = frame.split_off(64);
        swr.write_all(&frame).await.unwrap();
        for chunk in rest.chunks(2 << 10) {
            tokio::time::sleep(Duration::from_secs(1)).await;
            swr.write_all(chunk).await.unwrap();
        }
        // Keep reading the client's messages until it says Bye.
        while let Ok(msg) = input.read_msg::<ClientMsg>().await {
            if msg == ClientMsg::Bye {
                break;
            }
        }
    });
    let (rd, wr) = tokio::io::split(b);
    let (control, driver) = Control::new(FrameBudget::default());
    let (tx, mut rx) = mpsc::channel::<Delivery>(32);
    let frames = tokio::spawn(async move {
        let mut frames = 0;
        while let Some(delivery) = rx.recv().await {
            frames += usize::from(matches!(delivery, Delivery::Frame(_)));
        }
        frames
    });
    let cancel = control.clone();
    tokio::spawn(async move {
        tokio::time::sleep(Duration::from_secs(40)).await;
        cancel.cancel();
    });
    let end = run(rd, wr, config(), driver, tx).await;
    assert_eq!(
        end.unwrap(),
        gliff_client_core::session::SessionEnd::Cancelled
    );
    assert_eq!(frames.await.unwrap(), 1);
    server.await.unwrap();
}
