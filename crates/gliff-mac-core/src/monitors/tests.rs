use super::*;
use std::{path::Path, process::Stdio};

fn report(lines: &[&str]) -> String {
    lines
        .iter()
        .map(|line| format!("{PREFIX}{line}\n"))
        .collect()
}

fn orphan(name: &str, width: u32, height: u32, enabled: bool) -> OrphanedOutput {
    OrphanedOutput {
        name: name.into(),
        width,
        height,
        enabled,
    }
}

// MARK: Parsing

#[test]
fn check_reports_parse_and_ignore_login_noise() {
    let text = format!(
        "Welcome to the host\n{}",
        report(&[
            "begin",
            "orphan gliff-4242 1920 1080 enabled",
            "orphan gliff-7 0 0 disabled",
            "end 2",
        ])
    ) + "trailing noise\n";
    assert_eq!(
        parse_check(&text).unwrap(),
        OrphanCheck::Found {
            outputs: vec![
                orphan("gliff-4242", 1920, 1080, true),
                orphan("gliff-7", 0, 0, false)
            ]
        }
    );
    assert_eq!(
        parse_check(&report(&["begin", "end 0"])).unwrap(),
        OrphanCheck::Found { outputs: vec![] }
    );
    for (token, reason) in [
        ("no-hyprctl", CheckUnavailable::NoHyprctl),
        ("no-hyprland", CheckUnavailable::NoHyprland),
        ("hyprctl-failed", CheckUnavailable::HyprctlFailed),
    ] {
        assert_eq!(
            parse_check(&report(&[&format!("unavailable {token}")])).unwrap(),
            OrphanCheck::Unavailable { reason }
        );
    }
}

#[test]
fn malformed_or_hostile_check_reports_are_rejected_whole() {
    let line = |entry: &str| report(&["begin", entry, "end 1"]);
    for bad in [
        // Names that are not gliff-<pid>, or could be read as more.
        line("orphan eDP-1 2880 1800 enabled"),
        line("orphan gliff-1;reboot 1 1 enabled"),
        line("orphan gliff-0012 1 1 enabled"),
        line("orphan gliff-12345678 1 1 enabled"),
        line("orphan gliff- 1 1 enabled"),
        line("orphan gliff-12\u{202e} 1 1 enabled"),
        line("orphan ../gliff-1 1 1 enabled"),
        // Sizes and states.
        line("orphan gliff-1 -1 1 enabled"),
        line("orphan gliff-1 +1 1 enabled"),
        line("orphan gliff-1 0100 1 enabled"),
        line("orphan gliff-1 999999 1 enabled"),
        line("orphan gliff-1 1 1 on"),
        // Shape: extra or missing words, double spaces, other verbs.
        line("orphan gliff-1 1 1 enabled extra"),
        line("orphan gliff-1 1 1"),
        line("orphan  gliff-1 1 1 enabled"),
        line("removed gliff-1"),
        // Framing: count, truncation, foreign lines inside, repeats.
        report(&["begin", "orphan gliff-1 1 1 enabled", "end 2"]),
        report(&["begin", "orphan gliff-1 1 1 enabled", "end +1"]),
        report(&["begin", "orphan gliff-1 1 1 enabled"]),
        report(&[
            "begin",
            "orphan gliff-1 1 1 enabled",
            "orphan gliff-1 1 1 enabled",
            "end 2",
        ]),
        format!("{PREFIX}begin\nnoise\n{PREFIX}end 0\n"),
        report(&["unavailable maybe"]),
        report(&["orphan gliff-1 1 1 enabled", "begin", "end 0"]),
        String::new(),
        "no report at all\n".into(),
    ] {
        assert!(
            matches!(parse_check(&bad), Err(GliffError::Protocol { .. })),
            "{bad:?}"
        );
    }
    let mut many = vec!["begin".to_owned()];
    many.extend((1..=MAX_OUTPUTS + 1).map(|i| format!("orphan gliff-{i} 1 1 enabled")));
    many.push(format!("end {}", MAX_OUTPUTS + 1));
    let many: Vec<&str> = many.iter().map(String::as_str).collect();
    assert!(parse_check(&report(&many)).is_err());
}

