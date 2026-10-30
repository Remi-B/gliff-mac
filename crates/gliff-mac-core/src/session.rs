//! The session object and its delegate.
//!
//! Threads: the driver runs on a shared two-thread Tokio runtime and never
//! calls Swift. Each started session owns one delivery thread that calls the
//! delegate, in wire order, and ends with exactly one `on_ended`; the
//! delegate is released right after. A slow callback stalls the driver
//! through a bounded channel and the in-flight frame budget, not memory.

use std::sync::{Arc, Mutex, OnceLock};

use gliff_client_core::session::{self as core, Control, Delivery, Driver, FrameOutcome};
use tokio::runtime::Runtime;
use tokio::sync::mpsc;

use crate::types::*;

/// Deliveries queued between the driver and the delivery thread. Frames
/// are bounded separately by the in-flight budget.
const DELIVERY_QUEUE: usize = 32;

/// Receives one session's events on its delivery thread, never on the
/// network thread or the main thread. Callbacks run one at a time, in wire
/// order; a callback must return promptly and hop to the main actor for UI
/// state. No callback follows `on_ended`.
#[uniffi::export(with_foreign)]
pub trait SessionDelegate: Send + Sync {
    fn on_connected(&self, hello: ServerHello);
    /// Before the first frame of its revision. `rebuild` replaces the
    /// decoder; frames of older generations are discarded by the bridge.
    fn on_video_config(&self, config: VideoConfig);
    /// Report every frame with `GliffSession::report_decode` when the
    /// decoder completes it, whatever the outcome; no more frames arrive
    /// while the in-flight budget is used up.
    fn on_frame(&self, frame: EncodedFrame);
    fn on_cursor_shape(&self, shape: CursorShape);
    fn on_cursor_position(&self, position: CursorPosition);
    /// A recoverable server error; the server ends the session after it.
    fn on_server_error(&self, code: u16, message: String);
    fn on_ended(&self, end: SessionEnd);
}

fn runtime() -> &'static Runtime {
    static RUNTIME: OnceLock<Runtime> = OnceLock::new();
    RUNTIME.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .thread_name("gliff-net")
            .enable_all()
            .build()
            .expect("cannot start the Gliff network runtime")
    })
}

pub(crate) enum Item {
    Delivery(Delivery),
    Ended(SessionEnd),
}

impl From<Delivery> for Item {
    fn from(d: Delivery) -> Self {
        Self::Delivery(d)
    }
}

/// One connection attempt. Start it once; create a new session to reconnect.
#[derive(uniffi::Object)]
pub struct GliffSession {
    config: core::SessionConfig,
    terminal: Arc<Mutex<Option<SessionState>>>,
    control: Arc<Control>,
    /// Taken by `start`.
    pending: Mutex<Option<(ConnectionTarget, Driver)>>,
}

#[uniffi::export]
impl GliffSession {
    /// Validate the target and options; nothing is started yet.
    #[uniffi::constructor]
    pub fn new(target: ConnectionTarget, options: SessionOptions) -> Result<Arc<Self>, GliffError> {
        target.validate()?;
        // SSH and replay advertise the configured chroma modes: `ChromaMode`
        // only has the two the native decoder implements (Dual420 since
        // task 08, Single420), so nothing else can reach the server.
        let config = options.to_core()?;
        let (control, driver) = Control::new(config.budget);
        Ok(Arc::new(Self {
            config,
            terminal: Arc::new(Mutex::new(None)),
            control,
            pending: Mutex::new(Some((target, driver))),
        }))
    }

    /// Start the session; events go to `delegate` until `on_ended`.
    pub fn start(&self, delegate: Arc<dyn SessionDelegate>) -> Result<(), GliffError> {
        let mut pending = self.pending.lock().unwrap_or_else(|e| e.into_inner());
        let Some((target, driver)) = pending.take() else {
            return Err(GliffError::AlreadyStarted);
        };
        let (tx, rx) = mpsc::channel(DELIVERY_QUEUE);
        let control = self.control.clone();
        std::thread::Builder::new()
            .name("gliff-delivery".into())
            .spawn(move || deliver(rx, delegate, control))
            .map_err(|e| GliffError::Transport {
                message: format!("cannot start the delivery thread: {e}"),
            })?;
        let mut config = self.config.clone();
        let control = self.control.clone();
        let terminal = self.terminal.clone();
        runtime().spawn(async move {
            let end = match target {
                ConnectionTarget::Replay { stream } => {
                    config.drain_on_close = true;
                    match core::run(
                        std::io::Cursor::new(stream),
                        tokio::io::sink(),
                        config,
                        driver,
                        tx.clone(),
                    )
                    .await
                    {
                        Ok(core::SessionEnd::Closed) => SessionEnd::Closed,
                        Ok(core::SessionEnd::Cancelled) => SessionEnd::Cancelled,
                        Err(e) => SessionEnd::Failed { error: e.into() },
                    }
                }
                target => crate::ssh::run(target, config, driver, tx.clone(), control).await,
            };
            *terminal.lock().unwrap_or_else(|e| e.into_inner()) =
                Some(if matches!(end, SessionEnd::Failed { .. }) {
                    SessionState::Failed
                } else {
                    SessionState::Closed
                });
            // The delivery thread drains until this item, so it always
            // arrives and is the last callback.
            let _ = tx.send(Item::Ended(end)).await;
        });
        Ok(())
    }

