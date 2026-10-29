//! Transport-independent session driver.
//!
//! [`run`] owns one connection's reader and writer: it sends `Hello`, answers
//! `Ping` first, hands configurations and frames to the native side in wire
//! order, writes one `FrameAck` per accepted frame in `frame_id` order once
//! the native decoder reports it, forwards input and stops on cancellation.
//! The native side talks to it only through [`Control`], which is
//! thread-safe and never blocks: decode reports, input and cancellation.
//!
//! Back-pressure instead of loss: frames handed out and not yet reported are
//! "in flight". When the in-flight count or byte budget is reached the driver
//! stops reading, so the transport (the ssh pipe) fills up and the server
//! paces itself, as rule 8 of the session contract specifies. Other
//! deliveries go through a bounded channel, so a slow consumer stalls the
//! reader rather than growing memory.
//!
//! The SSH transport is added by task 05; the driver itself is the same for
//! a recorded stream and a live server.

use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use gliff_proto::{Axis, ClientCaps, ClientMsg, OutputInfo, SessionInfo, PROTOCOL_VERSION};
use gliff_transport::Framed;
use tokio::io::{AsyncRead, AsyncWrite};
use tokio::sync::{mpsc, watch, Notify};

use crate::events::{ServerEvent, ServerReader, SessionError};
use crate::video::{DecoderSupport, EncodedFrame, FrameDisposition, VideoConfig, MAX_DECODE};

/// How long a cancelled session may spend telling the server `Bye`.
const BYE_TIMEOUT: Duration = Duration::from_secs(1);
/// Input messages waiting for the writer; beyond this `send_input` fails.
pub const INPUT_QUEUE: usize = 256;

#[derive(Debug, Clone)]
pub struct SessionConfig {
    pub support: DecoderSupport,
    /// XKB keymap text, or empty for the server's default (US) map.
    pub keymap: String,
    pub budget: FrameBudget,
    /// When the server stream ends, wait for the frames still in flight to
    /// be reported and ack them before returning. For a recorded stream,
    /// whose writer outlives its reader; a live server is gone by then.
    pub drain_on_close: bool,
}

/// The in-flight frame bound: frames handed to the native side whose decode
/// has not been reported yet.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FrameBudget {
    pub max_frames: usize,
    /// Byte budget floor; it grows to twice the largest keyframe seen.
    pub min_bytes: u64,
}

impl Default for FrameBudget {
    /// The contract's initial values: 4 frames, 8 MiB.
    fn default() -> Self {
        Self {
            max_frames: 4,
            min_bytes: 8 << 20,
        }
    }
}

/// Input the native side sends; coordinates are in the remote's logical
/// space, key codes are Linux evdev codes.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum InputCommand {
    Key {
        keycode: u32,
        pressed: bool,
    },
    PointerMotion {
        x: f64,
        y: f64,
    },
    PointerButton {
        button: u32,
        pressed: bool,
    },
    PointerAxis {
        horizontal: bool,
        value: f64,
        discrete: Option<i32>,
        stop: bool,
    },
    Resize {
        width: u32,
        height: u32,
        scale: f32,
    },
}

impl InputCommand {
    fn into_msg(self) -> ClientMsg {
        match self {
            Self::Key { keycode, pressed } => ClientMsg::Key { keycode, pressed },
            Self::PointerMotion { x, y } => ClientMsg::PointerMotion { x, y },
            Self::PointerButton { button, pressed } => ClientMsg::PointerButton { button, pressed },
            Self::PointerAxis {
                horizontal,
                value,
                discrete,
                stop,
            } => ClientMsg::PointerAxis {
                axis: if horizontal {
                    Axis::Horizontal
                } else {
                    Axis::Vertical
                },
                value,
                discrete,
                stop,
            },
            Self::Resize {
                width,
                height,
                scale,
            } => ClientMsg::Resize {
                width,
                height,
                scale,
            },
        }
    }
}

/// What the driver hands to the native side, in wire order.
#[derive(Debug, Clone, PartialEq)]
pub enum Delivery {
    HelloAck {
        session: SessionInfo,
        outputs: Vec<OutputInfo>,
        features: Vec<String>,
    },
    Config(VideoConfig),
    /// Report it with [`Control::report`] once decoded, failed or discarded.
    Frame(EncodedFrame),
    CursorShape {
        id: u32,
        width: u32,
        height: u32,
        hot_x: i32,
        hot_y: i32,
        argb: Option<bytes::Bytes>,
    },
    CursorPos {
        x: f64,
        y: f64,
        shape_id: u32,
        visible: bool,
    },
    /// A recoverable server error; the server closes the session after it.
    ServerError {
        code: u16,
        message: String,
    },
}

