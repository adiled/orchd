//! The orchard rows: composable, pipe-able transforms.
//!
//! Each row reads JSON on stdin and writes JSON on stdout (except `tend`, which
//! has side effects). They are stateless and hold no policy. See ORCHARD.md.
//!
//!   seed  --sow-->  cutting  --plant-->  bed  --tend-->  tree (in a grove)
//!
//! - sow:   Spec (orch parse JSON) -> Cuttings (each service paired with its ExecSet)
//! - plant: Cuttings               -> Beds     (each service's native files, grouped)
//! - tend:  Beds                   -> running  (write + install + start)

use std::io::Read;

use serde::{Deserialize, Serialize};

use crate::config::Config;
use crate::exec::ExecSet;
use crate::platform::Platform;
use crate::types::{OrchFile, Service};

// ----- contracts -----------------------------------------------------------

/// A seed plus how to grow it: one service paired with the execution commands
/// the runtime produced for it. Output unit of `sow`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Cutting {
    pub service: Service,
    pub exec: ExecSet,
}

/// Output of `sow`: every materialized service as a cutting. The runtime's
/// knowledge is now captured entirely in command strings.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Cuttings {
    pub version: String,
    pub runtime: String,
    pub cuttings: Vec<Cutting>,
}

/// One generated native file: where it is written and what it is.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Artifact {
    /// unit | plist | supervise-spec | ready-gate | target
    pub kind: String,
    pub path: String,
    pub content: String,
}

/// The prepared ground for one tree: a service's native files, grouped. The
/// grove handle (systemd target) gets its own bed labeled with the grove.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Bed {
    pub label: String,
    pub artifacts: Vec<Artifact>,
}

/// Output of `plant`: a bed per service (plus the grove bed where applicable).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Beds {
    pub platform: String,
    pub namespace: String,
    pub scope: String,
    pub beds: Vec<Bed>,
}

