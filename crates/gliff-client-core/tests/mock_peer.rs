//! A mock server peer on an in-memory duplex: it reads the client's
//! `Hello` the way `gliff-server` does (`Greeting`), streams a committed
//! fixture back through a small pipe, and records what the client sends.
//! The client half follows the session contract: `Pong` before anything
//! else, one `FrameAck` per frame read (decoded or dropped), and a single
//! `RequestKeyframe` while waiting for a keyframe.

mod common;

use common::*;
use gliff_client_core::events::{ServerEvent, ServerReader, SessionError};
use gliff_client_core::video::FrameDisposition;
use gliff_proto::{features, ClientCaps, ClientMsg, Codec, Greeting, PROTOCOL_VERSION};
use gliff_transport::Framed;
use tokio::io::{AsyncWriteExt, DuplexStream};

/// What the mock server saw, in order.
#[derive(Debug, PartialEq)]
enum Seen {
    Pong,
    Ack(u64),
    RequestKeyframe,
    Bye,
}

async fn mock_server(stream: DuplexStream, reply: Vec<u8>) -> (ClientCaps, Vec<Seen>) {
    let (rd, mut wr) = tokio::io::split(stream);
    let mut input = Framed::new(rd);
    let caps = match input.read_msg::<Greeting>().await.unwrap() {
        Greeting::Hello { caps, .. } => caps,
        Greeting::OtherVersion(v) => panic!("client protocol {v}"),
    };
    let send = tokio::spawn(async move {
        wr.write_all(&reply).await.unwrap();
        wr.shutdown().await.unwrap();
    });
    let mut seen = Vec::new();
    loop {
        match input.read_msg::<ClientMsg>().await {
            Ok(ClientMsg::Pong { .. }) => seen.push(Seen::Pong),
            Ok(ClientMsg::FrameAck { frame_id, .. }) => seen.push(Seen::Ack(frame_id)),
            Ok(ClientMsg::RequestKeyframe) => seen.push(Seen::RequestKeyframe),
            Ok(ClientMsg::Bye) => {
                seen.push(Seen::Bye);
                break;
            }
            Ok(other) => panic!("unexpected {other:?}"),
            Err(gliff_transport::Error::Closed) => break,
            Err(e) => panic!("{e}"),
        }
    }
    send.await.unwrap();
    (caps, seen)
}

/// The client half: answers pings, acks every frame, stops at end of stream.
async fn client(stream: DuplexStream) -> Vec<u64> {
    let (rd, wr) = tokio::io::split(stream);
    let support = both_chroma();
    let mut writer = Framed::new(wr);
    writer
        .write_msg(&ClientMsg::Hello {
            version: PROTOCOL_VERSION,
            keymap: String::new(),
            caps: ClientCaps {
                codecs: support.codecs.clone(),
                max_width: 4096,
                max_height: 4096,
                chroma: support.chroma.clone(),
                features: features(),
            },
        })
        .await
        .unwrap();
    let mut reader = ServerReader::new(rd, support);
    let mut decoded = Vec::new();
    loop {
        let event = match reader.next_event().await {
            Ok(e) => e,
            Err(SessionError::Transport(gliff_transport::Error::Closed)) => break,
            Err(e) => panic!("{e}"),
        };
        let ack = |frame_id| ClientMsg::FrameAck {
            frame_id,
            decoded_at_ms: 0,
        };
        match event {
            ServerEvent::Ping { t } => writer.write_msg(&ClientMsg::Pong { t }).await.unwrap(),
            ServerEvent::Frame(FrameDisposition::Decode(f)) => {
                // The native decoder would complete here, asynchronously.
                decoded.push(f.frame_id);
                writer.write_msg(&ack(f.frame_id)).await.unwrap();
            }
            ServerEvent::Frame(FrameDisposition::AwaitKeyframe {
                frame_id,
                request_keyframe,
            }) => {
                writer.write_msg(&ack(frame_id)).await.unwrap();
                if request_keyframe {
                    writer.write_msg(&ClientMsg::RequestKeyframe).await.unwrap();
                }
            }
            _ => {}
        }
    }
    writer.write_msg(&ClientMsg::Bye).await.unwrap();
    decoded
}

#[tokio::test]
async fn a_full_session_replays_through_a_small_pipe() {
    for name in FIXTURES {
        let fx = fixture(name);
        // A 512-byte pipe forces many partial reads and writes, and the
        // server's writes interleave with the client's acks.
        let (a, b) = tokio::io::duplex(512);
        let server = tokio::spawn(mock_server(a, fx.bytes.clone()));
        let decoded = client(b).await;
        let (caps, seen) = server.await.unwrap();

        assert_eq!(caps.codecs, vec![Codec::H264]);
        let expected: Vec<u64> = fx.manifest["frames"]
            .as_array()
            .unwrap()
            .iter()
            .map(|f| f["frame_id"].as_u64().unwrap())
            .collect();
        assert_eq!(decoded, expected, "{name}");
        // Pong first, then exactly one ack per frame in order, then Bye.
        let mut want = vec![Seen::Pong];
        want.extend(expected.iter().map(|&id| Seen::Ack(id)));
        want.push(Seen::Bye);
        assert_eq!(seen, want, "{name}");
    }
}

#[tokio::test]
async fn a_stream_joined_mid_gop_acks_and_requests_one_keyframe() {
    // Drop the first video frame (the IDR) from the fixture: the client
    // must ack the predicted frames it cannot decode and ask once for a
    // keyframe; the fixture's forced IDR (frame 6) resumes decoding.
    let fx = fixture("synthetic-single420");
    let offsets = frame_offsets(&fx.bytes);
    let (at, len) = offsets[4];
    let stream = [&fx.bytes[..at], &fx.bytes[at + len..]].concat();
    let (a, b) = tokio::io::duplex(512);
    let server = tokio::spawn(mock_server(a, stream));
    let decoded = client(b).await;
    let (_, seen) = server.await.unwrap();
    assert_eq!(decoded.first(), Some(&6));
    let requests = seen.iter().filter(|s| **s == Seen::RequestKeyframe).count();
    assert_eq!(requests, 1);
    let acks: Vec<u64> = seen
        .iter()
        .filter_map(|s| match s {
            Seen::Ack(id) => Some(*id),
            _ => None,
        })
        .collect();
    assert_eq!(acks, (1..16).collect::<Vec<_>>());
}
