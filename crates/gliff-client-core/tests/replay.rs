//! Replay the committed server streams and malformed variants of them
//! through the client contract, using upstream framing.

mod common;

use common::*;
use gliff_client_core::events::{ServerEvent, ServerReader, SessionError};
use gliff_client_core::video::{ContractError, DecoderSupport, FrameDisposition};
use gliff_proto::frame::{MAX_FRAME_BODY, MAX_FRAME_PAYLOAD, MAX_PAYLOAD};
use gliff_proto::{
    ChromaMode, Codec, OutputInfo, Rect, ServerMsg, SessionInfo, VideoPipeline, ERROR_NO_CHROMA,
    ERROR_SETUP, ERROR_VERSION, PROTOCOL_VERSION,
};
use gliff_transport::{Error as TransportError, Framed};
use serde_json::Value;

fn event_name(e: &ServerEvent) -> &'static str {
    match e {
        ServerEvent::HelloAck { .. } => "HelloAck",
        ServerEvent::Ping { .. } => "Ping",
        ServerEvent::Pong { .. } => "Pong",
        ServerEvent::Config(_) => "StreamConfig",
        ServerEvent::Frame(_) => "VideoFrame",
        ServerEvent::CursorShape { .. } => "CursorShape",
        ServerEvent::CursorPos { .. } => "CursorPos",
        ServerEvent::Clipboard { .. } => "Clipboard",
        ServerEvent::Error { .. } => "Error",
    }
}

/// Check every event of a replay against the fixture's manifest.
fn assert_matches_manifest(events: &[ServerEvent], manifest: &Value) {
    let names: Vec<&str> = events.iter().map(event_name).collect();
    let expected: Vec<&str> = manifest["messages"]
        .as_array()
        .unwrap()
        .iter()
        .map(|v| v.as_str().unwrap())
        .collect();
    assert_eq!(names, expected);
    let configs: Vec<_> = events
        .iter()
        .filter_map(|e| match e {
            ServerEvent::Config(c) => Some(c),
            _ => None,
        })
        .collect();
    let expected = manifest["configs"].as_array().unwrap();
    assert_eq!(configs.len(), expected.len());
    for (c, m) in configs.iter().zip(expected) {
        assert_eq!(u64::from(c.generation), m["generation"]);
        assert_eq!(u64::from(c.revision), m["revision"]);
        assert_eq!(c.rebuild, m["rebuild"]);
        assert_eq!(format!("{:?}", c.chroma), m["chroma"]);
        assert_eq!(u64::from(c.width), m["width"]);
        assert_eq!(u64::from(c.height), m["height"]);
        assert_eq!(u64::from(c.fps_cap), m["fps_cap"]);
    }
    let frames: Vec<_> = events
        .iter()
        .filter_map(|e| match e {
            ServerEvent::Frame(FrameDisposition::Decode(f)) => Some(f),
            ServerEvent::Frame(other) => panic!("fixture frame not decodable: {other:?}"),
            _ => None,
        })
        .collect();
    let expected = manifest["frames"].as_array().unwrap();
    assert_eq!(frames.len(), expected.len());
    for (f, m) in frames.iter().zip(expected) {
        assert_eq!(u64::from(f.generation), m["generation"]);
        assert_eq!(u64::from(f.revision), m["revision"]);
        assert_eq!(f.frame_id, m["frame_id"]);
        assert_eq!(f.pts_us, m["pts_us"]);
        assert_eq!(f.keyframe, m["keyframe"]);
        assert_eq!(sha256(&f.main), m["main_sha256"]);
        // Main/aux association: each frame's aux is the bytes recorded for
        // that same frame, and only Dual420 frames have one.
        match &f.aux {
            Some(aux) => assert_eq!(sha256(aux), m["aux_sha256"]),
            None => assert!(m["aux_sha256"].is_null()),
        }
    }
}

#[tokio::test]
async fn fixtures_match_their_manifests() {
    for name in FIXTURES {
        let fx = fixture(name);
        assert_eq!(sha256(&fx.bytes), fx.manifest["sha256"], "{name}");
        assert_eq!(fx.bytes.len() as u64, fx.manifest["bytes"], "{name}");
        assert!(fx.bytes.len() < 1 << 20, "{name} must stay under 1 MiB");
        let mut reader = ServerReader::new(&fx.bytes[..], both_chroma());
        let (events, err) = read_all(&mut reader).await;
        assert!(err.is_none(), "{name}: {err:?}");
        assert_matches_manifest(&events, &fx.manifest);
    }
}

