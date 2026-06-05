//! The orchard rows: composable, pipe-able transforms.
//!
//! Each row reads JSON on stdin and writes JSON on stdout (except `tend`, which
//! has side effects). They are stateless and hold no policy. See ORCHARD.md.
//!
//!   spec  --sow-->  sown  --plant-->  artifacts  --tend-->  running grove
//!
//! - sow:   Spec (orch parse JSON) -> Sown   (each service paired with its ExecSet)
//! - plant: Sown                   -> Artifacts (native units/plists/specs + paths)
//! - tend:  Artifacts              -> write + install + start

use std::io::Read;

use serde::{Deserialize, Serialize};

use crate::config::Config;
use crate::exec::ExecSet;
use crate::platform::Platform;
use crate::types::{OrchFile, Service};

// ----- contracts -----------------------------------------------------------

/// One service paired with the execution commands the runtime produced for it.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Tree {
    pub service: Service,
    pub exec: ExecSet,
}

/// Output of `sow`: the spec, with every materialized service annotated by its
/// ExecSet. The runtime's knowledge is now captured entirely in command strings.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Sown {
    pub version: String,
    pub runtime: String,
    pub trees: Vec<Tree>,
}

/// One generated file plus where it is written and what it is.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Artifact {
    /// unit | plist | supervise-spec | ready-gate | target
    pub kind: String,
    pub label: String,
    pub path: String,
    pub content: String,
}

/// Output of `plant`: the native artifacts for the chosen platform.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Artifacts {
    pub platform: String,
    pub namespace: String,
    pub scope: String,
    pub artifacts: Vec<Artifact>,
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

// ----- sow: Spec -> Sown ---------------------------------------------------

/// Runtime transform. Reads an Orchfile spec, annotates each enabled service with
/// the ExecSet for `config.runtime`. Pure: no image pulls, no I/O beyond stdio.
pub fn sow(config: &Config) -> Result<(), OrchardError> {
    let input = read_stdin()?;
    let spec: OrchFile = serde_json::from_str(&input)?;

    let rt = crate::runtime::create_runtime(&config.runtime, config)?;

    let mut trees = Vec::new();
    for service in &spec.services {
        if service.disabled {
            continue;
        }
        match rt.exec_set(service) {
            Ok(exec) => trees.push(Tree {
                service: service.clone(),
                exec,
            }),
            Err(e) => eprintln!("sow: skip {}: {}", service.name, e),
        }
    }

    let sown = Sown {
        version: spec.version,
        runtime: config.runtime.clone(),
        trees,
    };
    println!("{}", serde_json::to_string_pretty(&sown)?);
    Ok(())
}

// ----- plant: Sown -> Artifacts --------------------------------------------

/// Platform transform. Reads a Sown document, renders the native artifacts for
/// `config.platform`. Pure: produces content + paths, writes nothing.
pub fn plant(config: &Config) -> Result<(), OrchardError> {
    let input = read_stdin()?;
    let sown: Sown = serde_json::from_str(&input)?;

    let services: Vec<Service> = sown.trees.iter().map(|t| t.service.clone()).collect();
    let exec_sets: Vec<(usize, ExecSet)> = sown
        .trees
        .iter()
        .enumerate()
        .map(|(i, t)| (i, t.exec.clone()))
        .collect();

    let artifacts = match config.platform.as_str() {
        "launchd" => render_launchd(&services, &exec_sets, config),
        _ => render_systemd(&services, &exec_sets, config),
    };

    let out = Artifacts {
        platform: config.platform.clone(),
        namespace: config.namespace.clone(),
        scope: if config.scope.is_user() { "user" } else { "system" }.to_string(),
        artifacts,
    };
    println!("{}", serde_json::to_string_pretty(&out)?);
    Ok(())
}

fn render_launchd(services: &[Service], exec_sets: &[(usize, ExecSet)], config: &Config) -> Vec<Artifact> {
    use crate::platform::launchd::generate::{
        build_dep_gates, build_supervise_spec, generate_service_plist_with_deps, plist_filename,
        plist_label, supervise_spec_path,
    };
    let units_dir = config.units_dir();
    let mut out = Vec::new();
    for (idx, exec) in exec_sets {
        let svc = &services[*idx];
        let label = plist_label(config, &svc.name);
        let deps = build_dep_gates(svc, services);

        if !deps.is_empty() || exec.stop.is_some() || exec.post_stop.is_some() {
            let spec = build_supervise_spec(svc, exec, config, &deps);
            out.push(Artifact {
                kind: "supervise-spec".into(),
                label: label.clone(),
                path: supervise_spec_path(config, &label),
                content: serde_json::to_string_pretty(&spec).unwrap_or_default(),
            });
        }

        out.push(Artifact {
            kind: "plist".into(),
            label: label.clone(),
            path: units_dir.join(plist_filename(config, &svc.name)).display().to_string(),
            content: generate_service_plist_with_deps(svc, exec, config, &deps),
        });
    }
    out
}