/// How a session ended without an error.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SessionEnd {
    /// The server closed the stream between messages.
    Closed,
    Cancelled,
}

/// What became of a frame handed to the native side.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FrameOutcome {
    Decoded,
    /// The native decoder failed: the reference is lost and a keyframe is
    /// requested, unless the frame belongs to an older generation.
    Failed,
    /// Never decoded: an older generation's frame or a cancelled session.
    Discarded,
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum ControlError {
    #[error("the session is not running")]
    NotRunning,
    #[error("the input queue is full")]
    Busy,
    #[error("frame {0} is not awaiting a decode report")]
    UnknownFrame(u64),
}

/// Counters for tests, diagnostics and later statistics.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Stats {
    pub configs: u64,
    /// Frames handed to the decoder (see [`Control::count_delivered`]).
    pub frames_delivered: u64,
    /// Frames acked without decoding: awaiting a keyframe, older generation
    /// or cancelled.
    pub frames_dropped: u64,
    pub frames_failed: u64,
    pub acks_sent: u64,
    pub keyframe_requests: u64,
    pub pongs_sent: u64,
    pub inputs_sent: u64,
    pub peak_in_flight_frames: u64,
    pub peak_in_flight_bytes: u64,
}

#[derive(Default)]
struct Counters {
    configs: AtomicU64,
    frames_delivered: AtomicU64,
    frames_dropped: AtomicU64,
    frames_failed: AtomicU64,
    acks_sent: AtomicU64,
    keyframe_requests: AtomicU64,
    pongs_sent: AtomicU64,
    inputs_sent: AtomicU64,
    peak_in_flight_frames: AtomicU64,
    peak_in_flight_bytes: AtomicU64,
}

fn bump(counter: &AtomicU64) {
    counter.fetch_add(1, Ordering::Relaxed);
}

/// Frames handed out, in `frame_id` order, until acknowledged.
struct Flight {
    entries: VecDeque<Entry>,
    bytes: u64,
    budget: FrameBudget,
    largest_keyframe: u64,
    lose_reference: bool,
    running: bool,
}

struct Entry {
    frame_id: u64,
    generation: u32,
    bytes: u64,
    outcome: Option<FrameOutcome>,
}

impl Flight {
    fn byte_budget(&self) -> u64 {
        self.budget
            .min_bytes
            .max(self.largest_keyframe.saturating_mul(2))
    }

    fn has_capacity(&self) -> bool {
        self.entries.len() < self.budget.max_frames && self.bytes < self.byte_budget()
    }
}

/// The thread-safe side of one session. Every method returns at once.
pub struct Control {
    cancel: watch::Sender<bool>,
    flight: Mutex<Flight>,
    /// Wakes the driver: a report completed an ack, or capacity opened.
    wake: Notify,
    input: mpsc::Sender<ClientMsg>,
    generation: AtomicU32,
    /// Set by a reference loss, cleared by the next delivered keyframe.
    reference_lost: AtomicBool,
    /// The last keyframe delivered: older frames cannot lose the reference.
    last_keyframe: AtomicU64,
    counters: Counters,
    started: AtomicBool,
}

/// The driver's half of a [`Control`], consumed by [`run`].
pub struct Driver {
    control: Arc<Control>,
    input: mpsc::Receiver<ClientMsg>,
}

impl Control {
    pub fn new(budget: FrameBudget) -> (Arc<Self>, Driver) {
        let (input_tx, input_rx) = mpsc::channel(INPUT_QUEUE);
        let control = Arc::new(Self {
            cancel: watch::Sender::new(false),
            flight: Mutex::new(Flight {
                entries: VecDeque::new(),
                bytes: 0,
                budget,
                largest_keyframe: 0,
                lose_reference: false,
                running: true,
            }),
            wake: Notify::new(),
            input: input_tx,
            generation: AtomicU32::new(0),
            reference_lost: AtomicBool::new(false),
            last_keyframe: AtomicU64::new(0),
            counters: Counters::default(),
            started: AtomicBool::new(false),
        });
        let driver = Driver {
            control: control.clone(),
            input: input_rx,
        };
        (control, driver)
    }

    fn flight(&self) -> MutexGuard<'_, Flight> {
        // A panic while holding the lock leaves consistent data: every
        // critical section is a few field updates.
        self.flight.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Stop the session. Idempotent; the driver writes `Bye` and returns.
    pub fn cancel(&self) {
        self.cancel.send_replace(true);
    }