#[tokio::test]
async fn the_fixtures_cover_both_chroma_modes_and_every_config_kind() {
    let single = fixture("synthetic-single420").manifest;
    let dual = fixture("synthetic-dual420").manifest;
    assert!(single["configs"]
        .as_array()
        .unwrap()
        .iter()
        .all(|c| c["chroma"] == "Single420"));
    assert!(dual["configs"]
        .as_array()
        .unwrap()
        .iter()
        .all(|c| c["chroma"] == "Dual420"));
    for m in [single, dual] {
        let configs = m["configs"].as_array().unwrap();
        assert!(
            configs.iter().any(|c| c["rebuild"] == false),
            "pace-only change"
        );
        assert!(
            configs.iter().skip(1).any(|c| c["rebuild"] == true),
            "rebuild"
        );
        // Every keyframe carries in-band SPS/PPS; the first frame of each
        // decoder generation is a keyframe.
        let frames = m["frames"].as_array().unwrap();
        for f in frames.iter().filter(|f| f["keyframe"] == true) {
            assert_eq!(f["main_nal_types"][0], 7);
            assert_eq!(f["main_nal_types"][1], 8);
        }
        for g in [1, 2] {
            let first = frames.iter().find(|f| f["generation"] == g).unwrap();
            assert_eq!(first["keyframe"], true);
        }
    }
}

#[tokio::test]
async fn partial_reads_at_every_chunk_size_give_the_same_events() {
    for name in FIXTURES {
        let fx = fixture(name);
        for chunk in [1, 2, 3, 7, 8, 9, 1000, 4096] {
            let mut reader =
                ServerReader::new(ChunkedReader::new(fx.bytes.clone(), chunk), both_chroma());
            let (events, err) = read_all(&mut reader).await;
            assert!(err.is_none(), "{name} chunk {chunk}: {err:?}");
            assert_matches_manifest(&events, &fx.manifest);
        }
    }
}

#[tokio::test]
async fn partial_writes_reproduce_the_fixture_bytes() {
    // Re-encode the fixture through upstream's writer over a sink that
    // takes a few bytes per (vectored) write: the output must be identical,
    // so short writes never reorder or drop main/aux bytes.
    let fx = fixture("synthetic-dual420");
    let mut src = Framed::new(&fx.bytes[..]);
    let mut sink = Framed::new(ShortWriter::new(5));
    loop {
        let msg: ServerMsg = match src.read_msg().await {
            Ok(m) => m,
            Err(TransportError::Closed) => break,
            Err(e) => panic!("{e}"),
        };
        let lens: Vec<u32> = match &msg {
            ServerMsg::VideoFrame {
                data_len, aux_len, ..
            } => vec![*data_len, *aux_len],
            ServerMsg::CursorShape { argb_len, .. } => vec![*argb_len],
            _ => vec![],
        };
        let mut payloads = Vec::new();
        for len in lens {
            payloads.push(src.read_payload(len).await.unwrap());
        }
        let slices: Vec<&[u8]> = payloads.iter().map(|p| &p[..]).collect();
        sink.write_msg_with_payloads(&msg, &slices).await.unwrap();
    }
    assert_eq!(sink.into_inner().written, fx.bytes);
}

#[tokio::test]
async fn truncation_anywhere_ends_without_a_partial_frame() {
    let fx = fixture("synthetic-dual420");
    let offsets = frame_offsets(&fx.bytes);
    // Cut inside the header, the body, the main payload and the aux
    // payload of the first video frame, and at a frame boundary.
    let (frame_at, frame_len) = offsets[4];
    let cuts = [
        frame_at + 3,
        frame_at + 12,
        frame_at + frame_len / 3,
        frame_at + frame_len - 1,
        frame_at,
    ];
    for cut in cuts {
        let mut reader = ServerReader::new(&fx.bytes[..cut], both_chroma());
        let (events, err) = read_all(&mut reader).await;
        // Upstream `Framed` reports `Closed` for a clean end and for a cut
        // inside a frame alike; the contract is that no partial message or
        // frame is ever delivered.
        assert!(err.is_none(), "cut {cut}: {err:?}");
        assert_eq!(events.len(), 4, "cut {cut}");
        assert!(!events.iter().any(|e| matches!(e, ServerEvent::Frame(_))));
    }
}

