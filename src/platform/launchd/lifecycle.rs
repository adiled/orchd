use std::path::PathBuf;
use std::process::Command;

use crate::config::Config;
use crate::platform::PlatformError;

use super::{disabled_units_dir, install_dir, plist_dest_path};
use crate::orchdi::service_label;

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
        Ok(o) if o.status.success() => String::from_utf8_lossy(&o.stdout).trim().to_string(),
        _ => "0".to_string(),
    }
}

fn is_loaded(target: &str) -> bool {
    Command::new("launchctl")
        .args(["print", target])
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}

fn wait_unloaded(target: &str, tries: u32) -> bool {
    for _ in 0..tries {
        if !is_loaded(target) {
            return true;
        }
        std::thread::sleep(std::time::Duration::from_millis(100));
    }
    !is_loaded(target)
}

pub(crate) fn bootout_label(config: &Config, label: &str) -> bool {
    let tgt = service_target(config, label);
    for _ in 0..2 {
        if !is_loaded(&tgt) {
            return true;
        }
        let _ = Command::new("launchctl").args(["bootout", &tgt]).output();
        if wait_unloaded(&tgt, 300) {
            return true;
        }
    }
    false
}

fn plist_source(config: &Config, label: &str) -> Option<PathBuf> {
    [
        plist_dest_path(config, label),
        disabled_units_dir(config).join(format!("{}.plist", label)),
    ]
    .into_iter()
    .find(|p| p.exists())
}

pub fn start(services: &[String], config: &Config) -> Result<(), PlatformError> {
    let labels = labels_for(services, config)?;
    let dom = domain(config);
    for label in &labels {
        let plist = plist_source(config, label).ok_or_else(|| {
            PlatformError::LifecycleFailed(format!("no bed is planted for {}", label))
        })?;
        if !bootout_label(config, label) {
            return Err(PlatformError::LifecycleFailed(format!(
                "launchd still holds {} after bootout",
                service_target(config, label)
            )));
        }
        let out = Command::new("launchctl")
            .args(["bootstrap", &dom, plist.to_str().unwrap_or("")])
            .output()
            .map_err(|e| PlatformError::LifecycleFailed(format!("launchctl bootstrap: {}", e)))?;
        if !out.status.success() {
            return Err(PlatformError::LifecycleFailed(format!(
                "launchctl bootstrap {} {} failed: {}",
                dom,
                plist.display(),
                String::from_utf8_lossy(&out.stderr).trim()
            )));
        }
    }
    Ok(())
}

