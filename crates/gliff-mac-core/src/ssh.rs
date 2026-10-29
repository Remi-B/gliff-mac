//! System OpenSSH adapter. No local shell, raw flags, or raw remote commands.
use crate::{session::Item, types::*};
use gliff_client_core::session::{self as core, Control, Driver};
use std::{process::Stdio, sync::Arc};
use tokio::{io::AsyncReadExt, process::Command, sync::mpsc};

fn quote(word: &str) -> String {
    format!("'{}'", word.replace('\'', "'\\''"))
}

fn command(target: &ConnectionTarget) -> Command {
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
    run_command(command(&target), config, driver, tx, control).await
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
                let _ = child.start_kill();
                child.wait().await
            }
        }
    } else {
        let _ = child.start_kill();
        child.wait().await
    };
    // A remote descendant can inherit stderr. Abort and join rather than wait forever.
    let mut drain = drain;
    let diagnostics =
        match tokio::time::timeout(std::time::Duration::from_secs(1), &mut drain).await {
            Ok(Ok(bytes)) => bytes,
            _ => {
                drain.abort();
                let _ = drain.await;
                Vec::new()
            }
        };
    match result {
        Ok(core::SessionEnd::Cancelled) => SessionEnd::Cancelled,
        Ok(core::SessionEnd::Closed)
            if !control.connected() || !status.is_ok_and(|status| status.success()) =>
        {
            SessionEnd::Failed {
                error: GliffError::Transport {
                    message: diagnostic(&diagnostics),
                },
            }
        }
        Ok(core::SessionEnd::Closed) => SessionEnd::Closed,
        // SSH stderr adds context to transport failures only. A server can
        // log before rejecting our protocol; retain its typed fatal error.
        Err(gliff_client_core::events::SessionError::Transport(_))
            if !control.connected() && !diagnostics.is_empty() =>
        {
            SessionEnd::Failed {
                error: GliffError::Transport {
                    message: diagnostic(&diagnostics),
                },
            }
        }
        Err(error) => SessionEnd::Failed {
            error: error.into(),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;
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
        let cmd = command(&target);
        assert_eq!(cmd.as_std().get_program(), "/usr/bin/ssh");
        let args: Vec<_> = cmd
            .as_std()
            .get_args()
            .map(|s| s.to_str().unwrap())
            .collect();
        assert!(args.contains(&"-oStrictHostKeyChecking=yes"));
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
}

#[cfg(test)]
mod process_tests {
    use super::*;

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