type ErrorCheck = fn(&SessionError) -> bool;

#[tokio::test]
async fn oversized_declarations_are_rejected_before_allocation() {
    let hello = fixture("synthetic-single420").bytes;
    let hello = &hello[..frame_offsets(&hello)[0].1];
    let cases: Vec<(Vec<u8>, ErrorCheck)> = vec![
        (raw_header(MAX_FRAME_BODY as u32 + 1, 0), |e| {
            matches!(e, SessionError::Transport(TransportError::BodyTooLarge(_)))
        }),
        (raw_header(4, MAX_FRAME_PAYLOAD + 1), |e| {
            matches!(
                e,
                SessionError::Transport(TransportError::PayloadTooLarge(_))
            )
        }),
    ];
    for (tail, check) in cases {
        let stream = [hello, &tail].concat();
        let mut reader = ServerReader::new(&stream[..], both_chroma());
        let (_, err) = read_all(&mut reader).await;
        assert!(check(err.as_ref().unwrap()), "{err:?}");
    }
}

/// A known HelloAck and StreamConfig, then `tail`.
fn session_with(chroma: ChromaMode, tail: &[u8]) -> Vec<u8> {
    let mut out = raw_frame(
        &encode(&ServerMsg::HelloAck {
            version: PROTOCOL_VERSION,
            session: SessionInfo {
                headless: false,
                output: "DP-1".into(),
            },
            outputs: vec![OutputInfo {
                name: "DP-1".into(),
                width: 64,
                height: 64,
                scale_milli: 1500,
            }],
            features: vec![],
        }),
        &[],
    );
    out.extend(raw_frame(&encode(&config(chroma, 64, 64)), &[]));
    out.extend_from_slice(tail);
    out
}

fn config(chroma: ChromaMode, width: u32, height: u32) -> ServerMsg {
    ServerMsg::StreamConfig {
        codec: Codec::H264,
        chroma,
        pipeline: Some(VideoPipeline::Gpu),
        width,
        height,
        scale_milli: 1500,
        extradata: vec![],
        aux_extradata: None,
        view_width: width,
        view_height: height,
        fps_cap: 60,
    }
}

const IDR: &[u8] = &[0, 0, 0, 1, 0x67, 1, 0, 0, 0, 1, 0x68, 2, 0, 0, 1, 0x65, 3];
const P: &[u8] = &[0, 0, 0, 1, 0x41, 4];

fn video(frame_id: u64, keyframe: bool, main: &[u8], aux: &[u8]) -> Vec<u8> {
    raw_frame(
        &encode(&ServerMsg::VideoFrame {
            frame_id,
            pts_us: 1_000 * frame_id,
            keyframe,
            damage: vec![Rect {
                x: 0,
                y: 0,
                width: 64,
                height: 64,
            }],
            data_len: main.len() as u32,
            aux_len: aux.len() as u32,
        }),
        &[main, aux].concat(),
    )
}

async fn replay(
    stream: Vec<u8>,
    support: DecoderSupport,
) -> (Vec<ServerEvent>, Option<SessionError>) {
    let mut reader = ServerReader::new(&stream[..], support);
    read_all(&mut reader).await
}

#[tokio::test]
async fn a_payload_declared_beyond_the_frame_is_an_overrun() {
    // The message claims more payload than its header carries.
    let body = encode(&ServerMsg::VideoFrame {
        frame_id: 0,
        pts_us: 0,
        keyframe: true,
        damage: vec![],
        data_len: IDR.len() as u32 + 10,
        aux_len: 0,
    });
    let stream = session_with(ChromaMode::Single420, &raw_frame(&body, IDR));
    let (_, err) = replay(stream, both_chroma()).await;
    assert!(matches!(
        err,
        Some(SessionError::Transport(
            TransportError::PayloadOverrun { .. }
        ))
    ));
    // And a single declared payload above the per-payload cap.
    let body = encode(&ServerMsg::VideoFrame {
        frame_id: 0,
        pts_us: 0,
        keyframe: true,
        damage: vec![],
        data_len: MAX_PAYLOAD + 1,
        aux_len: 0,
    });
    let stream = session_with(ChromaMode::Single420, &raw_frame(&body, IDR));
    let (_, err) = replay(stream, both_chroma()).await;
    assert!(matches!(
        err,
        Some(SessionError::Transport(TransportError::PayloadTooLarge(_)))
    ));
}

