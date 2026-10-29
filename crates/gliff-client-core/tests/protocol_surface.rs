//! Upstream compatibility gate: the wire surface of the pinned protocol
//! crate must match the reviewed record in `tests/compatibility`.
//!
//! The record holds the protocol version, the handshake features, the error
//! codes, the frame header and the exact CBOR encoding of one sample of every
//! client and server message. A pin bump that renumbers a field, makes a
//! shipped field optional, adds a required field or changes the version
//! fails here with the affected message, instead of reaching a session.
//! Run with `GLIFF_WRITE_PROTOCOL_SURFACE=1` to rewrite the record after
//! reviewing an intentional, compatible change.

use std::collections::BTreeMap;
use std::path::PathBuf;

use gliff_proto::msg::{
    Axis, ChromaMode, ClientCaps, Codec, OutputInfo, Rect, SessionInfo, VideoPipeline,
};
use gliff_proto::{
    ClientMsg, ClipboardFile, ClipboardItem, ServerMsg, ERROR_NO_CHROMA, ERROR_NO_CODEC,
    ERROR_SETUP, ERROR_VERSION, FEATURES, PROTOCOL_VERSION,
};
use serde_json::{json, Value};

const RECORD: &str = "../../tests/compatibility/protocol-surface.json";

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn caps() -> ClientCaps {
    ClientCaps {
        codecs: vec![Codec::H264],
        max_width: 3840,
        max_height: 2160,
        chroma: vec![ChromaMode::Dual420, ChromaMode::Single420],
        features: vec!["example".into()],
    }
}

fn file() -> ClipboardFile {
    ClipboardFile {
        path: "dir/a.txt".into(),
        size: 3,
        dir: false,
    }
}

fn client_messages() -> Vec<(&'static str, ClientMsg)> {
    vec![
        (
            "Hello",
            ClientMsg::Hello {
                version: PROTOCOL_VERSION,
                keymap: String::new(),
                caps: caps(),
            },
        ),
        (
            "Resize",
            ClientMsg::Resize {
                width: 1280,
                height: 800,
                scale: 2.0,
            },
        ),
        (
            "Key",
            ClientMsg::Key {
                keycode: 30,
                pressed: true,
            },
        ),
        ("PointerMotion", ClientMsg::PointerMotion { x: 1.5, y: 2.5 }),
        (
            "PointerButton",
            ClientMsg::PointerButton {
                button: 272,
                pressed: false,
            },
        ),
        (
            "PointerAxis",
            ClientMsg::PointerAxis {
                axis: Axis::Vertical,
                value: -15.0,
                discrete: Some(-1),
                stop: false,
            },
        ),
        (
            "FrameAck",
            ClientMsg::FrameAck {
                frame_id: 7,
                decoded_at_ms: 1_000,
            },
        ),
        ("RequestKeyframe", ClientMsg::RequestKeyframe),
        (
            "ClipboardOffer",
            ClientMsg::ClipboardOffer {
                serial: 1,
                mime_types: vec!["text/plain;charset=utf-8".into()],
                files: vec![file()],
            },
        ),
        (
            "ClipboardRequest",
            ClientMsg::ClipboardRequest {
                id: 2,
                serial: 1,
                item: ClipboardItem::Mime("image/png".into()),
            },
        ),
        (
            "ClipboardData",
            ClientMsg::ClipboardData {
                id: 2,
                offset: 0,
                data_len: 16,
                done: true,
            },
        ),
        ("Ping", ClientMsg::Ping { t: 42 }),
        ("Bye", ClientMsg::Bye),
        (
            "ClipboardAck",
            ClientMsg::ClipboardAck {
                id: 2,
                received: 16,
            },
        ),
        ("ClipboardAbort", ClientMsg::ClipboardAbort { id: 2 }),
        (
            "Keymap",
            ClientMsg::Keymap {
                keymap: "xkb_keymap {};".into(),
            },
        ),
        ("Pong", ClientMsg::Pong { t: 42 }),
    ]
}