#[test]
fn removal_reports_give_one_result_per_requested_output() {
    let names = vec!["gliff-1".to_owned(), "gliff-2".into(), "gliff-3".into()];
    let text = report(&[
        "begin",
        "in-use gliff-2",
        "removed gliff-1",
        "failed gliff-3",
        "end 3",
    ]);
    let OrphanRemoval::Finished { results } = parse_removal(&text, &names).unwrap() else {
        panic!()
    };
    assert_eq!(
        results
            .iter()
            .map(|r| (r.name.as_str(), r.outcome))
            .collect::<Vec<_>>(),
        [
            ("gliff-1", RemovalOutcome::Removed),
            ("gliff-2", RemovalOutcome::InUse),
            ("gliff-3", RemovalOutcome::Failed)
        ]
    );
    for bad in [
        report(&["begin", "removed gliff-9", "end 1"]),
        report(&["begin", "removed gliff-1", "removed gliff-1", "end 2"]),
        report(&["begin", "deleted gliff-1", "end 1"]),
        report(&["begin", "removed gliff-1 now", "end 1"]),
        report(&["begin", "removed gliff-1"]),
    ] {
        assert!(parse_removal(&bad, &names).is_err(), "{bad:?}");
    }
}

#[test]
fn only_gliff_pid_names_can_be_requested() {
    assert_eq!(
        validate_names(vec!["gliff-5".into(), "gliff-5".into(), "gliff-6".into()]).unwrap(),
        ["gliff-5", "gliff-6"]
    );
    for bad in [
        vec![],
        vec!["eDP-1".to_owned()],
        vec!["gliff-1 gliff-2".into()],
        vec!["gliff-1;id".into()],
        vec!["gliff-01".into()],
        vec!["-gliff-1".into()],
        (1..=MAX_OUTPUTS + 1)
            .map(|i| format!("gliff-{i}"))
            .collect(),
    ] {
        assert!(validate_names(bad.clone()).is_err(), "{bad:?}");
    }
}

#[test]
fn only_ssh_targets_are_accepted() {
    assert!(HostMonitors::new(ConnectionTarget::Replay { stream: vec![1] }).is_err());
    let target = ConnectionTarget::Ssh {
        host: "-oProxyCommand=x".into(),
        user: None,
        port: None,
        server_path: None,
        identity_file: None,
        headless: true,
        output: None,
        video_mode: crate::VideoMode::Auto,
    };
    assert!(HostMonitors::new(target).is_err());
}

#[test]
fn the_ssh_command_runs_the_fixed_script_from_stdin() {
    let target = ConnectionTarget::Ssh {
        host: "host".into(),
        user: Some("remi".into()),
        port: Some(2222),
        server_path: Some("/opt/gliff-server".into()),
        identity_file: Some("/tmp/key".into()),
        headless: true,
        output: None,
        video_mode: crate::VideoMode::Gpu,
    };
    let cmd = ssh::ssh(&target, Path::new("/tmp/policy"), &[], "sh -s -- check");
    let args: Vec<_> = cmd
        .as_std()
        .get_args()
        .map(|s| s.to_str().unwrap())
        .collect();
    assert_eq!(cmd.as_std().get_program(), "/usr/bin/ssh");
    assert!(args.contains(&"-oBatchMode=yes"));
    assert!(args.contains(&"-oStrictHostKeyChecking=yes"));
    assert_eq!(&args[args.len() - 3..], ["--", "host", "sh -s -- check"]);
    // Session settings that do not apply to a maintenance command.
    assert!(!args
        .iter()
        .any(|a| a.contains("gliff-server") || a.contains("gpu")));
}

// MARK: The script, with a fake hyprctl and process table

/// A host: `hyprctl` backed by a state file (`name width height disabled`
/// per line) and a fake `/proc`.
struct FakeHost {
    dir: tempfile::TempDir,
}

const FAKE_HYPRCTL: &str = r#"#!/bin/sh
state="$FAKE_ROOT/monitors"
[ -e "$FAKE_ROOT/dead" ] && { echo 'HYPRLAND_INSTANCE_SIGNATURE not set! (is hyprland running?)'; exit 1; }
case $HYPRLAND_INSTANCE_SIGNATURE in live*) ;; *) echo "Couldn't connect"; exit 1 ;; esac
set_disabled() {
  awk -v n="$1" -v d="$2" '$1 == n { $4 = d } { print }' "$state" >"$state.new" && mv "$state.new" "$state"
}
case "$1 $2" in
"monitors all")
  [ -e "$FAKE_ROOT/empty" ] && exit 0
  id=0
  while read -r n w h d; do
    printf 'Monitor %s (ID %s):\n\t%sx%s@60.00000 at 0x0\n\tdescription: \n\tdisabled: %s\n\n' "$n" $id "$w" "$h" "$d"
    id=$((id + 1))
  done <"$state"
  ;;
