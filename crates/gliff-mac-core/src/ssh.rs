//! System OpenSSH adapter. No local shell, raw flags, or raw remote commands.
use crate::{session::Item, types::*};
use gliff_client_core::{
    events::SessionError,
    session::{self as core, Control, Driver},
};
use rustix::process::{kill_process_group, test_kill_process_group, Pid, Signal};
use std::{
    error::Error, io::Write, os::unix::process::CommandExt, path::Path, process::Stdio, sync::Arc,
};
use tokio::{io::AsyncReadExt, process::Command, sync::mpsc};

fn quote(word: &str) -> String {
    format!("'{}'", word.replace('\'', "'\\''"))
}

// -F is propagated by OpenSSH to every generated ProxyJump command. Apply
// invariant options before including the ordinary user and system configs,
// so aliases, identities and jump chains retain their normal configuration.
fn policy_config(user: &str, system: &str) -> std::io::Result<tempfile::NamedTempFile> {
    let mut file = tempfile::Builder::new().prefix("gliff-ssh-").tempfile()?;
    writeln!(file, "Host *")?;
    for option in [
        "BatchMode yes",
        "StrictHostKeyChecking yes",
        "ConnectTimeout 10",
        "ConnectionAttempts 1",
        "ControlMaster no",
        "ControlPath none",
        "PermitLocalCommand no",
        "ClearAllForwardings yes",
        "ForwardAgent no",
        "ForwardX11 no",
        "ForwardX11Trusted no",
        "ForkAfterAuthentication no",
        "StdinNull no",
        "SessionType default",
        "RequestTTY no",
        "RemoteCommand none",
        "Tunnel no",
    ] {
        writeln!(file, "    {option}")?;
    }
    // Includes can leave their last Host/Match inactive: reset between files.
    writeln!(file, "Include {user}\nHost *\nInclude {system}")?;
    file.flush()?;
    Ok(file)
}

struct ProcessGroup {
    pid: Pid,
    armed: bool,
}

impl ProcessGroup {
    async fn terminate(&self) {
        if test_kill_process_group(self.pid) == Err(rustix::io::Errno::SRCH) {
            return;
        }
        let _ = kill_process_group(self.pid, Signal::TERM);
        let deadline = tokio::time::Instant::now() + std::time::Duration::from_millis(200);
        while test_kill_process_group(self.pid).is_ok() && tokio::time::Instant::now() < deadline {
            tokio::time::sleep(std::time::Duration::from_millis(10)).await;
        }
        if test_kill_process_group(self.pid).is_ok() {
            let _ = kill_process_group(self.pid, Signal::KILL);
        }
    }
}

impl Drop for ProcessGroup {
    fn drop(&mut self) {
        // Also covers a task panic/abort while a proxy helper is running.
        if self.armed {
            let _ = kill_process_group(self.pid, Signal::KILL);
        }
    }
}

fn command(target: &ConnectionTarget, policy: &Path) -> Command {
    let ConnectionTarget::Ssh {
        host,
        user,
        port,
        server_path,
        identity_file,
        headless,
    } = target
    else {
        unreachable!()
    };
    let mut cmd = Command::new("/usr/bin/ssh");
    cmd.arg("-F").arg(policy);
    cmd.args([
        "-T",
        "-oBatchMode=yes",
        "-oStrictHostKeyChecking=yes",
        "-oConnectTimeout=10",
        "-oConnectionAttempts=1",
        "-oServerAliveInterval=10",
        "-oServerAliveCountMax=2",
        "-oControlMaster=no",
        "-oControlPath=none",
        "-oPermitLocalCommand=no",
        "-oClearAllForwardings=yes",
        "-oForwardAgent=no",
        "-oForwardX11=no",
        "-oForwardX11Trusted=no",
    ]);
    if let Some(user) = user {
        cmd.args(["-l", user]);
    }
    if let Some(port) = port {
        cmd.args(["-p", &port.to_string()]);
    }
    if let Some(identity) = identity_file {
        cmd.args(["-i", identity]);
    }
    let remote = format!(
        "exec {} --stdio{}",
        quote(server_path.as_deref().unwrap_or("gliff-server")),
        if *headless { " --headless" } else { "" }
    );
    cmd.arg("--").arg(host).arg(remote);
    cmd.stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    cmd
}