#[tokio::test]
async fn an_unknown_message_is_skipped_with_its_payload() {
    // `[99, [1, 2]]`: a variant this build does not know, with a payload.
    let unknown = raw_frame(&[0x82, 0x18, 99, 0x82, 0x01, 0x02], b"opaque payload");
    let mut tail = unknown.clone();
    tail.extend(raw_frame(&encode(&ServerMsg::Ping { t: 7 }), &[]));
    tail.extend(unknown);
    tail.extend(video(0, true, IDR, &[]));
    let (events, err) = replay(session_with(ChromaMode::Single420, &tail), both_chroma()).await;
    assert!(err.is_none(), "{err:?}");
    assert!(matches!(events[2], ServerEvent::Ping { t: 7 }));
    assert!(matches!(
        events[3],
        ServerEvent::Frame(FrameDisposition::Decode(_))
    ));
}

#[tokio::test]
async fn an_unknown_enum_value_inside_a_known_message_is_fatal() {
    // StreamConfig with codec index 9: not skippable, the message fails.
    let mut body = encode(&config(ChromaMode::Single420, 64, 64));
    // `[1, [codec, ...]]`: 0x82 0x01 0x8b then the codec index.
    assert_eq!(&body[..4], &[0x82, 0x01, 0x8b, 0x01]);
    body[3] = 0x09;
    let stream = session_with(ChromaMode::Single420, &raw_frame(&body, &[]));
    let (_, err) = replay(stream, both_chroma()).await;
    assert!(matches!(
        err,
        Some(SessionError::Transport(TransportError::Decode(_)))
    ));
}

#[tokio::test]
async fn version_mismatch_and_incompatible_errors_are_fatal() {
    let ack = |version| {
        raw_frame(
            &encode(&ServerMsg::HelloAck {
                version,
                session: SessionInfo {
                    headless: true,
                    output: "x".into(),
                },
                outputs: vec![],
                features: vec![],
            }),
            &[],
        )
    };
    let (_, err) = replay(ack(PROTOCOL_VERSION + 1), both_chroma()).await;
    let err = err.unwrap();
    assert!(err.is_fatal_incompatibility());
    assert!(
        err.to_string().contains("Client version is too old"),
        "{err}"
    );

    // A server that rejects our Hello sends only Error with its version.
    let rejected = raw_frame(
        &encode(&ServerMsg::Error {
            code: ERROR_VERSION,
            message: "Server version is too old".into(),
            version: Some(0),
        }),
        &[],
    );
    let (_, err) = replay(rejected, both_chroma()).await;
    assert!(matches!(
        err,
        Some(SessionError::VersionMismatch { server: 0, .. })
    ));

    let no_chroma = raw_frame(&encode(&ServerMsg::error(ERROR_NO_CHROMA, "none")), &[]);
    let (_, err) = replay(no_chroma, both_chroma()).await;
    assert!(matches!(
        err,
        Some(SessionError::Incompatible { code: 2, .. })
    ));

    // ERROR_SETUP is outside the incompatible range: reported, retryable.
    let setup = raw_frame(&encode(&ServerMsg::error(ERROR_SETUP, "no Hyprland")), &[]);
    let (events, err) = replay(setup, both_chroma()).await;
    assert!(err.is_none());
    assert!(matches!(events[0], ServerEvent::Error { code: 256, .. }));

    // Anything but HelloAck first is a protocol violation.
    let (_, err) = replay(video(0, true, IDR, &[]), both_chroma()).await;
    assert!(matches!(
        err,
        Some(SessionError::UnexpectedFirstMessage("VideoFrame"))
    ));
}

#[tokio::test]
async fn an_unadvertised_chroma_mode_or_codec_is_rejected() {
    let single_only = DecoderSupport::h264(&[ChromaMode::Single420]);
    let (_, err) = replay(session_with(ChromaMode::Dual420, &[]), single_only.clone()).await;
    assert!(matches!(
        err,
        Some(SessionError::Contract(ContractError::UnsupportedChroma(
            ChromaMode::Dual420
        )))
    ));
    // Native444 exists upstream; existing is not support.
    let (_, err) = replay(session_with(ChromaMode::Native444, &[]), both_chroma()).await;
    assert!(matches!(
        err,
        Some(SessionError::Contract(ContractError::UnsupportedChroma(
            ChromaMode::Native444
        )))
    ));
}

