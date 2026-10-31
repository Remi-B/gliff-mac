//! Live orphaned-monitor probe through the public facade (task 14).
//! Prints one JSON object: what was found or removed, and how long it took.
//! Output names only: no host names or paths.
//!
//! usage: monitor_probe HOST USER ABSOLUTE_IDENTITY ACTION [NAME]...
//!   check           list the host's orphaned gliff-<pid> outputs
//!   remove NAME...  remove those outputs (each re-checked first)
//!   cancel          start a check and cancel it after 100 ms
use gliff_mac_core::*;
use std::time::{Duration, Instant};

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 5 {
        eprintln!("usage: monitor_probe HOST USER ABSOLUTE_IDENTITY check|remove NAME...|cancel");
        std::process::exit(2);
    }
    let monitors = HostMonitors::new(ConnectionTarget::Ssh {
        host: args[1].clone(),
        user: Some(args[2].clone()),
        port: None,
        identity_file: Some(args[3].clone()),
        server_path: None,
        headless: true,
        output: None,
        video_mode: VideoMode::Auto,
    })
    .unwrap_or_else(|e| fail(&e));
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap();
    let started = Instant::now();
    let result = runtime.block_on(async {
        match args[4].as_str() {
            "check" => monitors.find_orphans().await.map(|check| match check {
                OrphanCheck::Found { outputs } => format!(
                    "\"found\":[{}]",
                    outputs
                        .iter()
                        .map(|o| format!(
                            "{{\"name\":\"{}\",\"width\":{},\"height\":{},\"enabled\":{}}}",
                            o.name, o.width, o.height, o.enabled
                        ))
                        .collect::<Vec<_>>()
                        .join(",")
                ),
                OrphanCheck::Unavailable { reason } => format!("\"unavailable\":\"{reason:?}\""),
                OrphanCheck::Cancelled => "\"cancelled\":true".into(),
            }),
            "remove" => monitors
                .remove_orphans(args[5..].to_vec())
                .await
                .map(|removal| match removal {
                    OrphanRemoval::Finished { results } => format!(
                        "\"results\":[{}]",
                        results
                            .iter()
                            .map(|r| format!(
                                "{{\"name\":\"{}\",\"outcome\":\"{:?}\"}}",
                                r.name, r.outcome
                            ))
                            .collect::<Vec<_>>()
                            .join(",")
                    ),
                    OrphanRemoval::Unavailable { reason } => {
                        format!("\"unavailable\":\"{reason:?}\"")
                    }
                    OrphanRemoval::Cancelled => "\"cancelled\":true".into(),
                }),
            "cancel" => {
                let check = monitors.find_orphans();
                let cancel = async {
                    tokio::time::sleep(Duration::from_millis(100)).await;
                    monitors.cancel();
                    std::future::pending::<()>().await
                };
                tokio::select! {
                    result = check => result.map(|check| format!("\"cancelled\":{}", check == OrphanCheck::Cancelled)),
                    _ = cancel => unreachable!(),
                }
            }
            other => {
                eprintln!("unknown action {other}");
                std::process::exit(2);
            }
        }
    });
    match result {
        Ok(body) => println!(
            "{{\"action\":\"{}\",{body},\"elapsed_ms\":{}}}",
            args[4],
            started.elapsed().as_millis()
        ),
        Err(e) => fail(&e),
    }
}

fn fail(error: &GliffError) -> ! {
    // Bridge messages are fixed, redacted guidance.
    println!("{{\"error\":{:?}}}", error.to_string());
    std::process::exit(1);
}