"output remove")
  # Hyprland stops answering right after this request.
  [ -e "$FAKE_ROOT/dies-on-remove" ] && { touch "$FAKE_ROOT/dead"; echo "output not found"; exit 0; }
  if [ -e "$FAKE_ROOT/stuck" ] || ! awk -v n="$3" '$1 == n && $4 == "false" { found = 1 } END { exit !found }' "$state"; then
    echo "output not found"
  else
    awk -v n="$3" '$1 != n' "$state" >"$state.new" && mv "$state.new" "$state"
    echo ok
  fi
  ;;
"eval "*)
  [ -e "$FAKE_ROOT/no-eval" ] && { echo "unknown request"; exit 0; }
  # A server starts with that pid while the output is being enabled.
  if [ -e "$FAKE_ROOT/starts-on-enable" ]; then
    pid=$(cat "$FAKE_ROOT/starts-on-enable")
    mkdir -p "$GLIFF_ORPHANS_PROC/$pid" && printf 'gliff-server\0' >"$GLIFF_ORPHANS_PROC/$pid/cmdline"
  fi
  name=$(printf '%s' "$2" | sed -n 's/^hl.monitor({ output = "\(gliff-[0-9]*\)", disabled = false })$/\1/p')
  [ -n "$name" ] && set_disabled "$name" false
  echo ok
  ;;
"keyword monitor")
  set_disabled "${3%%,*}" false
  echo ok
  ;;
*) echo "unexpected: $*" >&2; exit 1 ;;
esac
"#;

impl FakeHost {
    fn new(monitors: &[&str]) -> Self {
        let dir = tempfile::tempdir().unwrap();
        let bin = dir.path().join("bin");
        std::fs::create_dir_all(&bin).unwrap();
        std::fs::create_dir_all(dir.path().join("proc")).unwrap();
        std::fs::create_dir_all(dir.path().join("run/hypr")).unwrap();
        let hyprctl = bin.join("hyprctl");
        std::fs::write(&hyprctl, FAKE_HYPRCTL).unwrap();
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&hyprctl, std::fs::Permissions::from_mode(0o755)).unwrap();
        let host = Self { dir };
        host.set_monitors(monitors);
        host
    }

    fn set_monitors(&self, monitors: &[&str]) {
        let mut text = monitors.join("\n");
        text.push('\n');
        std::fs::write(self.dir.path().join("monitors"), text).unwrap();
    }

    fn monitors(&self) -> String {
        std::fs::read_to_string(self.dir.path().join("monitors")).unwrap()
    }

    fn process(&self, pid: u32, argv: &[&str]) {
        let dir = self.dir.path().join("proc").join(pid.to_string());
        std::fs::create_dir_all(&dir).unwrap();
        let mut cmdline = Vec::new();
        for arg in argv {
            cmdline.extend_from_slice(arg.as_bytes());
            cmdline.push(0);
        }
        std::fs::write(dir.join("cmdline"), cmdline).unwrap();
    }

    fn flag(&self, name: &str) {
        std::fs::write(self.dir.path().join(name), "").unwrap();
    }

    /// Runs the script as `sh -s -- ARGS` would on the host.
    /// `GLIFF_TEST_SHELL=/bin/dash` checks it with a stricter shell.
    async fn run(&self, args: &[&str], instance: Option<&str>) -> String {
        let shell = std::env::var("GLIFF_TEST_SHELL").unwrap_or_else(|_| "/bin/sh".into());
        let mut cmd = Command::new(shell);
        cmd.arg("-s")
            .arg("--")
            .args(args)
            .env_clear()
            .env(
                "PATH",
                format!("{}:/usr/bin:/bin", self.dir.path().join("bin").display()),
            )
            .env("FAKE_ROOT", self.dir.path())
            .env("GLIFF_ORPHANS_PROC", self.dir.path().join("proc"))
            .env("XDG_RUNTIME_DIR", self.dir.path().join("run"))
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true);
        if let Some(instance) = instance {
            cmd.env("HYPRLAND_INSTANCE_SIGNATURE", instance);
        }
        let Run::Output(out) = run_bounded(
            cmd,
            SCRIPT.as_bytes(),
            Duration::from_secs(20),
            watch::channel(false).1,
        )
        .await
        .unwrap() else {
            panic!("cancelled")
        };
        out
    }
}