#[tokio::test]
async fn main_and_aux_lengths_must_match_the_chroma_mode() {
    let (_, err) = replay(
        session_with(ChromaMode::Dual420, &video(0, true, IDR, &[])),
        both_chroma(),
    )
    .await;
    assert!(matches!(
        err,
        Some(SessionError::Contract(ContractError::AuxMismatch {
            aux_len: 0,
            ..
        }))
    ));
    let (_, err) = replay(
        session_with(ChromaMode::Single420, &video(0, true, IDR, IDR)),
        both_chroma(),
    )
    .await;
    assert!(matches!(
        err,
        Some(SessionError::Contract(ContractError::AuxMismatch { .. }))
    ));
    // Dual: main and aux are split in declaration order.
    let aux_idr = &[0, 0, 1, 0x67, 9, 0, 0, 1, 0x68, 9, 0, 0, 1, 0x65, 9][..];
    let (events, err) = replay(
        session_with(ChromaMode::Dual420, &video(0, true, IDR, aux_idr)),
        both_chroma(),
    )
    .await;
    assert!(err.is_none());
    let ServerEvent::Frame(FrameDisposition::Decode(f)) = &events[2] else {
        panic!("{:?}", events[2]);
    };
    assert_eq!(&f.main[..], IDR);
    assert_eq!(f.aux.as_deref(), Some(aux_idr));
}

#[tokio::test]
async fn a_keyframe_needs_in_band_parameter_sets() {
    let bare_idr = &[0, 0, 1, 0x65, 1][..];
    let (_, err) = replay(
        session_with(ChromaMode::Single420, &video(0, true, bare_idr, &[])),
        both_chroma(),
    )
    .await;
    assert!(matches!(
        err,
        Some(SessionError::Contract(
            ContractError::KeyframeNotSelfContained { .. }
        ))
    ));
    let (_, err) = replay(
        session_with(ChromaMode::Single420, &video(0, false, b"\x01\x02", &[])),
        both_chroma(),
    )
    .await;
    assert!(matches!(
        err,
        Some(SessionError::Contract(ContractError::NotAnnexB { .. }))
    ));
}

#[tokio::test]
async fn predicted_frames_wait_for_a_keyframe_after_a_rebuild() {
    let mut tail = Vec::new();
    tail.extend(video(0, false, P, &[]));
    tail.extend(video(1, false, P, &[]));
    tail.extend(video(2, true, IDR, &[]));
    tail.extend(video(3, false, P, &[]));
    // Pace-only change: same decoder, no keyframe needed.
    let mut paced = config(ChromaMode::Single420, 64, 64);
    if let ServerMsg::StreamConfig { fps_cap, .. } = &mut paced {
        *fps_cap = 15;
    }
    tail.extend(raw_frame(&encode(&paced), &[]));
    tail.extend(video(4, false, P, &[]));
    // Chroma change at the same size: a new decoder generation.
    tail.extend(raw_frame(
        &encode(&config(ChromaMode::Dual420, 64, 64)),
        &[],
    ));
    tail.extend(video(5, false, P, P));
    tail.extend(video(6, true, IDR, IDR));
    let (events, err) = replay(session_with(ChromaMode::Single420, &tail), both_chroma()).await;
    assert!(err.is_none(), "{err:?}");
    let summary: Vec<String> = events
        .iter()
        .skip(1)
        .map(|e| match e {
            ServerEvent::Config(c) => format!(
                "config g{} r{} rebuild={}",
                c.generation, c.revision, c.rebuild
            ),
            ServerEvent::Frame(FrameDisposition::Decode(f)) => {
                format!("decode {} g{} r{}", f.frame_id, f.generation, f.revision)
            }
            ServerEvent::Frame(FrameDisposition::AwaitKeyframe {
                frame_id,
                request_keyframe,
            }) => format!("drop {frame_id} request={request_keyframe}"),
            other => format!("{other:?}"),
        })
        .collect();
    assert_eq!(
        summary,
        [
            "config g1 r1 rebuild=true",
            "drop 0 request=true",
            "drop 1 request=false",
            "decode 2 g1 r1",
            "decode 3 g1 r1",
            "config g1 r2 rebuild=false",
            "decode 4 g1 r2",
            "config g2 r3 rebuild=true",
            "drop 5 request=true",
            "decode 6 g2 r3",
        ]
    );
}

