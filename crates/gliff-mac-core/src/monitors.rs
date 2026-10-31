//! Orphaned virtual monitors (task 14): `gliff-<pid>` headless outputs that a
//! server which no longer runs left in Hyprland. A server killed with SIGKILL
//! never removes its output, and one whose output a monitor tool disabled
//! cannot remove it (Hyprland does not find disabled outputs).
//!
//! Each check or removal is a separate SSH command with the session's policy
//! (`ssh::ssh`): a fixed script (`orphans.sh`) on stdin, a strict line format
//! on stdout, a time limit, and the process group reaped on cancellation.
//! Nothing here involves the Gliff session itself.

use std::{os::unix::process::CommandExt, sync::Arc, time::Duration};

use rustix::process::Pid;
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    process::Command,
    sync::watch,
};

use crate::{
    session::runtime,
    ssh::{self, ProcessGroup},
    types::{ConnectionTarget, GliffError},
};

const SCRIPT: &str = include_str!("orphans.sh");
const PREFIX: &str = "gliff-orphans 1 ";
/// SSH may take its 10-second connect timeout, then the script runs.
const CHECK_LIMIT: Duration = Duration::from_secs(30);
/// Each output can take a few seconds to enable and verify.
const REMOVE_LIMIT: Duration = Duration::from_secs(60);
/// A report is a few lines per output: anything larger is not ours.
const STDOUT_LIMIT: usize = 64 * 1024;
/// More outputs than this in one report or request is refused.
pub const MAX_OUTPUTS: usize = 64;

/// A `gliff-<pid>` output whose server does not run.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct OrphanedOutput {
    pub name: String,
    /// Its mode in pixels; 0 when Hyprland did not report one.
    pub width: u32,
    pub height: u32,
    /// Disabled outputs (by a monitor tool, for example) count too.
    pub enabled: bool,
}

