use std::process::Command;

use crate::config::Config;
use crate::platform::PlatformError;

use super::{install_dir, plist_dest_path};
use super::generate::plist_label;

/// launchctl domain target: `gui/<uid>` (user) or `system` (system).
fn domain(config: &Config) -> String {
    if config.scope.is_user() {
        format!("gui/{}", current_uid())
    } else {
        "system".to_string()
    }
}

/// Fully qualified service target: `<domain>/<label>`.
fn service_target(config: &Config, label: &str) -> String {
    format!("{}/{}", domain(config), label)
}

fn current_uid() -> String {
    let out = Command::new("id").arg("-u").output();
    match out {
        Ok(o) if o.status.success() => {
            String::from_utf8_lossy(&o.stdout).trim().to_string()
        }
        _ => "0".to_string(),
    }
}

/// Start services (bootstrap their plists, or kickstart if already loaded).
pub fn start(services: &[String], config: &Config) -> Result<(), PlatformError> {
    let labels = labels_for(services, config)?;
    for label in &labels {
        let plist = plist_dest_path(config, label);
        // bootstrap is idempotent-ish: if already loaded, kickstart instead.
        let dom = domain(config);
        let bootstrap = Command::new("launchctl")
            .args(["bootstrap", &dom, plist.to_str().unwrap_or("")])
            .output();
        let already = match &bootstrap {
            Ok(o) => !o.status.success(),
            Err(_) => true,
        };
        if already {
            let tgt = service_target(config, label);
            let st = Command::new("launchctl")
                .args(["kickstart", "-k", &tgt])
                .status()
                .map_err(|e| PlatformError::LifecycleFailed(format!("launchctl kickstart: {}", e)))?;
            if !st.success() {
                return Err(PlatformError::LifecycleFailed(format!(
                    "launchctl kickstart {} failed", tgt
                )));
            }
        }
    }
    Ok(())
}

pub fn stop(services: &[String], config: &Config) -> Result<(), PlatformError> {
    let labels = labels_for(services, config)?;
    let dom = domain(config);
    for label in &labels {
        let plist = plist_dest_path(config, label);
        // bootout unloads the service.
        let _ = Command::new("launchctl")
            .args(["bootout", &dom, plist.to_str().unwrap_or("")])
            .status();
    }
    Ok(())
}

pub fn restart(services: &[String], config: &Config) -> Result<(), PlatformError> {
    stop(services, config)?;
    start(services, config)
}

#[derive(Debug)]
pub struct ServiceStatus {
    pub name: String,
    pub active_state: String,
    pub sub_state: String,
    pub pid: Option<u32>,
}

/// Query status of all managed services by scanning the units dir for plists.
pub fn status(config: &Config, as_json: bool) -> Result<(), PlatformError> {
    let units_dir = config.units_dir();
    let entries = std::fs::read_dir(&units_dir).map_err(|e| {
        PlatformError::LifecycleFailed(format!(
            "cannot read units directory '{}': {}. Run 'orchd generate' first.",
            units_dir.display(), e
        ))
    })?;

    let ns_prefix = format!("{}.", config.namespace);
    let mut statuses: Vec<ServiceStatus> = Vec::new();

    for entry in entries.flatten() {
        let filename = entry.file_name().to_string_lossy().to_string();
        if !filename.ends_with(".plist") { continue; }
        if !filename.starts_with(&ns_prefix) { continue; }

        let label = filename.strip_suffix(".plist").unwrap_or(&filename).to_string();
        let svc_name = label.strip_prefix(&ns_prefix).unwrap_or(&label).to_string();

        let (state, sub, pid) = query_status(&label, config);
        statuses.push(ServiceStatus {
            name: svc_name, active_state: state, sub_state: sub, pid,
        });
    }

    statuses.sort_by(|a, b| a.name.cmp(&b.name));

    if as_json { print_status_json(&statuses); } else { print_status_table(&statuses); }
    Ok(())
}