// Raw diagnostics never cross the bridge: even paths and hostnames can be private.
fn diagnostic(bytes: &[u8]) -> String {
    let s = String::from_utf8_lossy(bytes).to_ascii_lowercase();
    if s.contains("timed out") {
        "SSH connection timed out before the protocol handshake. Check host reachability and any ProxyJump hosts."
    } else if s.contains("could not resolve hostname") || s.contains("connection refused") || s.contains("no route to host") {
        "SSH could not reach the host. Check the hostname or config alias, network and SSH service."
    } else if s.contains("host key verification failed") || s.contains("remote host identification has changed") {
        "SSH host key verification failed. Verify the host fingerprint in Terminal and repair known_hosts only after confirming it with the administrator."
    } else if s.contains("permission denied (") || s.contains("no such identity") || s.contains("sign_and_send_pubkey") {
        "SSH key authentication failed. Check the username, identity file and GUI SSH agent; establish key authentication in Terminal first."
    } else if s.contains("not found") || s.contains("no such file") || s.contains("permission denied") {
        "Remote server could not start. Check the server executable path and its permissions."
    } else { "SSH connection or remote server ended. Check host reachability, SSH configuration, key authentication and the server executable." }.into()
}

pub(crate) async fn run(
    target: ConnectionTarget,
    config: core::SessionConfig,
    driver: Driver,
    tx: mpsc::Sender<Item>,
    control: Arc<Control>,
) -> SessionEnd {
    let policy = match policy_config("~/.ssh/config", "/etc/ssh/ssh_config") {
        Ok(file) => file,
        Err(_) => {
            control.finish();
            return SessionEnd::Failed { error: GliffError::Transport {
                message: "Cannot create the private SSH policy file. Check temporary-directory access.".into(),
            }};
        }
    };
    // Keep the policy file alive until SSH and all its jump helpers stop.
    run_command(command(&target, policy.path()), config, driver, tx, control).await
}

async fn run_command(
    mut command: Command,
    config: core::SessionConfig,
    driver: Driver,
    tx: mpsc::Sender<Item>,
    control: Arc<Control>,
) -> SessionEnd {
    if control.is_cancelled() {
        control.finish();
        return SessionEnd::Cancelled;
    }
    command.as_std_mut().process_group(0);
    let mut child = match command.spawn() {
        Ok(child) => child,
        Err(_) => {
            control.finish();
            return SessionEnd::Failed {
                error: GliffError::Transport {
                    message: "Cannot launch /usr/bin/ssh. Check the system OpenSSH installation."
                        .into(),
                },
            };
        }
    };
    let mut group = ProcessGroup {
        pid: Pid::from_raw(child.id().expect("spawned child") as i32).expect("positive pid"),
        armed: true,
    };
    let mut stderr = child.stderr.take().expect("piped stderr");
    let drain = tokio::spawn(async move {
        let mut retained = Vec::new();
        let mut chunk = [0; 4096];
        loop {
            match stderr.read(&mut chunk).await {
                Ok(0) | Err(_) => break,
                Ok(n) => {
                    let count = n.min(16384 - retained.len());
                    retained.extend_from_slice(&chunk[..count]);
                }
            }
        }
        retained
    });
    let result = core::run(
        child.stdout.take().expect("piped stdout"),
        child.stdin.take().expect("piped stdin"),
        config,
        driver,
        tx,
    )
    .await;
    // EOF can precede the child's normal exit by a scheduler turn. Preserve
    // its exit status instead of killing a successful server immediately.
    let status = if matches!(result, Ok(core::SessionEnd::Closed)) {
        match tokio::time::timeout(std::time::Duration::from_millis(200), child.wait()).await {
            Ok(status) => status,
            Err(_) => {
                group.terminate().await;
                child.wait().await
            }
        }
    } else {
        group.terminate().await;
        child.wait().await
    };
    // A proxy can outlive even a normally exited SSH parent.
    group.terminate().await;
    group.armed = false;
    // A remote descendant can inherit stderr. Abort and join rather than wait forever.
    let diagnostics = finish_diagnostics(drain).await;
    classify_end(
        result,
        control.connected(),
        status.is_ok_and(|status| status.success()),
        &diagnostics,
    )
}