#[tokio::test]
async fn the_check_classifies_outputs_by_their_server() {
    let host = FakeHost::new(&[
        "eDP-1 2880 1800 false",
        // A running server, by name or development build path.
        "gliff-100 1920 1080 false",
        "gliff-101 2560 1600 false",
        // A pid reused by another program, a dead one, a disabled one.
        "gliff-102 1920 1080 false",
        "gliff-103 1280 800 false",
        "gliff-104 1920 1080 true",
        // Other names and hostile ones are never Gliff's.
        "GLIFFMIRROR-1 1920 1080 false",
        "gliff-0105 1920 1080 false",
        "gliff-106;reboot 1920 1080 false",
        "HEADLESS-2 1920 1080 true",
    ]);
    host.process(100, &["gliff-server", "--stdio", "--headless"]);
    host.process(101, &["/home/u/.cache/gliff-server-abc.bin", "--stdio"]);
    host.process(102, &["vim", "gliff-server.rs"]);
    let out = host.run(&["check"], Some("live-1")).await;
    assert_eq!(
        parse_check(&out).unwrap(),
        OrphanCheck::Found {
            outputs: vec![
                orphan("gliff-102", 1920, 1080, true),
                orphan("gliff-103", 1280, 800, true),
                orphan("gliff-104", 1920, 1080, false),
            ]
        },
        "{out}"
    );
    // Read-only.
    assert!(host.monitors().contains("gliff-103"));
}

#[tokio::test]
async fn the_check_finds_the_hyprland_instance_or_reports_why_not() {
    let host = FakeHost::new(&["gliff-7 1920 1080 false"]);
    // No instance named and none in the runtime directory.
    assert_eq!(
        parse_check(&host.run(&["check"], None).await).unwrap(),
        OrphanCheck::Unavailable {
            reason: CheckUnavailable::NoHyprland
        }
    );
    // The newest answering instance with a socket; a stale name is ignored.
    let run = host.dir.path().join("run/hypr");
    for name in ["dead_1", "live_2"] {
        std::fs::create_dir_all(run.join(name)).unwrap();
        let listener =
            std::os::unix::net::UnixListener::bind(run.join(name).join(".socket.sock")).unwrap();
        std::mem::forget(listener);
    }
    let found = OrphanCheck::Found {
        outputs: vec![orphan("gliff-7", 1920, 1080, true)],
    };
    assert_eq!(
        parse_check(&host.run(&["check"], Some("stale")).await).unwrap(),
        found
    );
    assert_eq!(
        parse_check(&host.run(&["check"], None).await).unwrap(),
        found
    );
    host.flag("empty");
    assert_eq!(
        parse_check(&host.run(&["check"], Some("live-1")).await).unwrap(),
        OrphanCheck::Unavailable {
            reason: CheckUnavailable::NoHyprland
        }
    );
    host.flag("dead");
    assert_eq!(
        parse_check(&host.run(&["check"], Some("live-1")).await).unwrap(),
        OrphanCheck::Unavailable {
            reason: CheckUnavailable::NoHyprland
        }
    );
    std::fs::remove_file(host.dir.path().join("bin/hyprctl")).unwrap();
    assert_eq!(
        parse_check(&host.run(&["check"], Some("live-1")).await).unwrap(),
        OrphanCheck::Unavailable {
            reason: CheckUnavailable::NoHyprctl
        }
    );
}

#[tokio::test]
async fn removal_rechecks_enables_disabled_outputs_and_verifies() {
    let host = FakeHost::new(&[
        "eDP-1 2880 1800 false",
        "gliff-200 1920 1080 false",
        "gliff-201 1920 1080 true",
        "gliff-202 1920 1080 false",
    ]);
    // gliff-202's server started again since the check.
    host.process(202, &["gliff-server", "--stdio"]);
    let names: Vec<String> = ["gliff-200", "gliff-201", "gliff-202", "gliff-203"]
        .map(Into::into)
        .to_vec();
    let mut args = vec!["remove"];
    args.extend(names.iter().map(String::as_str));
    let out = host.run(&args, Some("live-1")).await;
    let OrphanRemoval::Finished { results } = parse_removal(&out, &names).unwrap() else {
        panic!("{out}")
    };
    assert_eq!(
        results.iter().map(|r| r.outcome).collect::<Vec<_>>(),
        [
            RemovalOutcome::Removed,
            // Disabled: enabled first, then removed.
            RemovalOutcome::Removed,
            RemovalOutcome::InUse,
            // Already gone.
            RemovalOutcome::Removed,
        ],
        "{out}"
    );
    assert_eq!(
        host.monitors(),
        "eDP-1 2880 1800 false\ngliff-202 1920 1080 false\n"
    );
}