pub fn stop(services: &[String], config: &Config) -> Result<(), PlatformError> {
    let labels = labels_for(services, config)?;
    let stuck: Vec<&String> = labels
        .iter()
        .filter(|label| !bootout_label(config, label))
        .collect();
    if stuck.is_empty() {
        Ok(())
    } else {
        Err(PlatformError::LifecycleFailed(format!(
            "launchd still holds {} after bootout",
            stuck
                .iter()
                .map(|l| l.as_str())
                .collect::<Vec<_>>()
                .join(", ")
        )))
    }
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
            units_dir.display(),
            e
        ))
    })?;

    let grove_prefix = format!("{}.", config.grove);
    let mut statuses: Vec<ServiceStatus> = Vec::new();

    let disabled = std::fs::read_dir(disabled_units_dir(config))
        .into_iter()
        .flatten()
        .flatten()
        .map(|e| (e, true));
    for (entry, is_disabled) in entries.flatten().map(|e| (e, false)).chain(disabled) {
        let filename = entry.file_name().to_string_lossy().to_string();
        if !filename.ends_with(".plist") {
            continue;
        }
        if !filename.starts_with(&grove_prefix) {
            continue;
        }

        let label = filename
            .strip_suffix(".plist")
            .unwrap_or(&filename)
            .to_string();
        let svc_name = label
            .strip_prefix(&grove_prefix)
            .unwrap_or(&label)
            .to_string();

        let (mut state, sub, pid) = query_status(&label, config);
        if is_disabled && pid.is_none() && state == "inactive" {
            state = "disabled".to_string();
        }
        statuses.push(ServiceStatus {
            name: svc_name,
            active_state: state,
            sub_state: sub,
            pid,
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

/// Parse `launchctl print <target>` for state + PID.
pub fn pid_of(label: &str, config: &Config) -> Option<u32> {
    query_status(label, config).2
}

fn query_status(label: &str, config: &Config) -> (String, String, Option<u32>) {
    let tgt = service_target(config, label);
    let out = Command::new("launchctl").args(["print", &tgt]).output();
    let stdout = match out {
        Ok(o) if o.status.success() => String::from_utf8_lossy(&o.stdout).into_owned(),
        _ => return ("inactive".to_string(), "dead".to_string(), None),
    };
    parse_launchctl_status(&stdout)
}

fn parse_launchctl_status(stdout: &str) -> (String, String, Option<u32>) {
    let mut pid: Option<u32> = None;
    let mut state = "inactive".to_string();
    let mut sub = "dead".to_string();

    for line in stdout.lines() {
        let t = line.trim();
        if pid.is_none() {
            if let Some(v) = t.strip_prefix("pid =") {
                if let Ok(p) = v.trim().trim_end_matches(',').parse::<u32>() {
                    if p > 0 {
                        pid = Some(p);
                    }
                }
            }
        }
        if sub == "dead" {
            if let Some(v) = t.strip_prefix("state =") {
                sub = v.trim().trim_end_matches(',').to_string();
                state = if sub == "running" {
                    "active".to_string()
                } else {
                    "inactive".to_string()
                };
            }
        }
    }
    (state, sub, pid)
}

fn print_status_table(statuses: &[ServiceStatus]) {
    println!("{:<24} {:<12} {:<12} {}", "SERVICE", "STATE", "SUB", "PID");
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

/// Tail StandardOutPath + StandardErrorPath for a service. launchd has no
/// journald, so we shell out to `tail`.
pub fn logs(service: &str, follow: bool, lines: u32, config: &Config) -> Result<(), PlatformError> {
    let (out_path, err_path) = super::generate::default_log_paths(config, service);

    let mut args: Vec<String> = vec!["-n".to_string(), lines.to_string()];
    if follow {
        args.push("-f".to_string());
    }
    args.push(out_path);
    args.push(err_path);

    let status = Command::new("tail")
        .args(&args)
        .status()
        .map_err(|e| PlatformError::LifecycleFailed(format!("tail: {}", e)))?;

    if !status.success() {
        return Err(PlatformError::LifecycleFailed(format!(
            "tail exited with code {}",
            status.code().unwrap_or(-1)
        )));
    }
    Ok(())
}

/// Resolve target service names to launchd labels. Empty list → all managed
/// plists discovered in the install dir.
fn labels_for(services: &[String], config: &Config) -> Result<Vec<String>, PlatformError> {
    if !services.is_empty() {
        return Ok(services.iter().map(|s| service_label(config, s)).collect());
    }

    let install = install_dir(config);
    let mut labels = Vec::new();
    let grove_prefix = format!("{}.", config.grove);
    if let Ok(entries) = std::fs::read_dir(&install) {
        for e in entries.flatten() {
            let name = e.file_name().to_string_lossy().to_string();
            if name.ends_with(".plist") && name.starts_with(&grove_prefix) {
                labels.push(name.trim_end_matches(".plist").to_string());
            }
        }
    }
    Ok(labels)
}

#[cfg(test)]
#[allow(non_snake_case)]
mod tests {
    use super::*;

    const RUNNING_PRINT: &str = concat!(
        "com.apple.xpc.launchd.agent = {\n",
        "\tstate = running\n",
        "\tpid = 28700\n",
        "\tprogram = /bin/sleep\n",
        "\tjetsam coalition = {\n",
        "\t\ttype = jetsam\n",
        "\t}\n",
        "\tendpoint = {\n",
        "\t\tcom.apple.builtin.iokit = {\n",
        "\t\t\ttype = state = active\n",
        "\t\t}\n",
        "\t}\n",
        "\tsocket = {\n",
        "\t\ttype = state = active\n",
        "\t}\n",
        "}\n"
    );

    #[test]
    fn test_parse_launchctl_status__job_state_wins_over_nested() {
        let (state, sub, pid) = parse_launchctl_status(RUNNING_PRINT);
        assert_eq!(state, "active", "a running job must not report inactive");
        assert_eq!(sub, "running");
        assert_eq!(pid, Some(28700));
    }

    #[test]
    fn test_parse_launchctl_status__not_running_job() {
        let text = concat!(
            "com.apple.xpc.launchd.agent = {\n",
            "\tstate = not running\n",
            "\tlast exit code = 0\n",
            "\tjetsam coalition = {\n",
            "\t\ttype = state = active\n",
            "\t}\n",
            "}\n"
        );
        let (state, sub, pid) = parse_launchctl_status(text);
        assert_eq!(state, "inactive");
        assert_eq!(sub, "not running");
        assert_eq!(pid, None);
    }

    #[test]
    fn test_parse_launchctl_status__pid_only() {
        let (state, sub, pid) =
            parse_launchctl_status("com.apple.xpc.launchd.agent = {\n\tpid = 5\n}\n");
        assert_eq!(state, "inactive");
        assert_eq!(sub, "dead");
        assert_eq!(pid, Some(5));
    }

    #[test]
    fn test_parse_launchctl_status__empty_output() {
        assert_eq!(
            parse_launchctl_status(""),
            ("inactive".to_string(), "dead".to_string(), None)
        );
    }
}