/// Why a host cannot be checked. Not an error: such a host has no orphans.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum CheckUnavailable {
    /// `hyprctl` is not on the remote PATH.
    NoHyprctl,
    /// No Hyprland instance of this user answers.
    NoHyprland,
    /// Hyprland answered, then did not list its monitors.
    HyprctlFailed,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum OrphanCheck {
    Found { outputs: Vec<OrphanedOutput> },
    Unavailable { reason: CheckUnavailable },
    Cancelled,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum RemovalOutcome {
    /// The output is gone (removed now, or already gone).
    Removed,
    /// Its server runs again: kept.
    InUse,
    /// Still present after the removal, or not reported.
    Failed,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct OutputRemoval {
    pub name: String,
    pub outcome: RemovalOutcome,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum OrphanRemoval {
    /// One result per requested output, in request order.
    Finished {
        results: Vec<OutputRemoval>,
    },
    Unavailable {
        reason: CheckUnavailable,
    },
    Cancelled,
}

/// Checks and cleans one host's orphaned Gliff outputs. Independent of any
/// session: create one per check, and `cancel` it with its window or session.
#[derive(uniffi::Object)]
pub struct HostMonitors {
    target: ConnectionTarget,
    cancel: watch::Sender<bool>,
}

#[uniffi::export]
impl HostMonitors {
    /// Accepts SSH targets only; validated like a session's.
    #[uniffi::constructor]
    pub fn new(target: ConnectionTarget) -> Result<Arc<Self>, GliffError> {
        target.validate()?;
        if !matches!(target, ConnectionTarget::Ssh { .. }) {
            return Err(GliffError::InvalidOptions {
                message: "monitor cleanup needs an SSH target".into(),
            });
        }
        Ok(Arc::new(Self {
            target,
            cancel: watch::channel(false).0,
        }))
    }

    /// Lists the host's orphaned outputs. Fails only when SSH or the report
    /// fails; a host without Hyprland is `Unavailable`.
    pub async fn find_orphans(&self) -> Result<OrphanCheck, GliffError> {
        let run = self.spawn(vec!["check".into()], CHECK_LIMIT);
        Ok(match run.await? {
            Run::Cancelled => OrphanCheck::Cancelled,
            Run::Output(stdout) => parse_check(&stdout)?,
        })
    }

    /// Removes `names`, re-checking each one's server right before.
    pub async fn remove_orphans(&self, names: Vec<String>) -> Result<OrphanRemoval, GliffError> {
        let names = validate_names(names)?;
        let mut args = vec!["remove".to_owned()];
        args.extend(names.iter().cloned());
        let run = self.spawn(args, REMOVE_LIMIT);
        Ok(match run.await? {
            Run::Cancelled => OrphanRemoval::Cancelled,
            Run::Output(stdout) => parse_removal(&stdout, &names)?,
        })
    }

    /// Stops a running or later check or removal. Idempotent.
    pub fn cancel(&self) {
        self.cancel.send_replace(true);
    }
}

impl Drop for HostMonitors {
    fn drop(&mut self) {
        self.cancel();
    }
}

impl HostMonitors {
    fn spawn(
        &self,
        args: Vec<String>,
        limit: Duration,
    ) -> impl std::future::Future<Output = Result<Run, GliffError>> {
        let target = self.target.clone();
        let cancel = self.cancel.subscribe();
        on_runtime(async move {
            let policy = ssh::policy_config("~/.ssh/config", "/etc/ssh/ssh_config").map_err(|_| {
                GliffError::Transport {
                    message: "Cannot create the private SSH policy file. Check temporary-directory access.".into(),
                }
            })?;
            // Fixed words: `check`, `remove` and validated output names.
            let remote = format!("sh -s -- {}", args.join(" "));
            // Keep the policy file until SSH and its jump helpers stop.
            let command = ssh::ssh(&target, policy.path(), &[], &remote);
            run_bounded(command, SCRIPT.as_bytes(), limit, cancel).await
        })
    }
}

/// Runs `work` on the bridge runtime, so the caller's executor only awaits.
/// Dropping the returned future aborts `work`, which kills its process group.
fn on_runtime(
    work: impl std::future::Future<Output = Result<Run, GliffError>> + Send + 'static,
) -> impl std::future::Future<Output = Result<Run, GliffError>> {
    struct AbortOnDrop(tokio::task::JoinHandle<Result<Run, GliffError>>);
    impl Drop for AbortOnDrop {
        fn drop(&mut self) {
            self.0.abort();
        }
    }
    let mut task = AbortOnDrop(runtime().spawn(work));
    async move {
        (&mut task.0).await.unwrap_or_else(|_| {
            Err(GliffError::Protocol {
                message: "the monitor check stopped unexpectedly".into(),
            })
        })
    }
}

#[derive(Debug)]
enum Run {
    Output(String),
    Cancelled,
}

/// Runs `command` in its own process group with `stdin` as its input, and
/// returns its output once it exits successfully. The group is terminated
/// on cancellation, on the time limit and when this future is dropped.
async fn run_bounded(
    mut command: Command,
    stdin: &[u8],
    limit: Duration,
    mut cancel: watch::Receiver<bool>,
) -> Result<Run, GliffError> {
    if *cancel.borrow() {
        return Ok(Run::Cancelled);
    }
    command.as_std_mut().process_group(0);
    let mut child = command.spawn().map_err(|_| GliffError::Transport {
        message: "Cannot launch /usr/bin/ssh. Check the system OpenSSH installation.".into(),
    })?;
    let mut group = ProcessGroup {
        pid: Pid::from_raw(child.id().expect("spawned child") as i32).expect("positive pid"),
        armed: true,
    };
    let mut input = child.stdin.take().expect("piped stdin");
    let mut stdout = child.stdout.take().expect("piped stdout");
    let mut stderr = child.stderr.take().expect("piped stderr");
    let work = async {
        // The script is small; a peer that exits early just closes the pipe.
        let write = async {
            let _ = input.write_all(stdin).await;
            drop(input);
        };
        let read = async {
            let mut out = Vec::new();
            let mut chunk = [0; 4096];
            loop {
                match stdout.read(&mut chunk).await {
                    Ok(0) | Err(_) => break,
                    Ok(n) => {
                        let room = STDOUT_LIMIT + 1 - out.len().min(STDOUT_LIMIT + 1);
                        out.extend_from_slice(&chunk[..n.min(room)]);
                    }
                }
            }
            out
        };
        let errors = async {
            let mut kept = Vec::new();
            let mut chunk = [0; 4096];
            loop {
                match stderr.read(&mut chunk).await {
                    Ok(0) | Err(_) => break,
                    Ok(n) => {
                        let room = 16384 - kept.len().min(16384);
                        kept.extend_from_slice(&chunk[..n.min(room)]);
                    }
                }
            }
            kept
        };
        let ((), out, errors) = tokio::join!(write, read, errors);
        (out, errors, child.wait().await)
    };
    let finished = tokio::select! {
        result = tokio::time::timeout(limit, work) => Some(result),
        // A closed channel never cancels: dropping `HostMonitors` sends
        // `true` first.
        _ = async {
            if cancel.wait_for(|cancelled| *cancelled).await.is_err() {
                std::future::pending::<()>().await;
            }
        } => None,
    };
    // Also covers SSH exiting while a proxy helper or remote child lingers.
    group.terminate().await;
    group.armed = false;
    let Some(result) = finished else {
        return Ok(Run::Cancelled);
    };
    let Ok((out, errors, status)) = result else {
        return Err(GliffError::Transport {
            message: "The monitor check timed out.".into(),
        });
    };
    if !status.is_ok_and(|status| status.success()) {
        return Err(ssh::diagnostic(&errors));
    }
    if out.len() > STDOUT_LIMIT {
        return Err(report_error("the report is too large"));
    }
    Ok(Run::Output(String::from_utf8_lossy(&out).into_owned()))
}

fn report_error(what: &str) -> GliffError {
    GliffError::Protocol {
        message: format!("invalid monitor report: {what}"),
    }
}

/// `gliff-<pid>`: digits only, no leading zero, at most 7 digits, as the
/// script checks too.
fn is_output_name(name: &str) -> bool {
    name.strip_prefix("gliff-").is_some_and(|pid| {
        (1..=7).contains(&pid.len())
            && pid.bytes().all(|b| b.is_ascii_digit())
            && !pid.starts_with('0')
    })
}

fn validate_names(names: Vec<String>) -> Result<Vec<String>, GliffError> {
    let mut unique: Vec<String> = Vec::new();
    for name in names {
        if !is_output_name(&name) {
            return Err(GliffError::InvalidOptions {
                message: "only gliff-<pid> outputs can be removed".into(),
            });
        }
        if !unique.contains(&name) {
            unique.push(name);
        }
    }
    if unique.is_empty() || unique.len() > MAX_OUTPUTS {
        return Err(GliffError::InvalidOptions {
            message: format!("between 1 and {MAX_OUTPUTS} outputs can be removed at once"),
        });
    }
    Ok(unique)
}

/// A decimal `u32` without sign or leading zero, at most 5 digits.
fn dimension(text: &str) -> Option<u32> {
    let valid = (1..=5).contains(&text.len())
        && text.bytes().all(|b| b.is_ascii_digit())
        && (text == "0" || !text.starts_with('0'));
    valid.then(|| text.parse().ok()).flatten()
}

enum Report<'a> {
    Unavailable(CheckUnavailable),
    /// The entries between `begin` and `end`, split into words.
    Entries(Vec<Vec<&'a str>>),
}

/// The framed part of the output. Lines before `begin` (a login shell's
/// noise) and after `end` are ignored; inside, every line must be a report
/// line and the count must match, or the whole report is rejected.
fn framed(stdout: &str) -> Result<Report<'_>, GliffError> {
    let mut lines = stdout.lines();
    loop {
        let Some(line) = lines.next() else {
            return Err(report_error("no report"));
        };
        let Some(rest) = line.strip_prefix(PREFIX) else {
            continue;
        };
        match rest {
            "begin" => break,
            "unavailable no-hyprctl" => {
                return Ok(Report::Unavailable(CheckUnavailable::NoHyprctl))
            }
            "unavailable no-hyprland" => {
                return Ok(Report::Unavailable(CheckUnavailable::NoHyprland))
            }
            "unavailable hyprctl-failed" => {
                return Ok(Report::Unavailable(CheckUnavailable::HyprctlFailed))
            }
            _ => return Err(report_error("unexpected line before the report")),
        }
    }
    let mut entries = Vec::new();
    for line in lines {
        let words: Vec<&str> = line
            .strip_prefix(PREFIX)
            .ok_or_else(|| report_error("a line is not a report line"))?
            .split(' ')
            .collect();
        if let ["end", count] = words.as_slice() {
            if count.parse::<usize>().ok() != Some(entries.len()) || count.starts_with('+') {
                return Err(report_error("the count does not match"));
            }
            return Ok(Report::Entries(entries));
        }
        if entries.len() == MAX_OUTPUTS {
            return Err(report_error("too many outputs"));
        }
        entries.push(words);
    }
    Err(report_error("the report is truncated"))
}

fn parse_check(stdout: &str) -> Result<OrphanCheck, GliffError> {
    let entries = match framed(stdout)? {
        Report::Unavailable(reason) => return Ok(OrphanCheck::Unavailable { reason }),
        Report::Entries(entries) => entries,
    };
    let mut outputs: Vec<OrphanedOutput> = Vec::new();
    for words in entries {
        let ["orphan", name, width, height, state] = words.as_slice() else {
            return Err(report_error("malformed output line"));
        };
        let (Some(width), Some(height)) = (dimension(width), dimension(height)) else {
            return Err(report_error("malformed size"));
        };
        let enabled = match *state {
            "enabled" => true,
            "disabled" => false,
            _ => return Err(report_error("malformed state")),
        };
        if !is_output_name(name) || outputs.iter().any(|o| o.name == *name) {
            return Err(report_error("malformed or repeated output name"));
        }
        outputs.push(OrphanedOutput {
            name: (*name).to_owned(),
            width,
            height,
            enabled,
        });
    }
    Ok(OrphanCheck::Found { outputs })
}

fn parse_removal(stdout: &str, names: &[String]) -> Result<OrphanRemoval, GliffError> {
    let entries = match framed(stdout)? {
        Report::Unavailable(reason) => return Ok(OrphanRemoval::Unavailable { reason }),
        Report::Entries(entries) => entries,
    };
    let mut outcomes: Vec<Option<RemovalOutcome>> = vec![None; names.len()];
    for words in entries {
        let [verb, name] = words.as_slice() else {
            return Err(report_error("malformed result line"));
        };
        let outcome = match *verb {
            "removed" => RemovalOutcome::Removed,
            "in-use" => RemovalOutcome::InUse,
            "failed" => RemovalOutcome::Failed,
            _ => return Err(report_error("unknown result")),
        };
        let Some(index) = names.iter().position(|n| n == name) else {
            return Err(report_error(
                "a result for an output that was not requested",
            ));
        };
        if outcomes[index].replace(outcome).is_some() {
            return Err(report_error("a repeated result"));
        }
    }
    Ok(OrphanRemoval::Finished {
        results: names
            .iter()
            .zip(outcomes)
            .map(|(name, outcome)| OutputRemoval {
                name: name.clone(),
                // The script reports every name; a missing one did not finish.
                outcome: outcome.unwrap_or(RemovalOutcome::Failed),
            })
            .collect(),
    })
}

#[cfg(test)]
mod tests;
