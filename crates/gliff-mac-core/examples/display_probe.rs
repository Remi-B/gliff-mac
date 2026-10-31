//! Live display and lifecycle probe through the public facade (task 10).
//! Prints one JSON object of metadata: configurations, timings and ends.
//! Never frame contents, host names or paths.
//!
//! usage: display_probe HOST USER ABSOLUTE_IDENTITY SERVER_PATH SCENARIO [ARG]
//!   resize          headless; Resize series, each answered by a configuration
//!   mirror OUTPUT   mirror OUTPUT; a smaller window scales the stream down
//!   hold SECONDS    headless; stream until the session ends or SECONDS pass,
//!                   printing `streaming` on stderr once the first config arrives
//!   cycles N        N headless sessions: first configuration, then cancel
use gliff_mac_core::*;
use std::sync::mpsc::{channel, Receiver, RecvTimeoutError, Sender};
use std::sync::{Arc, Mutex, Weak};
use std::time::{Duration, Instant};

enum Event {
    Hello(ServerHello),
    Config(VideoConfig),
    Ended(SessionEnd),
}

struct Probe {
    session: Mutex<Weak<GliffSession>>,
    events: Sender<Event>,
}

impl SessionDelegate for Probe {
    fn on_connected(&self, hello: ServerHello) {
        let _ = self.events.send(Event::Hello(hello));
    }
    fn on_video_config(&self, config: VideoConfig) {
        let _ = self.events.send(Event::Config(config));
    }
    fn on_frame(&self, frame: EncodedFrame) {
        if let Some(session) = self.session.lock().unwrap().upgrade() {
            let _ = session.report_decode(frame.frame_id, DecodeOutcome::Decoded);
        }
    }
    fn on_cursor_shape(&self, _: CursorShape) {}
    fn on_cursor_position(&self, _: CursorPosition) {}
    fn on_server_error(&self, _: u16, _: String) {}
    fn on_ended(&self, end: SessionEnd) {
        let _ = self.events.send(Event::Ended(end));
    }
}

struct Run {
    session: Arc<GliffSession>,
    events: Receiver<Event>,
    started: Instant,
    configs: Vec<String>,
    hello: Option<ServerHello>,
    output: Option<String>,
}

impl Run {
    fn start(args: &[String], headless: bool, output: Option<String>) -> Result<Self, GliffError> {
        let session = GliffSession::new(
            ConnectionTarget::Ssh {
                host: args[1].clone(),
                user: Some(args[2].clone()),
                port: None,
                identity_file: Some(args[3].clone()),
                server_path: Some(args[4].clone()),
                headless,
                output: output.clone(),
                video_mode: VideoMode::Auto,
            },
            SessionOptions {
                chroma: vec![ChromaMode::Dual420, ChromaMode::Single420],
                keymap: String::new(),
                max_in_flight_frames: 4,
                min_in_flight_bytes: 8 << 20,
            },
        )?;
        let (tx, rx) = channel();
        session.start(Arc::new(Probe {
            session: Mutex::new(Arc::downgrade(&session)),
            events: tx,
        }))?;
        Ok(Self {
            session,
            events: rx,
            started: Instant::now(),
            configs: Vec::new(),
            hello: None,
            output,
        })
    }

    /// The next configuration within `timeout`; `Err` carries the end.
    fn next_config(&mut self, timeout: Duration) -> Result<Option<VideoConfig>, String> {
        let deadline = Instant::now() + timeout;
        loop {
            let left = deadline.saturating_duration_since(Instant::now());
            match self.events.recv_timeout(left) {
                Ok(Event::Hello(hello)) => self.hello = Some(hello),
                Ok(Event::Config(config)) => {
                    self.configs.push(format!(
                        "{{\"ms\":{},\"generation\":{},\"rebuild\":{},\"width\":{},\"height\":{},\"view\":[{},{}],\"scale_milli\":{},\"fps\":{},\"chroma\":\"{:?}\"}}",
                        self.started.elapsed().as_millis(), config.generation, config.rebuild,
                        config.width, config.height, config.view_width, config.view_height,
                        config.scale_milli, config.fps_cap, config.chroma));
                    return Ok(Some(config));
                }
                Ok(Event::Ended(end)) => return Err(end_json(&end, self.started)),
                Err(RecvTimeoutError::Timeout) => return Ok(None),
                Err(RecvTimeoutError::Disconnected) => return Err("\"disconnected\"".into()),
            }
        }
    }