/// Parse `launchctl print <target>` for state + PID.
fn query_status(label: &str, config: &Config) -> (String, String, Option<u32>) {
    let tgt = service_target(config, label);
    let out = Command::new("launchctl").args(["print", &tgt]).output();
    let stdout = match out {
        Ok(o) if o.status.success() => String::from_utf8_lossy(&o.stdout).into_owned(),
        _ => return ("inactive".to_string(), "dead".to_string(), None),
    };

    let mut pid: Option<u32> = None;
    let mut state = "inactive".to_string();
    let mut sub = "dead".to_string();

    for line in stdout.lines() {
        let t = line.trim();
        if let Some(v) = t.strip_prefix("pid =") {
            if let Ok(p) = v.trim().trim_end_matches(',').parse::<u32>() {
                if p > 0 { pid = Some(p); }
            }
        } else if let Some(v) = t.strip_prefix("state =") {
            sub = v.trim().trim_end_matches(',').to_string();
            state = if sub == "running" { "active".to_string() } else { "inactive".to_string() };
        }
    }
    (state, sub, pid)
}

fn print_status_table(statuses: &[ServiceStatus]) {
    println!("{:<24} {:<12} {:<12} {}", "SERVICE", "STATE", "SUB", "PID");
    println!("{}", "-".repeat(60));
    for s in statuses {
        let pid_str = s.pid.map_or("-".to_string(), |p| p.to_string());
        println!("{:<24} {:<12} {:<12} {}", s.name, s.active_state, s.sub_state, pid_str);
    }
}

fn print_status_json(statuses: &[ServiceStatus]) {
    print!("[");
    for (i, s) in statuses.iter().enumerate() {
        if i > 0 { print!(","); }
        print!(
            "\n  {{\"name\":\"{}\",\"state\":\"{}\",\"sub\":\"{}\",\"pid\":{}}}",
            s.name, s.active_state, s.sub_state,
            s.pid.map_or("null".to_string(), |p| p.to_string())
        );
    }
    println!("\n]");
}

/// Tail StandardOutPath + StandardErrorPath for a service. launchd has no
/// journald, so we shell out to `tail`.
pub fn logs(
    service: &str,
    follow: bool,
    lines: u32,
    config: &Config,
) -> Result<(), PlatformError> {
    let label = plist_label(config, service);
    let log_base = log_base(config);
    let out_path = format!("{}/{}.out.log", log_base, label);
    let err_path = format!("{}/{}.err.log", log_base, label);

    let mut args: Vec<String> = vec!["-n".to_string(), lines.to_string()];
    if follow { args.push("-f".to_string()); }
    args.push(out_path);
    args.push(err_path);

    let status = Command::new("tail")
        .args(&args)
        .status()
        .map_err(|e| PlatformError::LifecycleFailed(format!("tail: {}", e)))?;

    if !status.success() {
        return Err(PlatformError::LifecycleFailed(format!(
            "tail exited with code {}", status.code().unwrap_or(-1)
        )));
    }
    Ok(())
}

fn log_base(config: &Config) -> String {
    if config.scope.is_user() {
        let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
        format!("{}/Library/Logs", home)
    } else {
        "/Library/Logs".to_string()
    }
}

/// Resolve target service names to launchd labels. Empty list → all managed
/// plists discovered in the install dir.
fn labels_for(services: &[String], config: &Config) -> Result<Vec<String>, PlatformError> {
    if !services.is_empty() {
        return Ok(services.iter().map(|s| plist_label(config, s)).collect());
    }

    let install = install_dir(config);
    let mut labels = Vec::new();
    let ns_prefix = format!("{}.", config.namespace);
    if let Ok(entries) = std::fs::read_dir(&install) {
        for e in entries.flatten() {
            let name = e.file_name().to_string_lossy().to_string();
            if name.ends_with(".plist") && name.starts_with(&ns_prefix) {
                labels.push(name.trim_end_matches(".plist").to_string());
            }
        }
    }
    Ok(labels)
}
