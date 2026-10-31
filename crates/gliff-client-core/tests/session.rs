//! The session driver against a mock server on an in-memory duplex: what
//! reaches the wire (Hello, Pong first, ordered acks, keyframe requests,
//! input, Bye) and how decode reports, budgets and cancellation drive it.

mod common;

use std::time::Duration;

use common::*;
use gliff_client_core::session::{
    run, Control, Delivery, FrameBudget, FrameOutcome, InputCommand, SessionConfig, SessionEnd,
};
use gliff_proto::{ClientMsg, Greeting};
use gliff_transport::Framed;
use tokio::io::{AsyncWriteExt, DuplexStream};
use tokio::sync::mpsc;

#[derive(Debug, PartialEq)]
enum Seen {
    Pong,
    Ack(u64),
    RequestKeyframe,
    Input,
    Bye,
}

/// Streams `reply` after reading `Hello`, then records client messages until
/// the client closes. With `hold_open`, the server keeps its side open after
/// the stream, like a live server waiting for the client.
async fn mock_server(stream: DuplexStream, reply: Vec<u8>, hold_open: bool) -> Vec<Seen> {
    let (rd, mut wr) = tokio::io::split(stream);
    let mut input = Framed::new(rd);
    assert!(matches!(
        input.read_msg::<Greeting>().await.unwrap(),
        Greeting::Hello { .. }
    ));
    let send = tokio::spawn(async move {
        wr.write_all(&reply).await.unwrap();
        if hold_open {
            std::future::pending::<()>().await;
        }
        wr.shutdown().await.unwrap();
    });
    let mut seen = Vec::new();
    loop {
        match input.read_msg::<ClientMsg>().await {
            Ok(ClientMsg::Pong { .. }) => seen.push(Seen::Pong),
            Ok(ClientMsg::FrameAck { frame_id, .. }) => seen.push(Seen::Ack(frame_id)),
            Ok(ClientMsg::RequestKeyframe) => seen.push(Seen::RequestKeyframe),
            Ok(ClientMsg::PointerMotion { .. }) => seen.push(Seen::Input),
            Ok(ClientMsg::Bye) => {
                seen.push(Seen::Bye);
                break;
            }
            Ok(other) => panic!("unexpected {other:?}"),
            Err(gliff_transport::Error::Closed) => break,
            Err(e) => panic!("{e}"),
        }
    }
    send.abort();
    seen
}

fn config(drain_on_close: bool) -> SessionConfig {
    SessionConfig {
        support: both_chroma(),
        keymap: String::new(),
        budget: FrameBudget::default(),
        drain_on_close,
    }
}

/// Run the driver; `decode` sees every delivered frame and returns its
/// outcome, reported from another task as a native decoder would.
async fn client(
    stream: DuplexStream,
    config: SessionConfig,
    decode: impl Fn(u64) -> FrameOutcome + Send + 'static,
    cancel_after: Option<usize>,
) -> (
    Result<SessionEnd, gliff_client_core::events::SessionError>,
    Vec<u64>,
) {
    let (rd, wr) = tokio::io::split(stream);
    let (control, driver) = Control::new(config.budget);
    let (tx, mut rx) = mpsc::channel::<Delivery>(8);
    let consumer = {
        let control = control.clone();
        tokio::spawn(async move {
            let mut delivered = Vec::new();
            while let Some(d) = rx.recv().await {
                if let Delivery::Frame(f) = d {
                    delivered.push(f.frame_id);
                    let outcome = decode(f.frame_id);
                    let reporter = control.clone();
                    tokio::spawn(async move {
                        tokio::task::yield_now().await;
                        reporter.report(f.frame_id, outcome).unwrap();
                    });
                    if cancel_after == Some(delivered.len()) {
                        control
                            .send_input(InputCommand::PointerMotion { x: 1.0, y: 2.0 })
                            .unwrap();
                        tokio::time::sleep(Duration::from_millis(10)).await;
                        control.cancel();
                    }
                }
            }
            delivered
        })
    };
    let result = run(rd, wr, config, driver, tx).await;
    (result, consumer.await.unwrap())
}