#[tokio::test]
async fn removal_falls_back_to_a_monitor_keyword_and_reports_failures() {
    let host = FakeHost::new(&["gliff-300 1920 1080 true", "gliff-301 1920 1080 false"]);
    // No Lua `eval`: the keyword re-enables the output.
    host.flag("no-eval");
    let names = vec!["gliff-300".to_owned()];
    let out = host.run(&["remove", "gliff-300"], Some("live-1")).await;
    assert_eq!(
        parse_removal(&out, &names).unwrap(),
        OrphanRemoval::Finished {
            results: vec![OutputRemoval {
                name: "gliff-300".into(),
                outcome: RemovalOutcome::Removed
            }]
        }
    );
    // hyprctl answers but the output stays: a failure, not a removal.
    host.flag("stuck");
    let names = vec!["gliff-301".to_owned()];
    let out = host.run(&["remove", "gliff-301"], Some("live-1")).await;
    assert_eq!(
        parse_removal(&out, &names).unwrap(),
        OrphanRemoval::Finished {
            results: vec![OutputRemoval {
                name: "gliff-301".into(),
                outcome: RemovalOutcome::Failed
            }]
        }
    );
    // An invalid name reaching the script is refused there too.
    let out = host
        .run(&["remove", "eDP-1", "gliff-1;id"], Some("live-1"))
        .await;
    assert_eq!(
        out,
        report(&["begin", "failed eDP-1", "failed gliff-1;id", "end 2"])
    );
    assert!(host.monitors().contains("gliff-301"));
}

#[tokio::test]
async fn uncertain_ownership_and_unanswered_queries_never_count_as_removed() {
    use std::os::unix::fs::PermissionsExt;
    let host = FakeHost::new(&[
        "gliff-400 1920 1080 false",
        "gliff-401 1920 1080 true",
        "gliff-402 1920 1080 false",
    ]);
    // A process whose command line cannot be read (hidepid, a race) may be
    // a running server: neither offered nor removed.
    host.process(400, &["gliff-server"]);
    let cmdline = host.dir.path().join("proc/400/cmdline");
    std::fs::set_permissions(&cmdline, std::fs::Permissions::from_mode(0o000)).unwrap();
    let readable = std::fs::read(&cmdline).is_ok(); // root reads it anyway
    if !readable {
        assert_eq!(
            parse_check(&host.run(&["check"], Some("live-1")).await).unwrap(),
            OrphanCheck::Found {
                outputs: vec![
                    orphan("gliff-401", 1920, 1080, false),
                    orphan("gliff-402", 1920, 1080, true)
                ]
            }
        );
    }
    // A server takes the pid while its disabled output is being enabled:
    // checked again right before the removal.
    std::fs::write(host.dir.path().join("starts-on-enable"), "401").unwrap();
    let names: Vec<String> = ["gliff-400", "gliff-401"].map(Into::into).to_vec();
    let out = host
        .run(&["remove", "gliff-400", "gliff-401"], Some("live-1"))
        .await;
    let OrphanRemoval::Finished { results } = parse_removal(&out, &names).unwrap() else {
        panic!("{out}")
    };
    if !readable {
        assert_eq!(results[0].outcome, RemovalOutcome::InUse, "{out}");
    }
    assert_eq!(results[1].outcome, RemovalOutcome::InUse, "{out}");
    assert!(host.monitors().contains("gliff-400") && host.monitors().contains("gliff-401"));
    // Hyprland stops answering after the removal request: not "removed".
    host.flag("dies-on-remove");
    let names = vec!["gliff-402".to_owned()];
    let out = host.run(&["remove", "gliff-402"], Some("live-1")).await;
    assert_eq!(
        parse_removal(&out, &names).unwrap(),
        OrphanRemoval::Finished {
            results: vec![OutputRemoval {
                name: "gliff-402".into(),
                outcome: RemovalOutcome::Failed
            }]
        },
        "{out}"
    );
}

// MARK: Bounded runs