fn server_messages() -> Vec<(&'static str, ServerMsg)> {
    vec![
        (
            "HelloAck",
            ServerMsg::HelloAck {
                version: PROTOCOL_VERSION,
                session: SessionInfo {
                    headless: true,
                    output: "gliff-1".into(),
                },
                outputs: vec![OutputInfo {
                    name: "DP-1".into(),
                    width: 2560,
                    height: 1440,
                    scale_milli: 1250,
                }],
                features: vec![],
            },
        ),
        (
            "StreamConfig",
            ServerMsg::StreamConfig {
                codec: Codec::H264,
                chroma: ChromaMode::Dual420,
                pipeline: Some(VideoPipeline::Gpu),
                width: 1280,
                height: 800,
                scale_milli: 2000,
                extradata: vec![0, 0, 0, 1, 0x67],
                aux_extradata: Some(vec![0, 0, 0, 1, 0x68]),
                view_width: 1280,
                view_height: 800,
                fps_cap: 60,
            },
        ),
        (
            "VideoFrame",
            ServerMsg::VideoFrame {
                frame_id: 3,
                pts_us: 33_333,
                keyframe: true,
                damage: vec![Rect {
                    x: 0,
                    y: 0,
                    width: 64,
                    height: 32,
                }],
                data_len: 1024,
                aux_len: 512,
            },
        ),
        (
            "CursorShape",
            ServerMsg::CursorShape {
                id: 1,
                width: 24,
                height: 24,
                hot_x: 4,
                hot_y: 2,
                argb_len: 2304,
            },
        ),
        (
            "CursorPos",
            ServerMsg::CursorPos {
                x: 10.0,
                y: 20.0,
                shape_id: 1,
                visible: true,
            },
        ),
        (
            "ClipboardOffer",
            ServerMsg::ClipboardOffer {
                serial: 5,
                mime_types: vec!["text/uri-list".into()],
                files: vec![file()],
            },
        ),
        (
            "ClipboardRequest",
            ServerMsg::ClipboardRequest {
                id: 6,
                serial: 5,
                item: ClipboardItem::File(0),
            },
        ),
        (
            "ClipboardData",
            ServerMsg::ClipboardData {
                id: 6,
                offset: 262_144,
                data_len: 3,
                done: false,
            },
        ),
        (
            "Pong",
            ServerMsg::Pong {
                t: 42,
                server_now_ms: 9_000,
            },
        ),
        (
            "Error",
            ServerMsg::error(ERROR_SETUP, "no Hyprland instance"),
        ),
        (
            "ClipboardAck",
            ServerMsg::ClipboardAck { id: 6, received: 3 },
        ),
        ("ClipboardAbort", ServerMsg::ClipboardAbort { id: 6 }),
        ("Ping", ServerMsg::Ping { t: 43 }),
    ]
}

fn current_surface() -> Value {
    let mut client = BTreeMap::new();
    for (name, msg) in client_messages() {
        let bytes = minicbor::to_vec(&msg).unwrap();
        let back: ClientMsg = minicbor::decode(&bytes).unwrap();
        assert_eq!(back, msg, "ClientMsg::{name} does not round-trip");
        client.insert(name, hex(&bytes));
    }
    let mut server = BTreeMap::new();
    for (name, msg) in server_messages() {
        let bytes = minicbor::to_vec(&msg).unwrap();
        let back: ServerMsg = minicbor::decode(&bytes).unwrap();
        assert_eq!(back, msg, "ServerMsg::{name} does not round-trip");
        server.insert(name, hex(&bytes));
    }
    json!({
        "protocol_version": PROTOCOL_VERSION,
        "features": FEATURES,
        "error_codes": {
            "version": ERROR_VERSION,
            "no_chroma": ERROR_NO_CHROMA,
            "no_codec": ERROR_NO_CODEC,
            "setup": ERROR_SETUP,
        },
        "frame": {
            "header_len": gliff_proto::frame::HEADER_LEN,
            "max_frame_body": gliff_proto::frame::MAX_FRAME_BODY,
            "max_payload": gliff_proto::frame::MAX_PAYLOAD,
        },
        "client_messages": client,
        "server_messages": server,
    })
}

/// Every difference between the record and the pinned crate, as one line
/// naming the key, its reviewed value and the pinned value.
fn differences(path: &str, recorded: &Value, current: &Value, out: &mut Vec<String>) {
    match (recorded, current) {
        (Value::Object(a), Value::Object(b)) => {
            for key in a.keys().chain(b.keys().filter(|k| !a.contains_key(*k))) {
                let child = format!("{path}.{key}");
                match (a.get(key), b.get(key)) {
                    (Some(x), Some(y)) => differences(&child, x, y, out),
                    (Some(x), None) => out.push(format!("{child}: removed (was {x})")),
                    (None, Some(y)) => out.push(format!("{child}: added ({y})")),
                    (None, None) => unreachable!(),
                }
            }
        }
        _ if recorded != current => out.push(format!("{path}: {recorded} -> {current}")),
        _ => {}
    }
}

#[test]
fn the_pinned_wire_surface_matches_the_reviewed_record() {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join(RECORD);
    let current = current_surface();
    if std::env::var_os("GLIFF_WRITE_PROTOCOL_SURFACE").is_some() {
        let mut text = serde_json::to_string_pretty(&current).unwrap();
        text.push('\n');
        std::fs::write(&path, text).unwrap();
        return;
    }
    let recorded: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    let mut changes = Vec::new();
    differences("surface", &recorded, &current, &mut changes);
    assert!(
        changes.is_empty(),
        "upstream wire surface differs from tests/compatibility/protocol-surface.json \
         ({} change(s)):\n  {}\n\
         A changed protocol_version is a breaking upgrade: the client and every supported \
         server must move together. A changed message encoding means upstream renumbered or \
         retyped a field, or changed a required field: older servers will misread it. \
         Review the range with docs/03-automate-upstream-sync-and-compatibility/\
         upstream-update-workflow.md; if the change is compatible, rewrite the record with \
         GLIFF_WRITE_PROTOCOL_SURFACE=1 and commit it with the pin.",
        changes.len(),
        changes.join("\n  ")
    );
}

#[test]
fn the_pinned_protocol_is_the_version_this_client_implements() {
    assert_eq!(
        gliff_client_core::protocol_version(),
        1,
        "the app implements protocol version 1; a new version needs a reviewed client update"
    );
}