    pub fn is_cancelled(&self) -> bool {
        *self.cancel.borrow()
    }

    /// Whether the driver is still running (or not started yet).
    pub fn is_running(&self) -> bool {
        self.flight().running
    }

    /// The current decoder generation; frames of older ones are discarded.
    pub fn generation(&self) -> u32 {
        self.generation.load(Ordering::Acquire)
    }

    /// Report what became of a delivered frame. The ack is written once
    /// every earlier frame has been reported too.
    pub fn report(&self, frame_id: u64, outcome: FrameOutcome) -> Result<(), ControlError> {
        let mut flight = self.flight();
        if !flight.running {
            return Err(ControlError::NotRunning);
        }
        let current = self.generation();
        let entry = flight
            .entries
            .iter_mut()
            .find(|e| e.frame_id == frame_id && e.outcome.is_none())
            .ok_or(ControlError::UnknownFrame(frame_id))?;
        entry.outcome = Some(outcome);
        let stale = entry.generation != current;
        match outcome {
            FrameOutcome::Decoded => {}
            FrameOutcome::Failed => bump(&self.counters.frames_failed),
            FrameOutcome::Discarded => bump(&self.counters.frames_dropped),
        }
        // A failed or abandoned frame of the current generation leaves the
        // decoder without a valid reference. It does not matter for a
        // replaced generation, a cancelled session, a loss already being
        // recovered, or a frame older than the last keyframe delivered.
        let lost = outcome != FrameOutcome::Decoded
            && !stale
            && !self.is_cancelled()
            && !self.reference_lost.load(Ordering::Acquire)
            && frame_id >= self.last_keyframe.load(Ordering::Acquire);
        if lost {
            flight.lose_reference = true;
            self.reference_lost.store(true, Ordering::Release);
        }
        drop(flight);
        self.wake.notify_one();
        Ok(())
    }

    /// Whether a frame waiting for delivery should still reach the decoder:
    /// not when a newer generation replaced its decoder, nor when it is a
    /// predicted frame after a reference loss (until the next keyframe).
    /// Report the frame `Discarded` when this returns false.
    pub fn should_deliver(&self, frame_id: u64, generation: u32, keyframe: bool) -> bool {
        if generation < self.generation() {
            return false;
        }
        if keyframe {
            self.last_keyframe.store(frame_id, Ordering::Release);
            self.reference_lost.store(false, Ordering::Release);
            return true;
        }
        !self.reference_lost.load(Ordering::Acquire)
    }

    /// Count a frame actually handed to the decoder. Frames of a replaced
    /// generation are reported `Discarded` instead.
    pub fn count_delivered(&self) {
        bump(&self.counters.frames_delivered);
    }

    /// Queue an input message for the server.
    pub fn send_input(&self, input: InputCommand) -> Result<(), ControlError> {
        if !self.is_running() || self.is_cancelled() {
            return Err(ControlError::NotRunning);
        }
        self.input.try_send(input.into_msg()).map_err(|e| match e {
            mpsc::error::TrySendError::Full(_) => ControlError::Busy,
            mpsc::error::TrySendError::Closed(_) => ControlError::NotRunning,
        })
    }

    pub fn stats(&self) -> Stats {
        let c = &self.counters;
        let get = |a: &AtomicU64| a.load(Ordering::Relaxed);
        Stats {
            configs: get(&c.configs),
            frames_delivered: get(&c.frames_delivered),
            frames_dropped: get(&c.frames_dropped),
            frames_failed: get(&c.frames_failed),
            acks_sent: get(&c.acks_sent),
            keyframe_requests: get(&c.keyframe_requests),
            pongs_sent: get(&c.pongs_sent),
            inputs_sent: get(&c.inputs_sent),
            peak_in_flight_frames: get(&c.peak_in_flight_frames),
            peak_in_flight_bytes: get(&c.peak_in_flight_bytes),
        }
    }

    fn admit(&self, frame_id: u64, generation: u32, bytes: u64, outcome: Option<FrameOutcome>) {
        let mut flight = self.flight();
        flight.entries.push_back(Entry {
            frame_id,
            generation,
            bytes,
            outcome,
        });
        flight.bytes += bytes;
        let c = &self.counters;
        c.peak_in_flight_frames
            .fetch_max(flight.entries.len() as u64, Ordering::Relaxed);
        c.peak_in_flight_bytes
            .fetch_max(flight.bytes, Ordering::Relaxed);
    }