fn classify_end(
    result: Result<core::SessionEnd, SessionError>,
    connected: bool,
    successful_exit: bool,
    diagnostics: &[u8],
) -> SessionEnd {
    match result {
        Ok(core::SessionEnd::Cancelled) => SessionEnd::Cancelled,
        Ok(core::SessionEnd::Closed) if !connected => SessionEnd::Failed {
            error: GliffError::Transport {
                message: diagnostic(diagnostics),
            },
        },
        Ok(core::SessionEnd::Closed) if !successful_exit => SessionEnd::Failed {
            error: GliffError::Transport {
                message:
                    "SSH session ended unexpectedly. Check the network and server diagnostics."
                        .into(),
            },
        },
        Ok(core::SessionEnd::Closed) => SessionEnd::Closed,
        Err(error @ SessionError::Transport(_)) if is_timeout(&error) => SessionEnd::Failed {
            error: error.into(),
        },
        // SSH stderr adds context to transport failures only. A server can
        // log before rejecting our protocol; retain its typed fatal error.
        Err(SessionError::Transport(_)) if !connected && !diagnostics.is_empty() => {
            SessionEnd::Failed {
                error: GliffError::Transport {
                    message: diagnostic(diagnostics),
                },
            }
        }
        Err(error) => SessionEnd::Failed {
            error: error.into(),
        },
    }
}

fn is_timeout(error: &SessionError) -> bool {
    let mut source: &dyn Error = error;
    loop {
        if let Some(io) = source.downcast_ref::<std::io::Error>() {
            return io.kind() == std::io::ErrorKind::TimedOut;
        }
        let Some(next) = source.source() else {
            return false;
        };
        source = next;
    }
}

