use std::process::Command;

use crate::config::Config;
use crate::platform::PlatformError;

fn scope_flag(config: &Config) -> Option<&'static str> {
    if config.scope.is_user() { Some("--user") } else { None }
}

/// Start services via systemctl.
/// If `services` is empty, starts the orch target (all managed services).
pub fn start(services: &[String], config: &Config) -> Result<(), PlatformError> {
    if services.is_empty() {
        systemctl(&["start", &config.target_name()], config)
    } else {
        let unit_names: Vec<String> = services.iter().map(|s| config.unit_name(s)).collect();
        let args: Vec<&str> = std::iter::once("start")
            .chain(unit_names.iter().map(|s| s.as_str()))
            .collect();
        systemctl(&args, config)
    }
}

pub fn stop(services: &[String], config: &Config) -> Result<(), PlatformError> {
    if services.is_empty() {
        systemctl(&["stop", &config.target_name()], config)
    } else {
        let unit_names: Vec<String> = services.iter().map(|s| config.unit_name(s)).collect();
        let args: Vec<&str> = std::iter::once("stop")
            .chain(unit_names.iter().map(|s| s.as_str()))
            .collect();
        systemctl(&args, config)
    }
}

/// Service status info parsed from systemctl show.
#[derive(Debug)]
pub struct ServiceStatus {
    pub name: String,
    pub active_state: String,
    pub sub_state: String,
    pub pid: Option<u32>,
}

/// Query status of all managed services.
/// Scans the units directory for generated .service files, then queries
/// systemctl show for each one.
pub fn status(config: &Config, as_json: bool) -> Result<(), PlatformError> {
    let units_dir = config.units_dir();
    let mut statuses: Vec<ServiceStatus> = Vec::new();

    // Read unit files from the units directory
    let entries = std::fs::read_dir(&units_dir).map_err(|e| {
        PlatformError::LifecycleFailed(format!(
            "cannot read units directory '{}': {}. Run 'orchd generate' first.",
            units_dir.display(),
            e
        ))
    })?;

    let ns_prefix = format!("{}-", config.namespace);

    for entry in entries.flatten() {
        let filename = entry.file_name().to_string_lossy().to_string();

        // Only query .service units (skip ready gates, target)
        if !filename.ends_with(".service") {
            continue;
        }
        if filename.contains("-ready.service") {
            continue;
        }
        if !filename.starts_with(&ns_prefix) {
            continue;
        }

        // Extract service name: orch-django.service → django
        let service_name = filename
            .strip_prefix(&ns_prefix)
            .and_then(|s| s.strip_suffix(".service"))
            .unwrap_or(&filename)
            .to_string();

        let status = query_unit_status(&filename, config)?;
        statuses.push(ServiceStatus {
            name: service_name,
            active_state: status.0,
            sub_state: status.1,
            pid: status.2,
        });
    }

    statuses.sort_by(|a, b| a.name.cmp(&b.name));

    if as_json {
        print_status_json(&statuses);
    } else {
        print_status_table(&statuses);
    }

    Ok(())
}

fn query_unit_status(unit_name: &str, config: &Config) -> Result<(String, String, Option<u32>), PlatformError> {
    let mut cmd = Command::new("systemctl");
    if let Some(f) = scope_flag(config) { cmd.arg(f); }
    let output = cmd
        .args(["show", unit_name, "--property=ActiveState,SubState,MainPID"])
        .output()
        .map_err(|e| PlatformError::LifecycleFailed(format!("systemctl show: {}", e)))?;

    let stdout = String::from_utf8_lossy(&output.stdout);

    let mut active_state = "unknown".to_string();
    let mut sub_state = "unknown".to_string();
    let mut pid: Option<u32> = None;

    for line in stdout.lines() {
        if let Some(val) = line.strip_prefix("ActiveState=") {
            active_state = val.to_string();
        } else if let Some(val) = line.strip_prefix("SubState=") {
            sub_state = val.to_string();
        } else if let Some(val) = line.strip_prefix("MainPID=") {
            if let Ok(p) = val.parse::<u32>() {
                if p > 0 {
                    pid = Some(p);
                }
            }
        }
    }

    Ok((active_state, sub_state, pid))
}

fn print_status_table(statuses: &[ServiceStatus]) {
    // Header
    println!(
        "{:<24} {:<12} {:<12} {}",
        "SERVICE", "STATE", "SUB", "PID"
    );
    println!("{}", "-".repeat(60));

    for s in statuses {
        let pid_str = s.pid.map_or("-".to_string(), |p| p.to_string());
        println!(
            "{:<24} {:<12} {:<12} {}",
            s.name, s.active_state, s.sub_state, pid_str
        );
    }
}

fn print_status_json(statuses: &[ServiceStatus]) {
    print!("[");
    for (i, s) in statuses.iter().enumerate() {
        if i > 0 {
            print!(",");
        }
        print!(
            "\n  {{\"name\":\"{}\",\"state\":\"{}\",\"sub\":\"{}\",\"pid\":{}}}",
            s.name,
            s.active_state,
            s.sub_state,
            s.pid.map_or("null".to_string(), |p| p.to_string())
        );
    }
    println!("\n]");
}

/// Tail logs for a service via journalctl.
/// This replaces the current process (exec) so the user gets live output.
pub fn logs(
    service: &str,
    follow: bool,
    lines: u32,
    config: &Config,
) -> Result<(), PlatformError> {
    let unit_name = config.unit_name(service);
    let mut args: Vec<String> = Vec::new();
    if config.scope.is_user() { args.push("--user".to_string()); }
    args.push("-u".to_string()); args.push(unit_name.clone());
    args.push("--no-pager".to_string());
    args.push("-n".to_string()); args.push(lines.to_string());
    if follow { args.push("-f".to_string()); }

    let status = Command::new("journalctl")
        .args(&args)
        .status()
        .map_err(|e| PlatformError::LifecycleFailed(format!("journalctl: {}", e)))?;

    if !status.success() {
        return Err(PlatformError::LifecycleFailed(format!(
            "journalctl exited with code {}",
            status.code().unwrap_or(-1)
        )));
    }

    Ok(())
}

fn systemctl(args: &[&str], config: &Config) -> Result<(), PlatformError> {
    let mut cmd = Command::new("systemctl");
    if let Some(f) = scope_flag(config) { cmd.arg(f); }
    let output = cmd
        .args(args)
        .output()
        .map_err(|e| {
            PlatformError::LifecycleFailed(format!("systemctl {}: {}", args.join(" "), e))
        })?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(PlatformError::LifecycleFailed(format!(
            "systemctl {} failed: {}",
            args.join(" "),
            stderr.trim()
        )));
    }

    Ok(())
}