/// Waits until `pid` no longer exists (a reaped zombie included).
async fn gone(pid: Pid) -> bool {
    for _ in 0..300 {
        if rustix::process::test_kill_process(pid) == Err(rustix::io::Errno::SRCH) {
            return true;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    false
}

#[tokio::test]
async fn dropping_a_pending_call_kills_its_process_group() {
    let marker = tempfile::NamedTempFile::new().unwrap();
    let script = format!(
        "/bin/sleep 60 & echo $$ $! > '{}'; wait",
        marker.path().display()
    );
    let (_tx, rx) = watch::channel(false);
    let call = tokio::spawn(on_runtime(run_bounded(
        shell(&script),
        b"",
        Duration::from_secs(30),
        rx,
    )));
    let pids = tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            let text = std::fs::read_to_string(marker.path()).unwrap();
            if text.ends_with('\n') {
                break text
                    .split_whitespace()
                    .map(|pid| Pid::from_raw(pid.parse().unwrap()).unwrap())
                    .collect::<Vec<_>>();
            }
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    })
    .await
    .unwrap();
    // The caller drops the future while keeping its `HostMonitors`.
    call.abort();
    let _ = call.await;
    for pid in pids {
        assert!(gone(pid).await, "PID {pid} survived the dropped call");
    }
}

fn shell(script: &str) -> Command {
    let mut cmd = Command::new("/bin/sh");
    cmd.args(["-c", script])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    cmd
}

#[tokio::test]
async fn cancellation_and_the_time_limit_reap_the_process_group() {
    use rustix::process::test_kill_process;
    for cancelled in [true, false] {
        let marker = tempfile::NamedTempFile::new().unwrap();
        let script = format!(
            "/bin/sleep 60 & echo $$ $! > '{}'; wait",
            marker.path().display()
        );
        let (tx, rx) = watch::channel(false);
        let limit = Duration::from_millis(if cancelled { 30_000 } else { 300 });
        let run = tokio::spawn(run_bounded(shell(&script), b"", limit, rx));
        let pids = tokio::time::timeout(Duration::from_secs(5), async {
            loop {
                let text = std::fs::read_to_string(marker.path()).unwrap();
                if text.ends_with('\n') {
                    break text
                        .split_whitespace()
                        .map(|pid| Pid::from_raw(pid.parse().unwrap()).unwrap())
                        .collect::<Vec<_>>();
                }
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
        })
        .await
        .unwrap();
        if cancelled {
            tx.send_replace(true);
        }
        let result = tokio::time::timeout(Duration::from_secs(5), run)
            .await
            .unwrap()
            .unwrap();
        if cancelled {
            assert!(matches!(result, Ok(Run::Cancelled)), "{result:?}");
        } else {
            assert!(
                matches!(result, Err(GliffError::Transport { ref message }) if message.contains("timed out")),
                "{result:?}"
            );
        }
        for pid in pids {
            assert_eq!(test_kill_process(pid), Err(rustix::io::Errno::SRCH));
        }
    }
    // Cancelled before starting: nothing runs.
    let (tx, rx) = watch::channel(false);
    tx.send_replace(true);
    assert!(matches!(
        run_bounded(shell("exit 0"), b"", Duration::from_secs(1), rx).await,
        Ok(Run::Cancelled)
    ));
}

#[tokio::test]
async fn ssh_failures_are_redacted_and_oversized_reports_refused() {
    let rx = || watch::channel(false).1;
    let failed = run_bounded(
        shell("cat >/dev/null; echo 'secret Permission denied (publickey).' >&2; exit 255"),
        SCRIPT.as_bytes(),
        Duration::from_secs(5),
        rx(),
    )
    .await;
    assert!(
        matches!(failed, Err(GliffError::Setup { ref message }) if !message.contains("secret")),
        "{failed:?}"
    );
    let flood = run_bounded(
        shell("head -c 200000 /dev/zero | tr '\\0' 'x'"),
        b"",
        Duration::from_secs(5),
        rx(),
    )
    .await;
    assert!(
        matches!(flood, Err(GliffError::Protocol { .. })),
        "{flood:?}"
    );
    // The script reaches the remote shell intact through stdin.
    let echoed = run_bounded(
        shell("cat"),
        SCRIPT.as_bytes(),
        Duration::from_secs(5),
        rx(),
    )
    .await;
    assert!(matches!(echoed, Ok(Run::Output(ref text)) if text == SCRIPT));
}