async fn finish_diagnostics(mut drain: tokio::task::JoinHandle<Vec<u8>>) -> Vec<u8> {
    match tokio::time::timeout(std::time::Duration::from_secs(1), &mut drain).await {
        Ok(Ok(bytes)) => bytes,
        _ => {
            drain.abort();
            let _ = drain.await;
            Vec::new()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn warnings_preserve_startup_timeout_and_live_exit_does_not_claim_startup_failed() {
        let error = SessionError::Transport(
            std::io::Error::new(std::io::ErrorKind::TimedOut, "startup exceeded 20 seconds").into(),
        );
        let end = classify_end(Err(error), false, false, b"Warning: key exchange warning");
        assert!(
            matches!(end, SessionEnd::Failed { error: GliffError::Transport { ref message } } if message.contains("startup exceeded 20 seconds")),
            "{end:?}"
        );
        let end = classify_end(
            Ok(core::SessionEnd::Closed),
            true,
            false,
            b"server resource not found: permission denied",
        );
        assert!(
            matches!(end, SessionEnd::Failed { error: GliffError::Transport { ref message } } if message.contains("session ended unexpectedly") && !message.contains("could not start")),
            "{end:?}"
        );
    }
    #[test]
    fn quotes_remote_shell_metacharacters() {
        assert_eq!(
            quote("/tmp/a'$(touch nope);b"),
            "'/tmp/a'\\''$(touch nope);b'"
        );
    }
    #[test]
    fn argv_is_absolute_noninteractive_and_structured() {
        let target = ConnectionTarget::Ssh {
            host: "alias".into(),
            user: Some("remi".into()),
            port: Some(2222),
            server_path: Some("/tmp/a'b".into()),
            identity_file: Some("/tmp/key file".into()),
            headless: true,
        };
        target.validate().unwrap();
        let cmd = command(&target, Path::new("/tmp/policy"));
        assert_eq!(cmd.as_std().get_program(), "/usr/bin/ssh");
        let args: Vec<_> = cmd
            .as_std()
            .get_args()
            .map(|s| s.to_str().unwrap())
            .collect();
        assert!(args.contains(&"-oStrictHostKeyChecking=yes"));
        assert!(args.contains(&"-oForwardAgent=no"));
        assert!(args.contains(&"-oForwardX11=no"));
        assert_eq!(args.last(), Some(&"exec '/tmp/a'\\''b' --stdio --headless"));
    }
    #[test]
    fn diagnostics_are_actionable_and_redacted() {
        for (raw, expected) in [
            ("secret host key verification failed", "fingerprint"),
            ("secret Permission denied (publickey)", "agent"),
            ("secret command not found", "executable"),
            ("secret Permission denied: gliff-server", "executable"),
            ("secret Operation timed out", "ProxyJump"),
            ("secret Could not resolve hostname", "hostname"),
        ] {
            let message = diagnostic(raw.as_bytes());
            assert!(message.contains(expected));
            assert!(!message.contains("secret"));
        }
    }

    #[tokio::test]
    async fn jump_hops_share_the_policy_and_keep_host_specific_config() {
        let mut user = tempfile::NamedTempFile::new().unwrap();
        writeln!(user, "Host destination\n HostName 127.0.0.1\n User endpoint\n Port 2222\n IdentityFile /tmp/endpoint-key\n ProxyJump jump\nHost jump\n HostName 127.0.0.1\n User jumper\n Port 2200\n IdentityFile /tmp/jump-key\nHost *\n BatchMode no\n StrictHostKeyChecking no\n ForwardAgent yes\n ForwardX11 yes\n ForwardX11Trusted yes\n RemoteCommand tmux attach\n Tunnel yes\nHost unmatched").unwrap();
        let mut system = tempfile::NamedTempFile::new().unwrap();
        writeln!(system, "Host *\n ServerAliveInterval 7").unwrap();
        let policy = policy_config(
            &format!("\"{}\"", user.path().display()),
            &format!("\"{}\"", system.path().display()),
        )
        .unwrap();
        for (host, user, port, identity) in [
            ("destination", "endpoint", 2222, "/tmp/endpoint-key"),
            ("jump", "jumper", 2200, "/tmp/jump-key"),
        ] {
            let output = Command::new("/usr/bin/ssh")
                .args(["-vvG", "-F"])
                .arg(policy.path())
                .arg(host)
                .output()
                .await
                .unwrap();
            assert!(
                output.status.success(),
                "{}",
                String::from_utf8_lossy(&output.stderr)
            );
            let config = String::from_utf8_lossy(&output.stdout);
            for expected in [
                "batchmode yes".to_owned(),
                "stricthostkeychecking true".into(),
                "forwardagent no".into(),
                "forwardx11 no".into(),
                "forwardx11trusted no".into(),
                "tunnel false".into(),
                "serveraliveinterval 7".into(),
                format!("user {user}"),
                format!("port {port}"),
                format!("identityfile {identity}"),
            ] {
                assert!(
                    config.lines().any(|line| line == expected),
                    "missing {expected}: {config}"
                );
            }
            assert!(!config.contains("tmux attach"), "{config}");
            if host == "destination" {
                let debug = String::from_utf8_lossy(&output.stderr);
                let proxy = debug
                    .lines()
                    .find(|line| line.contains("implicit ProxyCommand"))
                    .unwrap();
                assert!(
                    proxy.contains(&format!("-F {}", policy.path().display())),
                    "{proxy}"
                );
                assert!(proxy.ends_with(" jump"), "{proxy}");
            }
        }
    }
}

#[cfg(test)]
mod process_tests {
    use super::*;

    #[tokio::test]
    async fn inherited_stderr_deadline_aborts_and_joins_the_reader() {
        struct Witness(Arc<std::sync::atomic::AtomicBool>);
        impl Drop for Witness {
            fn drop(&mut self) {
                self.0.store(true, std::sync::atomic::Ordering::Release);
            }
        }
        let joined = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let witness = Witness(joined.clone());
        let drain = tokio::spawn(async move {
            let _witness = witness;
            std::future::pending::<Vec<u8>>().await
        });
        assert!(finish_diagnostics(drain).await.is_empty());
        assert!(joined.load(std::sync::atomic::Ordering::Acquire));
    }

    #[tokio::test]
    async fn cancellation_removes_observed_child_and_proxy_pids() {
        use rustix::process::test_kill_process;
        for descendant in [false, true] {
            let directory = tempfile::tempdir().unwrap();
            let marker = directory.path().join("pids");
            let script = if descendant {
                "import os,signal,subprocess,sys,time\np=subprocess.Popen(['/bin/sleep','60'],stdout=subprocess.DEVNULL)\ndef stop(*args):\n p.kill();p.wait();sys.exit(0)\nsignal.signal(signal.SIGTERM,stop)\nopen(sys.argv[1],'w').write(str(os.getpid())+' '+str(p.pid))\ntime.sleep(60)"
            } else {
                "import os,signal,sys,time\nsignal.signal(signal.SIGTERM,signal.SIG_IGN)\nopen(sys.argv[1],'w').write(str(os.getpid()))\ntime.sleep(60)"
            };
            let mut command = Command::new("/usr/bin/python3");
            command
                .args(["-c", script])
                .arg(&marker)
                .stdin(Stdio::piped())
                .stdout(Stdio::piped())
                .stderr(Stdio::piped())
                .kill_on_drop(true);
            let (control, driver) = Control::new(core::FrameBudget::default());
            let (tx, _rx) = mpsc::channel(32);
            let config = core::SessionConfig {
                support: gliff_client_core::video::DecoderSupport::h264(&[
                    gliff_proto::ChromaMode::Single420,
                ]),
                keymap: String::new(),
                budget: core::FrameBudget::default(),
                drain_on_close: false,
            };
            let run = tokio::spawn(run_command(command, config, driver, tx, control.clone()));
            let pids = tokio::time::timeout(std::time::Duration::from_secs(5), async {
                loop {
                    if let Ok(text) = std::fs::read_to_string(&marker) {
                        if !text.is_empty() {
                            break text
                                .split_whitespace()
                                .map(|pid| Pid::from_raw(pid.parse().unwrap()).unwrap())
                                .collect::<Vec<_>>();
                        }
                    }
                    tokio::time::sleep(std::time::Duration::from_millis(5)).await;
                }
            })
            .await
            .unwrap();
            assert_eq!(pids.len(), if descendant { 2 } else { 1 });
            for pid in &pids {
                assert!(test_kill_process(*pid).is_ok());
            }
            control.cancel();
            assert_eq!(
                tokio::time::timeout(std::time::Duration::from_secs(3), run)
                    .await
                    .unwrap()
                    .unwrap(),
                SessionEnd::Cancelled
            );
            for pid in pids {
                assert_eq!(
                    test_kill_process(pid),
                    Err(rustix::io::Errno::SRCH),
                    "PID {pid} survived completion"
                );
            }
        }
    }

    #[tokio::test]
    async fn logged_protocol_rejection_stays_fatal_and_normal_logged_eof_is_closed() {
        let fixture = std::fs::read(
            std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("../../tests/fixtures/streams/synthetic-single420.gliffstream"),
        )
        .unwrap();
        let header_len = u32::from_le_bytes(fixture[..4].try_into().unwrap()) as usize;
        let hello = &fixture[..8 + header_len];
        // The fixture's HelloAck starts [tag 0, [version 1, ...]]. Only
        // change that version, retaining the real upstream message encoding.
        assert_eq!(&hello[8..12], &[0x82, 0, 0x84, 1]);
        for mismatch in [false, true] {
            let path = std::env::temp_dir()
                .join(format!("gliff-ssh-hello-{}-{mismatch}", std::process::id()));
            let mut bytes = hello.to_vec();
            if mismatch {
                bytes[11] = 2;
            }
            std::fs::write(&path, bytes).unwrap();
            let mut cmd = Command::new("/bin/sh");
            cmd.args([
                "-c",
                "echo 'server startup diagnostic' >&2; cat \"$1\"",
                "probe",
            ])
            .arg(&path)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true);
            let (control, driver) = Control::new(core::FrameBudget::default());
            let (tx, _rx) = mpsc::channel(32);
            let config = core::SessionConfig {
                support: gliff_client_core::video::DecoderSupport::h264(&[
                    gliff_proto::ChromaMode::Single420,
                ]),
                keymap: String::new(),
                budget: core::FrameBudget::default(),
                drain_on_close: false,
            };
            let end = run_command(cmd, config, driver, tx, control).await;
            std::fs::remove_file(path).unwrap();
            if mismatch {
                assert!(
                    matches!(
                        end,
                        SessionEnd::Failed {
                            error: GliffError::VersionMismatch { server: 2, .. }
                        }
                    ),
                    "{end:?}"
                );
            } else {
                assert_eq!(end, SessionEnd::Closed);
            }
        }
    }

    #[tokio::test]
    async fn stderr_flood_eof_and_repeated_cleanup() {
        for _ in 0..8 {
            let mut cmd = Command::new("/bin/sh");
            cmd.args(["-c", "i=0; while [ $i -lt 2000 ]; do echo 'Permission denied secret-secret-secret' >&2; i=$((i+1)); done"])
                .stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped()).kill_on_drop(true);
            let (control, driver) = Control::new(core::FrameBudget::default());
            let (tx, _rx) = mpsc::channel(32);
            let config = core::SessionConfig {
                support: gliff_client_core::video::DecoderSupport::h264(&[
                    gliff_proto::ChromaMode::Single420,
                ]),
                keymap: String::new(),
                budget: core::FrameBudget::default(),
                drain_on_close: false,
            };
            let end = tokio::time::timeout(
                std::time::Duration::from_secs(5),
                run_command(cmd, config, driver, tx, control.clone()),
            )
            .await
            .unwrap();
            assert!(matches!(end, SessionEnd::Failed { .. }));
            assert!(!control.is_running());
        }
    }
    #[tokio::test]
    async fn cancellation_reaps_blocked_startup() {
        let mut cmd = Command::new("/bin/sleep");
        cmd.arg("60")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true);
        let (control, driver) = Control::new(core::FrameBudget::default());
        let (tx, _rx) = mpsc::channel(32);
        let config = core::SessionConfig {
            support: gliff_client_core::video::DecoderSupport::h264(&[
                gliff_proto::ChromaMode::Single420,
            ]),
            keymap: String::new(),
            budget: core::FrameBudget::default(),
            drain_on_close: false,
        };
        let cancel = control.clone();
        tokio::spawn(async move {
            tokio::time::sleep(std::time::Duration::from_millis(30)).await;
            cancel.cancel();
        });
        assert_eq!(
            tokio::time::timeout(
                std::time::Duration::from_secs(3),
                run_command(cmd, config, driver, tx, control.clone())
            )
            .await
            .unwrap(),
            SessionEnd::Cancelled
        );
        assert!(!control.is_running());
    }
}