    /// Waits for a configuration whose view matches `want`, ignoring others.
    fn config_where(
        &mut self,
        timeout: Duration,
        want: impl Fn(&VideoConfig) -> bool,
    ) -> Result<bool, String> {
        let deadline = Instant::now() + timeout;
        while let Some(config) =
            self.next_config(deadline.saturating_duration_since(Instant::now()))?
        {
            if want(&config) {
                return Ok(true);
            }
        }
        Ok(false)
    }

    fn finish(self) -> String {
        self.session.cancel();
        let end = loop {
            match self.events.recv_timeout(Duration::from_secs(10)) {
                Ok(Event::Ended(end)) => break end_json(&end, self.started),
                Ok(_) => {}
                Err(_) => break "\"no end within 10 s\"".into(),
            }
        };
        self.result(&end)
    }

    fn result(&self, end: &str) -> String {
        let s = self.session.stats();
        let hello = self.hello.as_ref().map_or("null".into(), |h| {
            format!(
                "{{\"headless\":{},\"output_is_requested\":{},\"outputs\":{}}}",
                h.headless,
                // Report only whether the served output is the requested
                // one: output names are not written to evidence.
                self.output.as_ref().is_some_and(|o| *o == h.output),
                h.outputs.len()
            )
        });
        format!(
            "{{\"hello\":{hello},\"configs\":[{}],\"end\":{end},\"stats\":{{\"frames\":{},\"acks\":{},\"pings\":{},\"inputs\":{},\"peak_in_flight\":{},\"decode_delay_max_us\":{}}}}}",
            self.configs.join(","), s.frames_delivered, s.acks_sent, s.pings_sent,
            s.inputs_sent, s.peak_in_flight_frames, s.decode_delay_max_us)
    }
}

fn end_json(end: &SessionEnd, started: Instant) -> String {
    let ms = started.elapsed().as_millis();
    match end {
        SessionEnd::Closed => format!("{{\"kind\":\"closed\",\"ms\":{ms}}}"),
        SessionEnd::Cancelled => format!("{{\"kind\":\"cancelled\",\"ms\":{ms}}}"),
        SessionEnd::Failed { error } => {
            let (class, message) = match error {
                GliffError::Transport { message } => ("transport", message.as_str()),
                GliffError::Setup { message } => ("setup", message.as_str()),
                _ => ("other", ""),
            };
            // Bridge messages are fixed, redacted guidance.
            format!(
                "{{\"kind\":\"failed\",\"class\":\"{class}\",\"message\":{:?},\"ms\":{ms}}}",
                message
            )
        }
    }
}

