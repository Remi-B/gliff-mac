//! Contract fixture generator and recorder.
//!
//! - `synth` encodes deterministic synthetic frames with upstream's CPU
//!   encoder (`gliff_sw::Encoder`, the encoder `gliff-server --video cpu`
//!   uses) and frames them with upstream `gliff_transport::Framed`, in the
//!   message order `gliff-server` sends. It is server-equivalent, not a live
//!   server capture: no Hyprland capture, rate control or GPU encoder runs.
//! - `record` captures the raw server-to-client byte stream of a real
//!   `gliff-server --stdio`, over ssh or any command, acting as a minimal
//!   client (Hello, Pong, FrameAck after decode).
//! - `serve` replays a capture to one client on stdio, to test `record`.
//! - `describe` replays a capture through the client contract
//!   (`gliff_client_core::events`), decodes it with upstream's reference
//!   decoder and prints its manifest entry.

mod capture;
mod describe;
mod synth;

use std::path::PathBuf;
use std::process::ExitCode;

type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;

const USAGE: &str = "usage:
  gliff-fixture-gen synth --chroma single420|dual420 --out FILE [--png-dir DIR]
  gliff-fixture-gen record (--ssh HOST [--ssh-arg ARG]... [--server-arg ARG]... | --command PROGRAM [ARG]...)
                           --chroma single420|dual420 --frames N --out FILE
                           [--resize-after N --resize WxH]
  gliff-fixture-gen serve FILE
  gliff-fixture-gen describe FILE [--name NAME] [--provenance JSON] [--png-dir DIR]";

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .expect("tokio runtime");
    match runtime.block_on(run(args)) {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("gliff-fixture-gen: {e}");
            ExitCode::FAILURE
        }
    }
}

async fn run(args: Vec<String>) -> Result<()> {
    let Some((command, rest)) = args.split_first() else {
        return Err(USAGE.into());
    };
    let mut opts = Opts::parse(rest)?;
    match command.as_str() {
        "synth" => {
            synth::run(
                opts.chroma()?,
                &opts.path("--out")?,
                opts.optional_path("--png-dir"),
            )
            .await
        }
        "record" => capture::record(&mut opts).await,
        "serve" => capture::serve(&opts.positional(0)?).await,
        "describe" => describe::run(&opts).await,
        _ => Err(USAGE.into()),
    }
}

/// Minimal `--flag value` parsing; repeated flags keep every value, and
/// everything after `--command` belongs to the command.
pub struct Opts {
    pairs: Vec<(String, String)>,
    positional: Vec<String>,
    command: Vec<String>,
}

impl Opts {
    fn parse(args: &[String]) -> Result<Self> {
        let mut opts = Opts {
            pairs: Vec::new(),
            positional: Vec::new(),
            command: Vec::new(),
        };
        let mut it = args.iter();
        while let Some(arg) = it.next() {
            if arg == "--command" {
                opts.command = it.by_ref().cloned().collect();
                break;
            }
            if arg.starts_with("--") {
                let value = it.next().ok_or_else(|| format!("{arg} needs a value"))?;
                opts.pairs.push((arg.clone(), value.clone()));
            } else {
                opts.positional.push(arg.clone());
            }
        }
        Ok(opts)
    }

    pub fn get(&self, flag: &str) -> Option<&str> {
        self.pairs
            .iter()
            .rev()
            .find(|(k, _)| k == flag)
            .map(|(_, v)| v.as_str())
    }

    pub fn all(&self, flag: &str) -> Vec<String> {
        self.pairs
            .iter()
            .filter(|(k, _)| k == flag)
            .map(|(_, v)| v.clone())
            .collect()
    }

    pub fn require(&self, flag: &str) -> Result<&str> {
        self.get(flag)
            .ok_or_else(|| format!("missing {flag}\n{USAGE}").into())
    }

    pub fn path(&self, flag: &str) -> Result<PathBuf> {
        self.require(flag).map(PathBuf::from)
    }

    pub fn optional_path(&self, flag: &str) -> Option<PathBuf> {
        self.get(flag).map(PathBuf::from)
    }

    pub fn positional(&self, i: usize) -> Result<PathBuf> {
        self.positional
            .get(i)
            .map(PathBuf::from)
            .ok_or_else(|| USAGE.into())
    }

    pub fn command(&self) -> &[String] {
        &self.command
    }

    pub fn chroma(&self) -> Result<gliff_proto::ChromaMode> {
        match self.require("--chroma")? {
            "single420" => Ok(gliff_proto::ChromaMode::Single420),
            "dual420" => Ok(gliff_proto::ChromaMode::Dual420),
            other => Err(format!("unsupported --chroma {other}").into()),
        }
    }
}