fn render_systemd(services: &[Service], exec_sets: &[(usize, ExecSet)], config: &Config) -> Vec<Artifact> {
    use crate::platform::systemd::generate::{
        generate_ready_gate, generate_service_unit, generate_target, services_needing_ready_gates,
    };
    let units_dir = config.units_dir();
    let gates = services_needing_ready_gates(services);
    let mut out = Vec::new();

    for (idx, exec) in exec_sets {
        let svc = &services[*idx];
        out.push(Artifact {
            kind: "unit".into(),
            label: config.unit_name(&svc.name),
            path: units_dir.join(config.unit_name(&svc.name)).display().to_string(),
            content: generate_service_unit(svc, exec, config, &gates),
        });
    }
    for svc in services {
        if gates.contains(&svc.name) {
            let name = format!("{}-{}-ready.service", config.namespace, svc.name);
            out.push(Artifact {
                kind: "ready-gate".into(),
                label: name.clone(),
                path: units_dir.join(&name).display().to_string(),
                content: generate_ready_gate(svc, config),
            });
        }
    }
    out.push(Artifact {
        kind: "target".into(),
        label: config.target_name(),
        path: units_dir.join(config.target_name()).display().to_string(),
        content: generate_target(config),
    });
    out
}

// ----- tend: Artifacts -> running ------------------------------------------

/// Activation. Writes each artifact to its path, then installs and (optionally)
/// starts via the platform's init system. The only side-effecting row.
pub fn tend(config: &Config, start: bool) -> Result<(), OrchardError> {
    let input = read_stdin()?;
    let arts: Artifacts = serde_json::from_str(&input)?;

    for a in &arts.artifacts {
        let path = std::path::PathBuf::from(&a.path);
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        std::fs::write(&path, &a.content)?;
        if !config.quiet {
            eprintln!("  wrote: {}", a.path);
        }
    }

    // Install + start reuse the proven platform lifecycle.
    match arts.platform.as_str() {
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
    fn test_render_systemd__units_and_target() {
        let cfg = test_config("systemd");
        let svcs = vec![host_service("web", "/usr/bin/web")];
        let es = vec![(0usize, exec("/usr/bin/web"))];
        let arts = render_systemd(&svcs, &es, &cfg);

        let kinds: Vec<&str> = arts.iter().map(|a| a.kind.as_str()).collect();
        assert!(kinds.contains(&"unit"));
        assert!(kinds.contains(&"target"));
        let unit = arts.iter().find(|a| a.kind == "unit").unwrap();
        assert_eq!(unit.label, "orch-web.service");
        assert!(unit.content.contains("ExecStart=/bin/bash -c '/usr/bin/web'"));
    }

    #[test]
    fn test_render_launchd__container_emits_plist_and_spec() {
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
        let arts = render_launchd(&svcs, &es, &cfg);

        let kinds: Vec<&str> = arts.iter().map(|a| a.kind.as_str()).collect();
        assert!(kinds.contains(&"plist"));
        assert!(kinds.contains(&"supervise-spec")); // teardown -> needs supervisor
        let plist = arts.iter().find(|a| a.kind == "plist").unwrap();
        assert!(plist.content.contains("<string>supervise</string>"));
    }

    #[test]
    fn test_contracts_roundtrip() {
        let sown = Sown {
            version: "0.2.1".into(),
            runtime: "apple".into(),
            trees: vec![Tree { service: host_service("a", "x"), exec: exec("x") }],
        };
        let back: Sown = serde_json::from_str(&serde_json::to_string(&sown).unwrap()).unwrap();
        assert_eq!(back.trees.len(), 1);

        let arts = Artifacts {
            platform: "launchd".into(),
            namespace: "orch".into(),
            scope: "user".into(),
            artifacts: vec![Artifact {
                kind: "plist".into(),
                label: "orch.a".into(),
                path: "/x".into(),
                content: "y".into(),
            }],
        };
        let back: Artifacts = serde_json::from_str(&serde_json::to_string(&arts).unwrap()).unwrap();
        assert_eq!(back.artifacts[0].kind, "plist");
    }
}