fn acks(seen: &[Seen]) -> Vec<u64> {
    seen.iter()
        .filter_map(|s| match s {
            Seen::Ack(id) => Some(*id),
            _ => None,
        })
        .collect()
}

fn frame_ids(fx: &Fixture) -> Vec<u64> {
    fx.manifest["frames"]
        .as_array()
        .unwrap()
        .iter()
        .map(|f| f["frame_id"].as_u64().unwrap())
        .collect()
}

#[tokio::test]
async fn every_frame_is_acked_in_order_after_its_report() {
    for name in FIXTURES {
        let fx = fixture(name);
        let (a, b) = tokio::io::duplex(512);
        let server = tokio::spawn(mock_server(a, fx.bytes.clone(), false));
        let (result, delivered) = client(b, config(true), |_| FrameOutcome::Decoded, None).await;
        assert_eq!(result.unwrap(), SessionEnd::Closed, "{name}");
        let seen = server.await.unwrap();
        assert_eq!(seen.first(), Some(&Seen::Pong), "{name}: Pong comes first");
        // Frames of a replaced generation may be discarded, never lost.
        assert_eq!(acks(&seen), frame_ids(&fx), "{name}");
        assert!(delivered.windows(2).all(|w| w[0] < w[1]), "{name}");
    }
}

#[tokio::test]
async fn a_failed_decode_requests_one_keyframe_and_drops_until_it() {
    let fx = fixture("synthetic-single420");
    let (a, b) = tokio::io::duplex(512);
    let server = tokio::spawn(mock_server(a, fx.bytes.clone(), false));
    let (result, delivered) = client(
        b,
        config(true),
        |id| {
            if id == 2 {
                FrameOutcome::Failed
            } else {
                FrameOutcome::Decoded
            }
        },
        None,
    )
    .await;
    result.unwrap();
    let seen = server.await.unwrap();
    assert_eq!(acks(&seen), frame_ids(&fx));
    let requests = seen.iter().filter(|s| **s == Seen::RequestKeyframe).count();
    assert_eq!(requests, 1);
    // Decoding resumes at the next IDR (6); frames read between the failure
    // report and it are dropped (how many depends on read-ahead).
    assert!(delivered.contains(&6));
}

#[tokio::test]
async fn cancellation_forwards_input_then_says_bye() {
    let fx = fixture("live-cpu-single420");
    let (a, b) = tokio::io::duplex(4096);
    let server = tokio::spawn(mock_server(a, fx.bytes.clone(), true));
    let (result, delivered) = client(b, config(false), |_| FrameOutcome::Decoded, Some(3)).await;
    assert_eq!(result.unwrap(), SessionEnd::Cancelled);
    let seen = server.await.unwrap();
    assert_eq!(seen.last(), Some(&Seen::Bye));
    assert!(seen.contains(&Seen::Input));
    assert!(delivered.len() < frame_ids(&fx).len());
}

#[tokio::test]
async fn unreported_frames_stop_the_reader_at_the_budget() {
    let fx = fixture("live-cpu-single420");
    let (a, b) = tokio::io::duplex(1 << 20);
    let _server = tokio::spawn(mock_server(a, fx.bytes.clone(), true));
    let (rd, wr) = tokio::io::split(b);
    let budget = FrameBudget {
        max_frames: 3,
        min_bytes: 8 << 20,
    };
    let (control, driver) = Control::new(budget);
    let (tx, mut rx) = mpsc::channel::<Delivery>(64);
    let config = SessionConfig {
        budget,
        ..config(false)
    };
    let session = tokio::spawn(run(rd, wr, config, driver, tx));
    let mut frames = Vec::new();
    // Never report: exactly three frames arrive, then the reader waits.
    while frames.len() < 3 {
        if let Delivery::Frame(f) = rx.recv().await.unwrap() {
            frames.push(f.frame_id);
        }
    }
    tokio::time::sleep(Duration::from_millis(50)).await;
    while let Ok(d) = rx.try_recv() {
        assert!(
            !matches!(d, Delivery::Frame(_)),
            "a frame beyond the budget"
        );
    }
    assert_eq!(control.stats().peak_in_flight_frames, 3);
    // One report lets exactly one more frame through.
    control.report(frames[0], FrameOutcome::Decoded).unwrap();
    loop {
        if let Delivery::Frame(_) = rx.recv().await.unwrap() {
            break;
        }
    }
    assert_eq!(control.stats().acks_sent, 1);
    assert_eq!(
        control.report(frames[0], FrameOutcome::Decoded),
        Err(gliff_client_core::session::ControlError::UnknownFrame(
            frames[0]
        ))
    );
    control.cancel();
    assert_eq!(session.await.unwrap().unwrap(), SessionEnd::Cancelled);
    assert!(!control.is_running());
    assert!(control
        .send_input(InputCommand::Key {
            keycode: 30,
            pressed: true
        })
        .is_err());
}

