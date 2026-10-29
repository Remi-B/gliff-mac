//! Public-facade headless probe. Prints counters only, never frame contents.
use gliff_mac_core::*;
use std::sync::{Arc, Mutex, Weak};
struct Probe {
    session: Mutex<Weak<GliffSession>>,
    ended: std::sync::mpsc::Sender<SessionEnd>,
}
impl SessionDelegate for Probe {
    fn on_connected(&self, hello: ServerHello) {
        println!("connected; headless={}", hello.headless);
    }
    fn on_video_config(&self, config: VideoConfig) {
        println!(
            "config {}x{} {:?}",
            config.width, config.height, config.chroma
        );
    }
    fn on_frame(&self, frame: EncodedFrame) {
        if let Some(session) = self.session.lock().unwrap().upgrade() {
            // Transport probe only; task 07 validates real decoder completion.
            let _ = session.report_decode(frame.frame_id, DecodeOutcome::Decoded);
        }
    }
    fn on_cursor_shape(&self, _: CursorShape) {}
    fn on_cursor_position(&self, _: CursorPosition) {}
    fn on_server_error(&self, code: u16, _: String) {
        println!("server error code {code}");
    }
    fn on_ended(&self, end: SessionEnd) {
        let _ = self.ended.send(end);
    }
}
fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<_> = std::env::args().collect();
    if args.len() != 5 {
        return Err(
            "usage: ssh_probe HOST USER ABSOLUTE_IDENTITY SERVER_PATH (always headless)".into(),
        );
    }
    let seconds = std::env::var("GLIFF_PROBE_SECONDS")
        .map(|value| value.parse::<u64>())
        .unwrap_or(Ok(10))?;
    if !(1..=60).contains(&seconds) {
        return Err("GLIFF_PROBE_SECONDS must be between 1 and 60".into());
    }
    let session = GliffSession::new(
        ConnectionTarget::Ssh {
            host: args[1].clone(),
            user: Some(args[2].clone()),
            port: None,
            identity_file: Some(args[3].clone()),
            server_path: Some(args[4].clone()),
            headless: true,
        },
        SessionOptions {
            chroma: vec![ChromaMode::Single420],
            keymap: String::new(),
            max_in_flight_frames: 4,
            min_in_flight_bytes: 8 << 20,
        },
    )?;
    let (tx, rx) = std::sync::mpsc::channel();
    session.start(Arc::new(Probe {
        session: Mutex::new(Arc::downgrade(&session)),
        ended: tx,
    }))?;
    let end = match rx.recv_timeout(std::time::Duration::from_secs(seconds)) {
        Ok(end) => end,
        Err(_) => {
            session.cancel();
            rx.recv_timeout(std::time::Duration::from_secs(5))?
        }
    };
    println!(
        "end={end:?}; state={:?}; stats={:?}",
        session.state(),
        session.stats()
    );
    if matches!(end, SessionEnd::Failed { .. }) {
        return Err("SSH probe failed".into());
    }
    let stats = session.stats();
    if stats.frames_delivered == 0
        || stats.pongs_sent == 0
        || stats.acks_sent != stats.frames_delivered
    {
        return Err(
            "expected frames, pong and a decode-completion ack for every delivered frame".into(),
        );
    }
    if let Ok(path) = std::env::var("GLIFF_PROBE_REPORT") {
        // Metadata only: this does not record compressed images or credentials.
        std::fs::write(path, format!(
            "{{\"status\":\"passed\",\"headless\":true,\"chroma\":\"Single420\",\"frames\":{},\"acks\":{},\"pongs\":{},\"peak_frames\":{},\"peak_bytes\":{},\"path_present\":{},\"agent_present\":{}}}\n",
            stats.frames_delivered, stats.acks_sent, stats.pongs_sent,
            stats.peak_in_flight_frames, stats.peak_in_flight_bytes,
            std::env::var_os("PATH").is_some(), std::env::var_os("SSH_AUTH_SOCK").is_some()
        ))?;
    }
    Ok(())
}