fn resize(run: &mut Run, width: u32, height: u32, scale: f32) -> Result<bool, String> {
    run.session
        .send_input(InputEvent::Resize {
            width,
            height,
            scale,
        })
        .map_err(|e| format!("\"send: {e}\""))?;
    run.config_where(Duration::from_secs(8), |c| {
        c.view_width.abs_diff(width) <= 8 && c.view_height.abs_diff(height) <= 8
    })
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 6 {
        return Err("usage: display_probe HOST USER IDENTITY SERVER_PATH SCENARIO [ARG]".into());
    }
    let arg = args.get(6).cloned();
    let json = match args[5].as_str() {
        "resize" => {
            let mut run = Run::start(&args, true, None)?;
            let mut steps = Vec::new();
            match run.next_config(Duration::from_secs(25)) {
                Ok(Some(_)) => {
                    // Window sizes in backing pixels, with Retina and
                    // non-Retina scales, and a scale-only change.
                    for (w, h, scale) in [
                        (1600, 1000, 2.0),
                        (1280, 800, 1.0),
                        (2560, 1440, 2.0),
                        (2560, 1440, 1.0),
                        (1024, 768, 2.0),
                    ] {
                        let t = run.started.elapsed().as_millis();
                        let matched = resize(&mut run, w, h, scale);
                        steps.push(format!(
                            "{{\"request\":[{w},{h},{scale}],\"matched\":{},\"ms\":{}}}",
                            matched.as_ref().map_or("false".into(), |m| m.to_string()),
                            run.started.elapsed().as_millis() - t
                        ));
                        if matched.is_err() {
                            break;
                        }
                    }
                }
                Ok(None) => steps.push("\"no first configuration\"".into()),
                Err(end) => steps.push(end),
            }
            let result = run.finish();
            format!(
                "{{\"scenario\":\"resize\",\"steps\":[{}],\"session\":{result}}}",
                steps.join(",")
            )
        }
        "mirror" => {
            let output = arg.ok_or("mirror needs an output name")?;
            let mut run = Run::start(&args, false, Some(output))?;
            let mut steps = Vec::new();
            match run.next_config(Duration::from_secs(25)) {
                Ok(Some(first)) => {
                    // The window is smaller than the output: the server fits
                    // the stream, keeping the output's aspect ratio.
                    let (w, h) = (first.view_width / 2, first.view_height / 2);
                    let t = run.started.elapsed().as_millis();
                    run.session.send_input(InputEvent::Resize {
                        width: w.max(320),
                        height: h.max(240),
                        scale: 2.0,
                    })?;
                    let fitted = run.config_where(Duration::from_secs(8), |c| {
                        c.width <= w.max(320) && c.height < first.height
                    });
                    steps.push(format!(
                        "{{\"first\":[{},{}],\"request\":[{},{}],\"fitted\":{},\"ms\":{}}}",
                        first.width,
                        first.height,
                        w.max(320),
                        h.max(240),
                        fitted.as_ref().map_or("false".into(), |m| m.to_string()),
                        run.started.elapsed().as_millis() - t
                    ));
                }
                Ok(None) => steps.push("\"no first configuration\"".into()),
                Err(end) => steps.push(end),
            }
            let result = run.finish();
            format!(
                "{{\"scenario\":\"mirror\",\"steps\":[{}],\"session\":{result}}}",
                steps.join(",")
            )
        }
        "hold" => {
            let seconds: u64 = arg.as_deref().unwrap_or("60").parse()?;
            let mut run = Run::start(&args, true, None)?;
            let first = run.next_config(Duration::from_secs(25));
            let streaming_ms = run.started.elapsed().as_millis();
            eprintln!("streaming");
            let end = match first {
                Ok(Some(_)) => {
                    let deadline = Instant::now() + Duration::from_secs(seconds);
                    loop {
                        match run.next_config(deadline.saturating_duration_since(Instant::now())) {
                            Ok(Some(_)) => {}
                            Ok(None) => break None,
                            Err(end) => break Some(end),
                        }
                    }
                }
                Ok(None) => None,
                Err(end) => Some(end),
            };
            let result = match end {
                Some(end) => run.result(&end),
                None => run.finish(),
            };
            format!(
                "{{\"scenario\":\"hold\",\"streaming_ms\":{streaming_ms},\"session\":{result}}}"
            )
        }
        "cycles" => {
            let count: u32 = arg.as_deref().unwrap_or("10").parse()?;
            let mut cycles = Vec::new();
            for _ in 0..count {
                let mut run = Run::start(&args, true, None)?;
                let streamed = matches!(run.next_config(Duration::from_secs(25)), Ok(Some(_)));
                // Some input queued at cancel time must not leak anywhere.
                for _ in 0..8 {
                    let _ = run.session.send_input(InputEvent::Key {
                        keycode: 30,
                        pressed: true,
                    });
                    let _ = run.session.send_input(InputEvent::Key {
                        keycode: 30,
                        pressed: false,
                    });
                }
                let cancel_at = Instant::now();
                let result = run.finish();
                cycles.push(format!(
                    "{{\"streamed\":{streamed},\"teardown_ms\":{},\"session\":{result}}}",
                    cancel_at.elapsed().as_millis()
                ));
            }
            format!(
                "{{\"scenario\":\"cycles\",\"cycles\":[{}]}}",
                cycles.join(",")
            )
        }
        other => return Err(format!("unknown scenario {other}").into()),
    };
    println!("{json}");
    Ok(())
}