    /// Pop the reported prefix: the frames to ack now, in order, and
    /// whether a decode failure needs a keyframe.
    fn take_ready(&self) -> (Vec<u64>, bool) {
        let mut flight = self.flight();
        let mut acks = Vec::new();
        while flight.entries.front().is_some_and(|e| e.outcome.is_some()) {
            let entry = flight.entries.pop_front().expect("checked");
            flight.bytes -= entry.bytes;
            acks.push(entry.frame_id);
        }
        (acks, std::mem::take(&mut flight.lose_reference))
    }

    fn finish(&self) {
        let mut flight = self.flight();
        flight.running = false;
        flight.entries.clear();
        flight.bytes = 0;
    }
}

/// Run one session over `reader`/`writer` until the server closes, an error
/// occurs or [`Control::cancel`] is called. Deliveries are sent in wire
/// order; `deliveries` should be bounded.
pub async fn run<R, W, T>(
    reader: R,
    writer: W,
    config: SessionConfig,
    driver: Driver,
    deliveries: mpsc::Sender<T>,
) -> Result<SessionEnd, SessionError>
where
    R: AsyncRead + Unpin,
    W: AsyncWrite + Unpin,
    T: From<Delivery>,
{
    let Driver { control, input } = driver;
    let started = control.started.swap(true, Ordering::AcqRel);
    assert!(!started, "a Control drives one session");
    let mut session = Session {
        reader: ServerReader::new(reader, config.support.clone()),
        writer: Framed::new(writer),
        control: control.clone(),
        input,
        cancel: control.cancel.subscribe(),
        deliveries,
        writing: false,
    };
    // Cancellation also interrupts a write blocked on a peer that stopped
    // reading, so teardown never waits on the network beyond BYE_TIMEOUT.
    let mut cancel = control.cancel.subscribe();
    let result = tokio::select! {
        biased;
        _ = cancel.wait_for(|c| *c) => Ok(SessionEnd::Cancelled),
        result = session.drive(&config) => result,
    };
    // After an interrupted write the stream is mid-frame: a Bye would be
    // garbage, and closing is all that is left.
    if matches!(result, Ok(SessionEnd::Cancelled)) && !session.writing {
        let _ = tokio::time::timeout(BYE_TIMEOUT, session.writer.write_msg(&ClientMsg::Bye)).await;
    }
    control.finish();
    result
}

struct Session<R, W, T> {
    reader: ServerReader<R>,
    writer: Framed<W>,
    control: Arc<Control>,
    input: mpsc::Receiver<ClientMsg>,
    cancel: watch::Receiver<bool>,
    deliveries: mpsc::Sender<T>,
    /// A write is in progress; still set if cancellation interrupted it.
    writing: bool,
}

/// The driver stopped because of cancellation.
struct Cancelled;

/// What woke the driver.
enum Step {
    Cancel,
    Wake,
    Input(ClientMsg),
    Event(Result<ServerEvent, SessionError>),
}