#[derive(Debug, thiserror::Error)]
pub enum OrchardError {
    #[error("read stdin failed: {0}")]
    Stdin(#[from] std::io::Error),
    #[error("invalid JSON on stdin: {0}")]
    Json(#[from] serde_json::Error),
    #[error("runtime error: {0}")]
    Runtime(#[from] crate::runtime::RuntimeError),
    #[error("{0}")]
    Other(String),
}

fn read_stdin() -> Result<String, OrchardError> {
    let mut buf = String::new();
    std::io::stdin().read_to_string(&mut buf)?;
    Ok(buf)
}

// ----- sow: Spec -> Cuttings -----------------------------------------------

/// Runtime transform. Reads an Orchfile spec, takes a cutting of each enabled
/// service: the service plus the ExecSet for `config.runtime`. Pure: no image
/// pulls, no I/O beyond stdio.
pub fn sow(config: &Config) -> Result<(), OrchardError> {
    let input = read_stdin()?;
    let spec: OrchFile = serde_json::from_str(&input)?;

    let rt = crate::runtime::create_runtime(&config.runtime, config)?;

    let mut cuttings = Vec::new();
    for service in &spec.services {
        if service.disabled {
            continue;
        }
        match rt.exec_set(service) {
            Ok(exec) => cuttings.push(Cutting {
                service: service.clone(),
                exec,
            }),
            Err(e) => eprintln!("sow: skip {}: {}", service.name, e),
        }
    }

    let out = Cuttings {
        version: spec.version,
        runtime: config.runtime.clone(),
        cuttings,
    };
    println!("{}", serde_json::to_string_pretty(&out)?);
    Ok(())
}

// ----- plant: Cuttings -> Beds ---------------------------------------------

/// Platform transform. Reads cuttings, prepares a bed of native files for each.
/// Pure: produces content + paths, writes nothing.
pub fn plant(config: &Config) -> Result<(), OrchardError> {
    let input = read_stdin()?;
    let cuttings: Cuttings = serde_json::from_str(&input)?;

    let services: Vec<Service> = cuttings.cuttings.iter().map(|c| c.service.clone()).collect();
    let exec_sets: Vec<(usize, ExecSet)> = cuttings
        .cuttings
        .iter()
        .enumerate()
        .map(|(i, c)| (i, c.exec.clone()))
        .collect();

    let beds = match config.platform.as_str() {
        "launchd" => beds_launchd(&services, &exec_sets, config),
        _ => beds_systemd(&services, &exec_sets, config),
    };

    let out = Beds {
        platform: config.platform.clone(),
        namespace: config.namespace.clone(),
        scope: if config.scope.is_user() { "user" } else { "system" }.to_string(),
        beds,
    };
    println!("{}", serde_json::to_string_pretty(&out)?);
    Ok(())
}

fn beds_launchd(services: &[Service], exec_sets: &[(usize, ExecSet)], config: &Config) -> Vec<Bed> {
    use crate::platform::launchd::generate::{
        build_dep_gates, build_supervise_spec, generate_service_plist_with_deps, plist_filename,
        plist_label, supervise_spec_path,
    };
    let units_dir = config.units_dir();
    let mut beds = Vec::new();
    for (idx, exec) in exec_sets {
        let svc = &services[*idx];
        let label = plist_label(config, &svc.name);
        let deps = build_dep_gates(svc, services);
        let mut arts = Vec::new();

        if !deps.is_empty() || exec.stop.is_some() || exec.post_stop.is_some() {
            let spec = build_supervise_spec(svc, exec, config, &deps);
            arts.push(Artifact {
                kind: "supervise-spec".into(),
                path: supervise_spec_path(config, &label),
                content: serde_json::to_string_pretty(&spec).unwrap_or_default(),
            });
        }
        arts.push(Artifact {
            kind: "plist".into(),
            path: units_dir.join(plist_filename(config, &svc.name)).display().to_string(),
            content: generate_service_plist_with_deps(svc, exec, config, &deps),
        });
        beds.push(Bed { label, artifacts: arts });
    }
    beds
}

fn beds_systemd(services: &[Service], exec_sets: &[(usize, ExecSet)], config: &Config) -> Vec<Bed> {
    use crate::platform::systemd::generate::{
        generate_ready_gate, generate_service_unit, generate_target, services_needing_ready_gates,
    };
    let units_dir = config.units_dir();
    let gates = services_needing_ready_gates(services);
    let mut beds = Vec::new();

    for (idx, exec) in exec_sets {
        let svc = &services[*idx];
        let mut arts = vec![Artifact {
            kind: "unit".into(),
            path: units_dir.join(config.unit_name(&svc.name)).display().to_string(),
            content: generate_service_unit(svc, exec, config, &gates),
        }];
        if gates.contains(&svc.name) {
            let name = format!("{}-{}-ready.service", config.namespace, svc.name);
            arts.push(Artifact {
                kind: "ready-gate".into(),
                path: units_dir.join(&name).display().to_string(),
                content: generate_ready_gate(svc, config),
            });
        }
        beds.push(Bed { label: config.unit_name(&svc.name), artifacts: arts });
    }

    // The grove handle: its own bed (one target for the whole namespace).
    beds.push(Bed {
        label: config.target_name(),
        artifacts: vec![Artifact {
            kind: "target".into(),
            path: units_dir.join(config.target_name()).display().to_string(),
            content: generate_target(config),
        }],
    });
    beds
}

// ----- tend: Beds -> running -----------------------------------------------

/// Activation. Writes every artifact in every bed to its path, then installs and
/// (optionally) starts via the platform's init system. The only side-effecting row.
pub fn tend(config: &Config, start: bool) -> Result<(), OrchardError> {
    let input = read_stdin()?;
    let beds: Beds = serde_json::from_str(&input)?;

    for bed in &beds.beds {
        for a in &bed.artifacts {
            let path = std::path::PathBuf::from(&a.path);
            if let Some(parent) = path.parent() {
                std::fs::create_dir_all(parent)?;
            }
            std::fs::write(&path, &a.content)?;
            if !config.quiet {
                eprintln!("  wrote: {}", a.path);
            }
        }
    }

    // Install + start reuse the proven platform lifecycle.
    match beds.platform.as_str() {
        "launchd" => {
            crate::platform::launchd::LaunchdPlatform::new()
                .install(config)
                .map_err(|e| OrchardError::Other(e.to_string()))?;
            if start {
                crate::platform::launchd::lifecycle::start(&[], config)
                    .map_err(|e| OrchardError::Other(e.to_string()))?;
            }
        }
        _ => {
            crate::platform::systemd::SystemdPlatform::new()
                .install(config)
                .map_err(|e| OrchardError::Other(e.to_string()))?;
            if start {
                crate::platform::systemd::lifecycle::start(&[], config)
                    .map_err(|e| OrchardError::Other(e.to_string()))?;
            }
        }
    }
    Ok(())
}

#[cfg(test)]
#[allow(non_snake_case)]
mod tests {
    use super::*;
    use crate::config::Scope;
    use std::path::PathBuf;

    fn test_config(platform: &str) -> Config {
        Config {
            orchfile: PathBuf::from("/t/Orchfile"),
            overlays: vec![],
            runtime: "bare".into(),
            platform: platform.into(),
            scope: Scope::User,
            state_dir: PathBuf::from("/t/.orch"),
            project_dir: PathBuf::from("/t"),
            data_dir: PathBuf::from("/t/.orch/data"),
            orch_bin: PathBuf::from("orch"),
            namespace: "orch".into(),
            args: vec![],
            verbose: false,
            quiet: true,
        }
    }

    fn host_service(name: &str, run: &str) -> Service {
        let json = format!(
            r#"{{"name":"{name}","mode":"host","run_command":"{run}","oneshot":false,
                "disabled":false,"recreate":"never","restart":{{"policy":"no"}},
                "timeouts":{{}},"resources":{{}},"logging":{{}}}}"#
        );
        serde_json::from_str(&json).unwrap()
    }

    fn exec(start: &str) -> ExecSet {
        ExecSet { start: start.into(), pre_start: None, stop: None, post_stop: None }
    }

    #[test]
    fn test_beds_systemd__service_beds_plus_grove_bed() {
        let cfg = test_config("systemd");
        let svcs = vec![host_service("web", "/usr/bin/web")];
        let es = vec![(0usize, exec("/usr/bin/web"))];
        let beds = beds_systemd(&svcs, &es, &cfg);

        let labels: Vec<&str> = beds.iter().map(|b| b.label.as_str()).collect();
        assert!(labels.contains(&"orch-web.service"));
        assert!(labels.contains(&"orch.target")); // grove handle gets its own bed

        let web = beds.iter().find(|b| b.label == "orch-web.service").unwrap();
        assert_eq!(web.artifacts.len(), 1);
        assert_eq!(web.artifacts[0].kind, "unit");
        assert!(web.artifacts[0].content.contains("ExecStart=/bin/bash -c '/usr/bin/web'"));
    }

    #[test]
    fn test_beds_launchd__container_bed_groups_plist_and_spec() {
        let cfg = test_config("launchd");
        let svcs = vec![host_service("cache", "container run --name orch-cache redis")];
        let es = vec![(
            0usize,
            ExecSet {
                start: "container run --name orch-cache redis".into(),
                pre_start: Some("container image pull redis".into()),
                stop: Some("container stop orch-cache".into()),
                post_stop: Some("container delete --force orch-cache".into()),
            },
        )];
        let beds = beds_launchd(&svcs, &es, &cfg);

        assert_eq!(beds.len(), 1);
        let bed = &beds[0];
        assert_eq!(bed.label, "orch.cache");
        // teardown -> the bed groups both the plist and the supervise-spec
        let kinds: Vec<&str> = bed.artifacts.iter().map(|a| a.kind.as_str()).collect();
        assert!(kinds.contains(&"plist"));
        assert!(kinds.contains(&"supervise-spec"));
        let plist = bed.artifacts.iter().find(|a| a.kind == "plist").unwrap();
        assert!(plist.content.contains("<string>supervise</string>"));
    }

    #[test]
    fn test_contracts_roundtrip() {
        let cut = Cuttings {
            version: "0.2.1".into(),
            runtime: "apple".into(),
            cuttings: vec![Cutting { service: host_service("a", "x"), exec: exec("x") }],
        };
        let back: Cuttings = serde_json::from_str(&serde_json::to_string(&cut).unwrap()).unwrap();
        assert_eq!(back.cuttings.len(), 1);

        let beds = Beds {
            platform: "launchd".into(),
            namespace: "orch".into(),
            scope: "user".into(),
            beds: vec![Bed {
                label: "orch.a".into(),
                artifacts: vec![Artifact { kind: "plist".into(), path: "/x".into(), content: "y".into() }],
            }],
        };
        let back: Beds = serde_json::from_str(&serde_json::to_string(&beds).unwrap()).unwrap();
        assert_eq!(back.beds[0].artifacts[0].kind, "plist");
    }
}