    /// Report a delivered frame's decode outcome. Acks are written in
    /// `frame_id` order, so report every frame, including failures.
    pub fn report_decode(&self, frame_id: u64, outcome: DecodeOutcome) -> Result<(), GliffError> {
        Ok(self.control.report(frame_id, outcome.into())?)
    }

    /// Queue input for the server. Fails with `Busy` rather than buffering
    /// without bound, and with `NotRunning` after the session ended.
    pub fn send_input(&self, event: InputEvent) -> Result<(), GliffError> {
        Ok(self.control.send_input(event.into())?)
    }

    /// Stop the session. Idempotent and non-blocking: queued events are
    /// dropped and `on_ended(Cancelled)` follows (unless it already ended).
    pub fn cancel(&self) {
        self.control.cancel();
    }

    pub fn state(&self) -> SessionState {
        if let Some(state) = *self.terminal.lock().unwrap_or_else(|e| e.into_inner()) {
            return state;
        }
        if self.control.is_cancelled() || !self.control.is_running() {
            return SessionState::Stopping;
        }
        if self.control.generation() > 0 {
            return SessionState::Streaming;
        }
        if self
            .pending
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .is_some()
        {
            SessionState::Connecting
        } else {
            SessionState::Handshaking
        }
    }

    pub fn stats(&self) -> SessionStats {
        self.control.stats().into()
    }
}

impl Drop for GliffSession {
    /// Dropping the last reference cancels a running session. It does not
    /// wait: the delivery thread may be the one dropping it.
    fn drop(&mut self) {
        self.control.cancel();
    }
}

fn deliver(
    mut rx: mpsc::Receiver<Item>,
    delegate: Arc<dyn SessionDelegate>,
    control: Arc<Control>,
) {
    while let Some(item) = rx.blocking_recv() {
        let delivery = match item {
            Item::Ended(end) => {
                delegate.on_ended(end);
                return;
            }
            Item::Delivery(delivery) => delivery,
        };
        if control.is_cancelled() {
            continue;
        }
        match delivery {
            Delivery::HelloAck {
                session,
                outputs,
                features,
            } => delegate.on_connected(ServerHello {
                headless: session.headless,
                output: session.output,
                outputs: outputs
                    .into_iter()
                    .map(|o| OutputInfo {
                        name: o.name,
                        width: o.width,
                        height: o.height,
                        scale_milli: o.scale_milli,
                    })
                    .collect(),
                features,
            }),
            Delivery::Config(config) => delegate.on_video_config(config.into()),
            Delivery::Frame(frame)
                if !control.should_deliver(frame.frame_id, frame.generation, frame.keyframe) =>
            {
                // A newer configuration replaced this decoder generation, or
                // the reference was lost and this predicted frame cannot
                // decode before the next keyframe.
                let _ = control.report(frame.frame_id, FrameOutcome::Discarded);
            }
            Delivery::Frame(frame) => {
                control.count_delivered();
                delegate.on_frame(frame.into());
            }
            Delivery::CursorShape {
                id,
                width,
                height,
                hot_x,
                hot_y,
                argb,
            } => delegate.on_cursor_shape(CursorShape {
                id,
                width,
                height,
                hot_x,
                hot_y,
                argb: argb.map(|a| a.to_vec()),
            }),
            Delivery::CursorPos {
                x,
                y,
                shape_id,
                visible,
            } => delegate.on_cursor_position(CursorPosition {
                x,
                y,
                shape_id,
                visible,
            }),
            Delivery::ServerError { code, message } => delegate.on_server_error(code, message),
        }
    }
    // The driver task stopped without reporting (it panicked).
    delegate.on_ended(SessionEnd::Failed {
        error: GliffError::Protocol {
            message: "the session task stopped unexpectedly".into(),
        },
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Since task 08 an SSH session advertises the native decoder's modes
    /// as configured, Dual420 included, instead of forcing Single420.
    #[test]
    fn ssh_targets_advertise_the_configured_chroma_modes() {
        let target = ConnectionTarget::Ssh {
            host: "host".into(),
            user: None,
            port: None,
            server_path: None,
            identity_file: None,
            headless: true,
        };
        for chroma in [
            vec![ChromaMode::Dual420, ChromaMode::Single420],
            vec![ChromaMode::Single420],
        ] {
            let options = SessionOptions {
                chroma: chroma.clone(),
                keymap: String::new(),
                max_in_flight_frames: 4,
                min_in_flight_bytes: 8 << 20,
            };
            let session = GliffSession::new(target.clone(), options).unwrap();
            let expected: Vec<_> = chroma
                .iter()
                .map(|mode| match mode {
                    ChromaMode::Single420 => gliff_proto::ChromaMode::Single420,
                    ChromaMode::Dual420 => gliff_proto::ChromaMode::Dual420,
                })
                .collect();
            assert_eq!(session.config.support.chroma, expected);
            assert_eq!(
                session.config.support.codecs,
                vec![gliff_proto::Codec::H264]
            );
        }
    }
}