impl<R, W, T> Session<R, W, T>
where
    R: AsyncRead + Unpin,
    W: AsyncWrite + Unpin,
    T: From<Delivery>,
{
    async fn drive(&mut self, config: &SessionConfig) -> Result<SessionEnd, SessionError> {
        let (max_width, max_height) = MAX_DECODE;
        let hello = ClientMsg::Hello {
            version: PROTOCOL_VERSION,
            keymap: config.keymap.clone(),
            caps: ClientCaps {
                codecs: config.support.codecs.clone(),
                max_width,
                max_height,
                chroma: config.support.chroma.clone(),
                // Only behaviours this client implements; none yet.
                features: Vec::new(),
            },
        };
        self.write(&hello).await?;
        loop {
            if *self.cancel.borrow() {
                return Ok(SessionEnd::Cancelled);
            }
            self.flush().await?;
            let can_read = self.control.flight().has_capacity();
            let step = tokio::select! {
                biased;
                _ = self.cancel.wait_for(|c| *c) => Step::Cancel,
                _ = self.control.wake.notified() => Step::Wake,
                Some(msg) = self.input.recv() => Step::Input(msg),
                event = self.reader.next_event(), if can_read => Step::Event(event),
            };
            match step {
                Step::Cancel => return Ok(SessionEnd::Cancelled),
                Step::Wake => {}
                Step::Input(msg) => {
                    self.write(&msg).await?;
                    bump(&self.control.counters.inputs_sent);
                }
                Step::Event(Err(SessionError::Transport(gliff_transport::Error::Closed))) => {
                    return self.close(config.drain_on_close).await;
                }
                Step::Event(event) => {
                    if self.handle(event?).await?.is_err() {
                        return Ok(SessionEnd::Cancelled);
                    }
                }
            }
        }
    }

    async fn close(&mut self, drain: bool) -> Result<SessionEnd, SessionError> {
        if !drain {
            return Ok(SessionEnd::Closed);
        }
        loop {
            self.flush().await?;
            if self.control.flight().entries.is_empty() {
                return Ok(SessionEnd::Closed);
            }
            let cancelled = tokio::select! {
                biased;
                _ = self.cancel.wait_for(|c| *c) => true,
                _ = self.control.wake.notified() => false,
            };
            if cancelled {
                return Ok(SessionEnd::Cancelled);
            }
        }
    }

    /// Write the acks that are ready and a keyframe request after a decode
    /// failure.
    async fn flush(&mut self) -> Result<(), SessionError> {
        let (acks, lost) = self.control.take_ready();
        for frame_id in acks {
            let decoded_at_ms = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map_or(0, |d| d.as_millis() as u64);
            self.write(&ClientMsg::FrameAck {
                frame_id,
                decoded_at_ms,
            })
            .await?;
            bump(&self.control.counters.acks_sent);
        }
        if lost && self.reader.tracker_mut().lose_reference() {
            self.request_keyframe().await?;
        }
        Ok(())
    }

    async fn write(&mut self, msg: &ClientMsg) -> Result<(), SessionError> {
        self.writing = true;
        self.writer.write_msg(msg).await?;
        self.writing = false;
        Ok(())
    }

    async fn request_keyframe(&mut self) -> Result<(), SessionError> {
        self.write(&ClientMsg::RequestKeyframe).await?;
        bump(&self.control.counters.keyframe_requests);
        Ok(())
    }

    async fn handle(&mut self, event: ServerEvent) -> Result<Result<(), Cancelled>, SessionError> {
        let delivery = match event {
            ServerEvent::Ping { t } => {
                self.write(&ClientMsg::Pong { t }).await?;
                bump(&self.control.counters.pongs_sent);
                return Ok(Ok(()));
            }
            ServerEvent::Pong { .. } => return Ok(Ok(())),
            // Task 11 routes these to gliff_transport::clipboard; no
            // clipboard feature is advertised until then.
            ServerEvent::Clipboard { .. } => return Ok(Ok(())),
            ServerEvent::HelloAck {
                session,
                outputs,
                features,
            } => Delivery::HelloAck {
                session,
                outputs,
                features,
            },
            ServerEvent::Config(config) => {
                if config.rebuild {
                    self.control
                        .generation
                        .store(config.generation, Ordering::Release);
                }
                bump(&self.control.counters.configs);
                Delivery::Config(config)
            }
            ServerEvent::Frame(FrameDisposition::AwaitKeyframe {
                frame_id,
                request_keyframe,
            }) => {
                let generation = self.control.generation();
                self.control
                    .admit(frame_id, generation, 0, Some(FrameOutcome::Discarded));
                bump(&self.control.counters.frames_dropped);
                self.flush().await?;
                if request_keyframe {
                    self.request_keyframe().await?;
                }
                return Ok(Ok(()));
            }
            ServerEvent::Frame(FrameDisposition::Decode(frame)) => {
                let bytes = (frame.main.len() + frame.aux.as_ref().map_or(0, |a| a.len())) as u64;
                if frame.keyframe {
                    let mut flight = self.control.flight();
                    flight.largest_keyframe = flight.largest_keyframe.max(bytes);
                }
                self.control
                    .admit(frame.frame_id, frame.generation, bytes, None);
                Delivery::Frame(frame)
            }
            ServerEvent::CursorShape {
                id,
                width,
                height,
                hot_x,
                hot_y,
                argb,
            } => Delivery::CursorShape {
                id,
                width,
                height,
                hot_x,
                hot_y,
                argb,
            },
            ServerEvent::CursorPos {
                x,
                y,
                shape_id,
                visible,
            } => Delivery::CursorPos {
                x,
                y,
                shape_id,
                visible,
            },
            ServerEvent::Error { code, message } => Delivery::ServerError { code, message },
        };
        // A slow consumer stalls the reader here; cancellation still wins.
        tokio::select! {
            biased;
            _ = self.cancel.wait_for(|c| *c) => Ok(Err(Cancelled)),
            sent = self.deliveries.send(T::from(delivery)) => Ok(sent.map_err(|_| Cancelled)),
        }
    }
}