#[tokio::test]
async fn cancellation_interrupts_a_write_to_a_peer_that_stopped_reading() {
    // The peer reads nothing: Hello fills the 16-byte pipe and blocks.
    let (_peer, b) = tokio::io::duplex(16);
    let (rd, wr) = tokio::io::split(b);
    let (control, driver) = Control::new(FrameBudget::default());
    let (tx, _rx) = mpsc::channel::<Delivery>(8);
    let session = tokio::spawn(run(rd, wr, config(false), driver, tx));
    tokio::time::sleep(Duration::from_millis(20)).await;
    let started = std::time::Instant::now();
    control.cancel();
    let end = tokio::time::timeout(Duration::from_secs(2), session)
        .await
        .expect("teardown waited on the blocked peer");
    assert_eq!(end.unwrap().unwrap(), SessionEnd::Cancelled);
    // No Bye after an interrupted write: teardown does not wait for it.
    assert!(started.elapsed() < Duration::from_millis(500));
    assert!(!control.is_running());
}

#[tokio::test]
async fn the_keymap_goes_in_hello_and_a_changed_one_precedes_later_keys() {
    let (a, b) = tokio::io::duplex(4096);
    let server = tokio::spawn(async move {
        let (rd, _wr) = tokio::io::split(a);
        let mut input = Framed::new(rd);
        let Greeting::Hello { keymap, .. } = input.read_msg::<Greeting>().await.unwrap() else {
            panic!("expected Hello");
        };
        let mut seen = vec![format!("hello {keymap}")];
        loop {
            match input.read_msg::<ClientMsg>().await {
                Ok(ClientMsg::Keymap { keymap }) => seen.push(format!("keymap {keymap}")),
                Ok(ClientMsg::Key { keycode, pressed }) => {
                    seen.push(format!("key {keycode} {pressed}"))
                }
                Ok(ClientMsg::Bye) | Err(_) => break,
                Ok(other) => panic!("unexpected {other:?}"),
            }
        }
        seen
    });
    let (rd, wr) = tokio::io::split(b);
    let (control, driver) = Control::new(FrameBudget::default());
    let (tx, _rx) = mpsc::channel::<Delivery>(8);
    let mut config = config(false);
    config.keymap = "us-map".into();
    let session = tokio::spawn(run(rd, wr, config, driver, tx));
    while !control.is_running() {
        tokio::task::yield_now().await;
    }
    for input in [
        InputCommand::Key {
            keycode: 16,
            pressed: true,
        },
        InputCommand::Keymap {
            keymap: "fr-map".into(),
        },
        InputCommand::Key {
            keycode: 16,
            pressed: false,
        },
    ] {
        control.send_input(input).unwrap();
    }
    tokio::time::sleep(Duration::from_millis(20)).await;
    control.cancel();
    assert_eq!(session.await.unwrap().unwrap(), SessionEnd::Cancelled);
    assert_eq!(
        server.await.unwrap(),
        [
            "hello us-map",
            "key 16 true",
            "keymap fr-map",
            "key 16 false"
        ]
    );
}
