//! orchdi lifecycle: spawn and track `orchd supervise` leaves via pidfiles.
//!
//! Each service's supervisor runs as a detached process whose pid lives in
//! `<state>/run/<label>.pid` and whose stdout/stderr go to `<state>/logs/
//! <label>.log`. start spawns them; stop SIGTERMs them (the supervisor then
//! runs the service's stop/post_stop and exits); status reads the pidfiles.

use std::fs;
use std::os::unix::process::CommandExt;
use std::path::PathBuf;
use std::process::{Command, Stdio};

use crate::config::Config;
use crate::orchdi::{service_label, supervise_spec_path};
use crate::platform::PlatformError;

fn run_dir(config: &Config) -> PathBuf {
    config.state_dir.join("run")
}
fn logs_dir(config: &Config) -> PathBuf {
    config.state_dir.join("logs")
}
fn pidfile(config: &Config, label: &str) -> PathBuf {
    run_dir(config).join(format!("{label}.pid"))
}
fn logfile(config: &Config, label: &str) -> PathBuf {
    logs_dir(config).join(format!("{label}.log"))
}

fn orchd_exe() -> String {
    std::env::current_exe()
        .ok()
        .and_then(|p| p.to_str().map(String::from))
        .unwrap_or_else(|| "orchd".to_string())
}

fn read_pid(pf: &PathBuf) -> Option<i32> {
    fs::read_to_string(pf).ok()?.trim().parse().ok()
}

/// kill(pid, 0): true if the process exists and we can signal it.
fn alive(pid: i32) -> bool {
    unsafe { libc::kill(pid, 0) == 0 }
}

/// Stems of files with `ext` in `dir` (e.g. spec labels, pidfile labels).
fn stems(dir: PathBuf, ext: &str) -> Vec<String> {
    let mut out = Vec::new();
    if let Ok(rd) = fs::read_dir(dir) {
        for e in rd.flatten() {
            let p = e.path();
            if p.extension().map(|x| x == ext).unwrap_or(false) {
                if let Some(s) = p.file_stem().and_then(|s| s.to_str()) {
                    out.push(s.to_string());
                }
            }
        }
    }
    out
}

/// Labels to act on: the named services, else every generated spec.
fn labels_to_start(services: &[String], config: &Config) -> Vec<String> {
    if services.is_empty() {
        stems(config.state_dir.join("supervise"), "json")
    } else {
        services.iter().map(|s| service_label(config, s)).collect()
    }
}

/// Labels to stop: the named services, else every running pidfile.
fn labels_to_stop(services: &[String], config: &Config) -> Vec<String> {
    if services.is_empty() {
        stems(run_dir(config), "pid")
    } else {
        services.iter().map(|s| service_label(config, s)).collect()
    }
}

pub fn start(services: &[String], config: &Config) -> Result<(), PlatformError> {
    fs::create_dir_all(run_dir(config))?;
    fs::create_dir_all(logs_dir(config))?;

    for label in labels_to_start(services, config) {
        if let Some(pid) = read_pid(&pidfile(config, &label)) {
            if alive(pid) {
                continue; // already supervised
            }
        }
        let spec = supervise_spec_path(config, &label);
        let out = fs::File::create(logfile(config, &label))?;
        let err = out.try_clone()?;
        let child = Command::new(orchd_exe())
            .arg("supervise")
            .arg("--spec")
            .arg(&spec)
            .stdin(Stdio::null())
            .stdout(Stdio::from(out))
            .stderr(Stdio::from(err))
            .process_group(0) // own process group: survives orchd exiting
            .spawn()
            .map_err(|e| PlatformError::LifecycleFailed(format!("spawn supervisor: {e}")))?;
        fs::write(pidfile(config, &label), child.id().to_string())?;
    }
    Ok(())
}

pub fn stop(services: &[String], config: &Config) -> Result<(), PlatformError> {
    for label in labels_to_stop(services, config) {
        let pf = pidfile(config, &label);
        if let Some(pid) = read_pid(&pf) {
            // SIGTERM the supervisor; it runs the service's stop + post_stop.
            unsafe {
                libc::kill(pid, libc::SIGTERM);
            }
        }
        let _ = fs::remove_file(&pf);
    }
    Ok(())
}

pub fn status(config: &Config, as_json: bool) -> Result<(), PlatformError> {
    let mut rows: Vec<(String, Option<i32>, bool)> = Vec::new();
    for label in stems(run_dir(config), "pid") {
        let pid = read_pid(&pidfile(config, &label));
        let running = pid.map(alive).unwrap_or(false);
        rows.push((label, pid, running));
    }

    if as_json {
        let items: Vec<String> = rows
            .iter()
            .map(|(l, pid, r)| {
                format!(
                    "{{\"label\":\"{}\",\"pid\":{},\"running\":{}}}",
                    l,
                    pid.unwrap_or(0),
                    r
                )
            })
            .collect();
        println!("[{}]", items.join(","));
    } else if rows.is_empty() {
        println!("no orchdi services");
    } else {
        for (label, pid, running) in rows {
            println!(
                "{:<28} {:<8} {}",
                label,
                pid.map(|p| p.to_string()).unwrap_or_else(|| "-".to_string()),
                if running { "running" } else { "stopped" }
            );
        }
    }
    Ok(())
}

pub fn logs(service: &str, follow: bool, lines: u32, config: &Config) -> Result<(), PlatformError> {
    let label = service_label(config, service);
    let log = logfile(config, &label);
    let mut cmd = Command::new("tail");
    cmd.arg("-n").arg(lines.to_string());
    if follow {
        cmd.arg("-f");
    }
    cmd.arg(&log);
    cmd.status()
        .map_err(|e| PlatformError::LifecycleFailed(format!("tail: {e}")))?;
    Ok(())
}