#[tokio::test]
async fn frames_must_follow_a_configuration_and_increase() {
    let hello = fixture("synthetic-single420").bytes;
    let hello = hello[..frame_offsets(&hello)[0].1].to_vec();
    let (_, err) = replay([hello, video(0, true, IDR, &[])].concat(), both_chroma()).await;
    assert!(matches!(
        err,
        Some(SessionError::Contract(ContractError::FrameBeforeConfig(0)))
    ));
    let tail = [video(5, true, IDR, &[]), video(5, false, P, &[])].concat();
    let (_, err) = replay(session_with(ChromaMode::Single420, &tail), both_chroma()).await;
    assert!(matches!(
        err,
        Some(SessionError::Contract(
            ContractError::FrameIdNotIncreasing {
                previous: 5,
                frame_id: 5
            }
        ))
    ));
}

#[tokio::test]
async fn invalid_geometry_is_rejected_like_upstream() {
    for (w, h) in [(0, 64), (63, 64), (4098, 64)] {
        let stream = [
            session_with(ChromaMode::Single420, &[]),
            raw_frame(&encode(&config(ChromaMode::Single420, w, h)), &[]),
        ]
        .concat();
        let (_, err) = replay(stream, both_chroma()).await;
        assert!(
            matches!(
                err,
                Some(SessionError::Contract(ContractError::InvalidSize { .. }))
            ),
            "{w}x{h}: {err:?}"
        );
    }
    let mut tiny_view = config(ChromaMode::Single420, 64, 64);
    if let ServerMsg::StreamConfig { view_width, .. } = &mut tiny_view {
        *view_width = 31;
    }
    let stream = [
        session_with(ChromaMode::Single420, &[]),
        raw_frame(&encode(&tiny_view), &[]),
    ]
    .concat();
    let (_, err) = replay(stream, both_chroma()).await;
    assert!(matches!(
        err,
        Some(SessionError::Contract(ContractError::InvalidView { .. }))
    ));
}

#[tokio::test]
async fn a_malformed_cursor_shape_is_ignored_not_fatal() {
    let shape = raw_frame(
        &encode(&ServerMsg::CursorShape {
            id: 1,
            width: 2,
            height: 2,
            hot_x: 0,
            hot_y: 0,
            argb_len: 3,
        }),
        &[1, 2, 3],
    );
    let tail = [shape, video(0, true, IDR, &[])].concat();
    let (events, err) = replay(session_with(ChromaMode::Single420, &tail), both_chroma()).await;
    assert!(err.is_none(), "{err:?}");
    assert!(matches!(
        events[2],
        ServerEvent::CursorShape { argb: None, .. }
    ));
    assert!(matches!(
        events[3],
        ServerEvent::Frame(FrameDisposition::Decode(_))
    ));
}

#[tokio::test]
async fn a_cancelled_read_resumes_inside_a_frame_payload() {
    use tokio::io::AsyncWriteExt;
    // Cancel `next_event` while the main and then the aux payload are only
    // partly delivered: the next call must return that same frame.
    let aux_idr = &[0, 0, 1, 0x67, 9, 0, 0, 1, 0x68, 9, 0, 0, 1, 0x65, 9][..];
    let stream = session_with(ChromaMode::Dual420, &video(3, true, IDR, aux_idr));
    let frame_at = stream.len() - (IDR.len() + aux_idr.len());
    let (mut tx, rx) = tokio::io::duplex(64 * 1024);
    let mut reader = ServerReader::new(rx, both_chroma());
    let wait = std::time::Duration::from_millis(20);
    let cuts = [0, frame_at + 4, frame_at + IDR.len() + 3, stream.len()];
    let mut events = Vec::new();
    for pair in cuts.windows(2) {
        tx.write_all(&stream[pair[0]..pair[1]]).await.unwrap();
        // A timeout cancels the pending read.
        while let Ok(event) = tokio::time::timeout(wait, reader.next_event()).await {
            events.push(event.unwrap());
        }
    }
    assert_eq!(events.len(), 3, "{events:?}");
    let ServerEvent::Frame(FrameDisposition::Decode(f)) = &events[2] else {
        panic!("{:?}", events[2]);
    };
    assert_eq!(f.frame_id, 3);
    assert_eq!(&f.main[..], IDR);
    assert_eq!(f.aux.as_deref(), Some(aux_idr));
}
