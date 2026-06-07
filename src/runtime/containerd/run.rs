//! containerd_run: orchd's in-process containerd client.
//!
//! `orchd containerd-run --spec <base64>` is the foreground process the
//! supervisor tracks for a containerd-backed service. It pulls the image (via
//! containerd's Transfer service), prepares a writable snapshot, creates and
//! starts the container task over containerd's gRPC socket, waits for it to
//! exit, and on SIGTERM kills + deletes it.
//!
//! The container runs in the HOST network namespace (the OCI spec omits a new
//! network namespace), so there is no CNI/iptables dependency.
//!
//! The gRPC backend (tonic + containerd-client) lives behind the `containerd`
//! cargo feature, so the default orchd build stays lean and needs no protoc.
//! The spec-building half (used by the runtime's exec_set) is always compiled.

use serde::{Deserialize, Serialize};

/// Everything `containerd-run` needs to pull and run one container. Built by the
/// containerd runtime's exec_set, consumed here.
#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct ContainerdRunSpec {
    /// containerd gRPC unix socket (e.g. /run/containerd/containerd.sock).
    pub socket: String,
    /// containerd namespace (e.g. "default").
    pub namespace: String,
    /// Image reference to pull/run.
    pub image: String,
    /// Container id in containerd (e.g. "orch-web").
    pub container_id: String,
    /// argv. Empty -> use the image config's Entrypoint ++ Cmd.
    #[serde(default)]
    pub args: Vec<String>,
    /// "KEY=VALUE" entries, merged after the image env.
    #[serde(default)]
    pub env: Vec<String>,
    /// Working directory. Empty -> the image config's WorkingDir (or "/").
    #[serde(default)]
    pub cwd: String,
    /// uid[:gid] (numeric). None -> the image config's User (or root).
    #[serde(default)]
    pub user: Option<String>,
    /// Env files (paths) read and merged after the image env, before `env`.
    #[serde(default)]
    pub env_files: Vec<String>,
    /// Host directories bind-mounted into the container.
    #[serde(default)]
    pub volumes: Vec<VolumeMount>,
    /// cgroup / rlimit caps applied to the container (from resources.*).
    #[serde(default)]
    pub resources: Resources,
}

/// A host path bind-mounted into the container.
#[derive(Serialize, Deserialize, Debug, Clone, Default)]
pub struct VolumeMount {
    pub source: String,
    pub destination: String,
}

/// Resolved resource caps. 0/None means "unset". Memory in bytes, cpu as a
/// cgroup v2 cpu.max (quota,period) in microseconds.
#[derive(Serialize, Deserialize, Debug, Clone, Default)]
pub struct Resources {
    pub memory_bytes: Option<u64>,
    pub cpu_quota_us: Option<u64>,
    pub cpu_period_us: Option<u64>,
    pub pids_max: Option<u64>,
    pub nofile: Option<u64>,
    pub nproc: Option<u64>,
    pub io_weight: Option<u32>,
}

/// Encode a spec as a shell-safe base64 arg for the ExecSet start command.
pub fn encode_spec(spec: &ContainerdRunSpec) -> String {
    use base64::Engine;
    let json = serde_json::to_vec(spec).expect("ContainerdRunSpec serializes");
    base64::engine::general_purpose::STANDARD.encode(json)
}

fn decode_spec(b64: &str) -> Result<ContainerdRunSpec, String> {
    use base64::Engine;
    let json = base64::engine::general_purpose::STANDARD
        .decode(b64.trim())
        .map_err(|e| format!("base64: {e}"))?;
    serde_json::from_slice(&json).map_err(|e| format!("json: {e}"))
}

/// Decode the base64 spec and run the container to completion. Returns the
/// container's exit code (or a non-zero orchd error code).
pub fn run(spec_b64: &str) -> i32 {
    let spec = match decode_spec(spec_b64) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("containerd-run: bad --spec: {e}");
            return 1;
        }
    };

    #[cfg(feature = "containerd")]
    {
        match backend::run(spec) {
            Ok(code) => code,
            Err(e) => {
                eprintln!("containerd-run: {e:#}");
                1
            }
        }
    }
    #[cfg(not(feature = "containerd"))]
    {
        let _ = spec;
        eprintln!("containerd-run: this orchd was built without the 'containerd' feature");
        1
    }
}

#[cfg(feature = "containerd")]
mod backend {
    use super::{ContainerdRunSpec, Resources, VolumeMount};
    use std::collections::HashMap;
    use std::env::consts;

    use anyhow::{anyhow, Context, Result};
    use containerd_client::{
        services::v1::{
            container::Runtime,
            snapshots::{PrepareSnapshotRequest, RemoveSnapshotRequest},
            Container, CreateContainerRequest, CreateTaskRequest, DeleteContainerRequest,
            DeleteTaskRequest, GetImageRequest, KillRequest, ReadContentRequest, StartRequest,
            TransferOptions, TransferRequest, WaitRequest,
        },
        to_any,
        types::{
            transfer::{ImageStore, OciRegistry, UnpackConfiguration},
            Platform,
        },
        with_namespace, Client,
    };
    use sha2::{Digest, Sha256};
    use tokio::signal::unix::{signal, SignalKind};
    use tonic::Request;

    const SIGTERM: u32 = 15;
    const SIGKILL: u32 = 9;
    const SNAPSHOTTER: &str = "overlayfs";

    /// containerd's GOARCH string for this host.
    fn goarch() -> &'static str {
        match consts::ARCH {
            "x86_64" => "amd64",
            "aarch64" => "arm64",
            other => other,
        }
    }

    /// Process defaults read from the image config.
    #[derive(Default)]
    struct ImageConfig {
        entrypoint: Vec<String>,
        cmd: Vec<String>,
        env: Vec<String>,
        working_dir: String,
        user: String,
    }

    pub fn run(spec: ContainerdRunSpec) -> Result<i32> {
        let rt = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
            .context("build tokio runtime")?;
        rt.block_on(run_async(spec))
    }

    async fn run_async(spec: ContainerdRunSpec) -> Result<i32> {
        let ns = &spec.namespace;
        let id = &spec.container_id;
        let client = Client::from_path(&spec.socket)
            .await
            .with_context(|| format!("connect to containerd at {}", spec.socket))?;

        // Idempotent: clear any leftover container/task/snapshot from a prior run.
        teardown(&client, ns, id).await;

        // Pull (Transfer service also unpacks into the snapshotter).
        pull(&client, ns, &spec.image).await?;

        // Resolve the rootfs chainID + the image's process defaults.
        let (diff_ids, cfg) = read_image(&client, ns, &spec.image).await?;
        let chain = chain_id(&diff_ids);
        let mut snapshots = client.snapshots();
        let mounts = snapshots
            .prepare(with_namespace!(
                PrepareSnapshotRequest {
                    snapshotter: SNAPSHOTTER.to_string(),
                    key: id.to_string(),
                    parent: chain,
                    labels: HashMap::new(),
                },
                ns
            ))
            .await
            .context("snapshots.prepare")?
            .into_inner()
            .mounts;

        // Layer the service spec over the image defaults.
        let argv = if !spec.args.is_empty() {
            spec.args.clone()
        } else {
            let mut a = cfg.entrypoint.clone();
            a.extend(cfg.cmd.clone());
            a
        };
        if argv.is_empty() {
            return Err(anyhow!(
                "no argv: image has no entrypoint/cmd and none was provided"
            ));
        }
        let mut env = cfg.env.clone();
        for f in &spec.env_files {
            if let Ok(data) = std::fs::read_to_string(f) {
                for line in data.lines() {
                    let t = line.trim();
                    if t.is_empty() || t.starts_with('#') || !t.contains('=') {
                        continue;
                    }
                    env.push(t.to_string());
                }
            }
        }
        env.extend(spec.env.clone());
        let cwd = if !spec.cwd.is_empty() {
            spec.cwd.clone()
        } else if !cfg.working_dir.is_empty() {
            cfg.working_dir.clone()
        } else {
            "/".to_string()
        };
        let user = spec.user.as_deref().or(if cfg.user.is_empty() {
            None
        } else {
            Some(cfg.user.as_str())
        });
        // Only numeric uid[:gid] is resolved here; a username would need the
        // image's /etc/passwd. Surface that rather than silently running as root.
        if let Some(u) = user {
            let uid_part = u.split(':').next().unwrap_or(u);
            if !uid_part.is_empty() && uid_part.parse::<u32>().is_err() {
                eprintln!(
                    "containerd-run: USER '{u}' is a name; running as root (numeric uid[:gid] only)"
                );
            }
        }
        let (uid, gid) = parse_user(user);

        let spec_json = oci_spec_json(id, &argv, &env, &cwd, uid, gid, &spec.resources, &spec.volumes);

        // Create the container record, referencing the snapshot.
        client
            .containers()
            .create(with_namespace!(
                CreateContainerRequest {
                    container: Some(Container {
                        id: id.to_string(),
                        image: spec.image.clone(),
                        runtime: Some(Runtime {
                            name: "io.containerd.runc.v2".to_string(),
                            // no_pivot_root=true: orchd-osx boots the VM as an
                            // initramfs (ramfs root) where runc's pivot_root
                            // fails (EINVAL); this makes runc use MS_MOVE+chroot
                            // instead. Harmless on a normal disk-rooted host.
                            // Any of containerd.runc.v1.Options{ no_pivot_root:
                            // true } = field 1, varint true = bytes 08 01.
                            options: Some(prost_types::Any {
                                type_url: "containerd.runc.v1.Options".to_string(),
                                value: vec![0x08, 0x01],
                            }),
                        }),
                        spec: Some(prost_types::Any {
                            type_url:
                                "types.containerd.io/opencontainers/runtime-spec/1/Spec"
                                    .to_string(),
                            value: spec_json.into_bytes(),
                        }),
                        snapshotter: SNAPSHOTTER.to_string(),
                        snapshot_key: id.to_string(),
                        ..Default::default()
                    })
                },
                ns
            ))
            .await
            .context("containers.create")?;

        // Create + start the task with the snapshot mounts as its rootfs.
        let mut tasks = client.tasks();
        tasks
            .create(with_namespace!(
                CreateTaskRequest {
                    container_id: id.to_string(),
                    rootfs: mounts,
                    ..Default::default()
                },
                ns
            ))
            .await
            .context("tasks.create")?;
        tasks
            .start(with_namespace!(
                StartRequest {
                    container_id: id.to_string(),
                    ..Default::default()
                },
                ns
            ))
            .await
            .context("tasks.start")?;
        eprintln!("containerd-run: started {id} ({})", spec.image);

        // Wait for the task to exit, OR for the supervisor to SIGTERM us.
        let mut sigterm = signal(SignalKind::terminate()).context("install SIGTERM handler")?;
        let mut sigint = signal(SignalKind::interrupt()).context("install SIGINT handler")?;
        let mut waiter = client.tasks();
        let code = tokio::select! {
            w = waiter.wait(with_namespace!(
                WaitRequest { container_id: id.to_string(), ..Default::default() }, ns)) => {
                match w {
                    Ok(r) => r.into_inner().exit_status as i32,
                    Err(e) => { eprintln!("containerd-run: wait: {e}"); 1 }
                }
            }
            _ = sigterm.recv() => { eprintln!("containerd-run: SIGTERM, stopping {id}"); 143 }
            _ = sigint.recv()  => { eprintln!("containerd-run: SIGINT, stopping {id}"); 130 }
        };

        // Always tear the container down on the way out.
        teardown(&client, ns, id).await;
        Ok(code)
    }

    /// Pull `image` via the Transfer service, unpacking into the snapshotter.
    async fn pull(client: &Client, ns: &str, image: &str) -> Result<()> {
        let platform = Platform {
            os: "linux".to_string(),
            architecture: goarch().to_string(),
            variant: String::new(),
            os_version: String::new(),
        };
        let source = OciRegistry {
            reference: image.to_string(),
            resolver: Default::default(),
        };
        let destination = ImageStore {
            name: image.to_string(),
            platforms: vec![platform.clone()],
            unpacks: vec![UnpackConfiguration {
                platform: Some(platform),
                snapshotter: SNAPSHOTTER.to_string(),
            }],
            ..Default::default()
        };
        client
            .transfer()
            .transfer(with_namespace!(
                TransferRequest {
                    source: Some(to_any(&source)),
                    destination: Some(to_any(&destination)),
                    options: Some(TransferOptions::default()),
                },
                ns
            ))
            .await
            .context("transfer (pull) image")?;
        Ok(())
    }

    /// Read a content blob (full) by digest.
    async fn read_content(client: &Client, ns: &str, digest: &str) -> Result<Vec<u8>> {
        let mut stream = client
            .content()
            .read(with_namespace!(
                ReadContentRequest {
                    digest: digest.to_string(),
                    offset: 0,
                    size: 0,
                },
                ns
            ))
            .await
            .with_context(|| format!("content.read {digest}"))?
            .into_inner();
        let mut buf = Vec::new();
        while let Some(chunk) = stream.message().await.context("read content chunk")? {
            buf.extend_from_slice(&chunk.data);
        }
        Ok(buf)
    }

    /// Resolve the image's rootfs diff_ids and process config (descending an
    /// index by platform if present).
    async fn read_image(
        client: &Client,
        ns: &str,
        image: &str,
    ) -> Result<(Vec<String>, ImageConfig)> {
        let target = client
            .images()
            .get(with_namespace!(
                GetImageRequest { name: image.to_string() },
                ns
            ))
            .await
            .context("images.get")?
            .into_inner()
            .image
            .and_then(|i| i.target)
            .ok_or_else(|| anyhow!("image has no target descriptor"))?;

        let blob = read_content(client, ns, &target.digest).await?;
        let json: serde_json::Value =
            serde_json::from_slice(&blob).context("parse manifest/index json")?;

        let manifest = if json.get("manifests").is_some() {
            let arch = goarch();
            let manifests = json["manifests"].as_array().cloned().unwrap_or_default();
            let chosen = manifests
                .iter()
                .find(|m| m["platform"]["os"] == "linux" && m["platform"]["architecture"] == arch)
                .or_else(|| manifests.first())
                .ok_or_else(|| anyhow!("no manifest in index"))?;
            let mdigest = chosen["digest"]
                .as_str()
                .ok_or_else(|| anyhow!("manifest entry missing digest"))?;
            let mblob = read_content(client, ns, mdigest).await?;
            serde_json::from_slice::<serde_json::Value>(&mblob).context("parse manifest json")?
        } else {
            json
        };

        let config_digest = manifest["config"]["digest"]
            .as_str()
            .ok_or_else(|| anyhow!("manifest missing config.digest"))?;
        let config: serde_json::Value =
            serde_json::from_slice(&read_content(client, ns, config_digest).await?)
                .context("parse image config json")?;

        let diff_ids = config["rootfs"]["diff_ids"]
            .as_array()
            .ok_or_else(|| anyhow!("config missing rootfs.diff_ids"))?
            .iter()
            .filter_map(|v| v.as_str().map(String::from))
            .collect::<Vec<_>>();
        if diff_ids.is_empty() {
            return Err(anyhow!("empty diff_ids"));
        }

        let str_list = |v: &serde_json::Value| -> Vec<String> {
            v.as_array()
                .map(|a| {
                    a.iter()
                        .filter_map(|x| x.as_str().map(String::from))
                        .collect()
                })
                .unwrap_or_default()
        };
        let cfg = ImageConfig {
            entrypoint: str_list(&config["config"]["Entrypoint"]),
            cmd: str_list(&config["config"]["Cmd"]),
            env: str_list(&config["config"]["Env"]),
            working_dir: config["config"]["WorkingDir"]
                .as_str()
                .unwrap_or("")
                .to_string(),
            user: config["config"]["User"].as_str().unwrap_or("").to_string(),
        };
        Ok((diff_ids, cfg))
    }

    /// Fold diff_ids into the rootfs chainID (containerd identity.ChainID).
    fn chain_id(diff_ids: &[String]) -> String {
        let mut chain = diff_ids[0].clone();
        for next in &diff_ids[1..] {
            let mut h = Sha256::new();
            h.update(format!("{chain} {next}").as_bytes());
            chain = format!("sha256:{}", hex::encode(h.finalize()));
        }
        chain
    }

    /// Parse a numeric uid[:gid] (names are not resolvable here -> root).
    fn parse_user(user: Option<&str>) -> (u32, u32) {
        let Some(u) = user.map(str::trim).filter(|s| !s.is_empty()) else {
            return (0, 0);
        };
        let (uid_s, gid_s) = match u.split_once(':') {
            Some((a, b)) => (a, Some(b)),
            None => (u, None),
        };
        let uid = uid_s.parse::<u32>().unwrap_or(0);
        let gid = gid_s.and_then(|g| g.parse::<u32>().ok()).unwrap_or(uid);
        (uid, gid)
    }

    /// OCI runtime spec JSON. Namespaces omit "network" => host netns, no CNI.
    /// rlimits, cgroup resources, and bind mounts come from the spec.
    fn oci_spec_json(
        id: &str,
        argv: &[String],
        env: &[String],
        cwd: &str,
        uid: u32,
        gid: u32,
        res: &Resources,
        vols: &[VolumeMount],
    ) -> String {
        // rlimits: nofile (from spec or default 1024) + optional nproc.
        let nofile = res.nofile.unwrap_or(1024);
        let mut rlimits = vec![serde_json::json!(
            { "type": "RLIMIT_NOFILE", "hard": nofile, "soft": nofile }
        )];
        if let Some(n) = res.nproc {
            rlimits.push(serde_json::json!({ "type": "RLIMIT_NPROC", "hard": n, "soft": n }));
        }

        // mounts: the standard set, plus a rw bind mount per volume.
        let mut mounts = vec![
            serde_json::json!({ "destination": "/proc", "type": "proc", "source": "proc" }),
            serde_json::json!({ "destination": "/dev", "type": "tmpfs", "source": "tmpfs",
                "options": ["nosuid","strictatime","mode=755","size=65536k"] }),
            serde_json::json!({ "destination": "/dev/pts", "type": "devpts", "source": "devpts",
                "options": ["nosuid","noexec","newinstance","ptmxmode=0666","mode=0620","gid=5"] }),
            serde_json::json!({ "destination": "/dev/shm", "type": "tmpfs", "source": "shm",
                "options": ["nosuid","noexec","nodev","mode=1777","size=65536k"] }),
            serde_json::json!({ "destination": "/dev/mqueue", "type": "mqueue", "source": "mqueue",
                "options": ["nosuid","noexec","nodev"] }),
            serde_json::json!({ "destination": "/sys", "type": "sysfs", "source": "sysfs",
                "options": ["nosuid","noexec","nodev","ro"] }),
            serde_json::json!({ "destination": "/etc/resolv.conf", "type": "bind", "source": "/etc/resolv.conf",
                "options": ["rbind","ro"] }),
        ];
        for v in vols {
            mounts.push(serde_json::json!({
                "destination": v.destination, "type": "bind", "source": v.source,
                "options": ["rbind","rw"]
            }));
        }

        // cgroup v2 resource caps.
        let mut resources = serde_json::Map::new();
        if let Some(m) = res.memory_bytes {
            resources.insert("memory".into(), serde_json::json!({ "limit": m }));
        }
        if let Some(q) = res.cpu_quota_us {
            let period = res.cpu_period_us.unwrap_or(100000);
            resources.insert("cpu".into(), serde_json::json!({ "quota": q, "period": period }));
        }
        if let Some(p) = res.pids_max {
            resources.insert("pids".into(), serde_json::json!({ "limit": p }));
        }
        if let Some(w) = res.io_weight {
            resources.insert("blockIO".into(), serde_json::json!({ "weight": w }));
        }

        let mut linux = serde_json::json!({
            "namespaces": [
                { "type": "pid" }, { "type": "ipc" }, { "type": "uts" }, { "type": "mount" }
            ],
            "maskedPaths": [
                "/proc/kcore","/proc/latency_stats","/proc/timer_list",
                "/proc/timer_stats","/proc/sched_debug","/sys/firmware"
            ],
            "readonlyPaths": [
                "/proc/asound","/proc/bus","/proc/fs","/proc/irq",
                "/proc/sys","/proc/sysrq-trigger"
            ]
        });
        if !resources.is_empty() {
            linux["resources"] = serde_json::Value::Object(resources);
        }

        serde_json::json!({
            "ociVersion": "1.1.0",
            "process": {
                "terminal": false,
                "user": { "uid": uid, "gid": gid },
                "args": argv,
                "env": env,
                "cwd": if cwd.is_empty() { "/" } else { cwd },
                "capabilities": {
                    "bounding":  ["CAP_NET_RAW","CAP_CHOWN","CAP_DAC_OVERRIDE","CAP_SETUID","CAP_SETGID","CAP_NET_BIND_SERVICE"],
                    "effective": ["CAP_NET_RAW","CAP_CHOWN","CAP_DAC_OVERRIDE","CAP_SETUID","CAP_SETGID","CAP_NET_BIND_SERVICE"],
                    "permitted": ["CAP_NET_RAW","CAP_CHOWN","CAP_DAC_OVERRIDE","CAP_SETUID","CAP_SETGID","CAP_NET_BIND_SERVICE"]
                },
                "rlimits": rlimits,
                "noNewPrivileges": true
            },
            "root": { "path": "rootfs", "readonly": false },
            "hostname": id,
            "mounts": mounts,
            "linux": linux
        })
        .to_string()
    }

    /// Best-effort, idempotent cleanup, safe to call before and after a run.
    /// The container task runs under containerd's shim (not our process group),
    /// so we must stop it via the API AND wait for it to actually exit before
    /// deleting the task/container/snapshot — otherwise the live task leaks.
    async fn teardown(client: &Client, ns: &str, id: &str) {
        let mut tasks = client.tasks();

        // Ask the task to stop. kill succeeds only if a running task exists.
        let had_task = tasks
            .kill(with_namespace!(
                KillRequest {
                    container_id: id.to_string(),
                    exec_id: String::new(),
                    signal: SIGTERM,
                    all: true,
                },
                ns
            ))
            .await
            .is_ok();

        if had_task {
            // Wait for it to actually exit; SIGKILL if it overruns the grace.
            let graceful = tokio::time::timeout(
                std::time::Duration::from_secs(8),
                tasks.wait(with_namespace!(
                    WaitRequest { container_id: id.to_string(), ..Default::default() },
                    ns
                )),
            )
            .await;
            if graceful.is_err() {
                let _ = tasks
                    .kill(with_namespace!(
                        KillRequest {
                            container_id: id.to_string(),
                            exec_id: String::new(),
                            signal: SIGKILL,
                            all: true,
                        },
                        ns
                    ))
                    .await;
                let _ = tokio::time::timeout(
                    std::time::Duration::from_secs(3),
                    tasks.wait(with_namespace!(
                        WaitRequest { container_id: id.to_string(), ..Default::default() },
                        ns
                    )),
                )
                .await;
            }
        }

        // Task is dead (or never existed): now safe to delete records.
        let _ = tasks
            .delete(with_namespace!(
                DeleteTaskRequest { container_id: id.to_string() },
                ns
            ))
            .await;
        let _ = client
            .containers()
            .delete(with_namespace!(
                DeleteContainerRequest { id: id.to_string() },
                ns
            ))
            .await;
        let _ = client
            .snapshots()
            .remove(with_namespace!(
                RemoveSnapshotRequest {
                    snapshotter: SNAPSHOTTER.to_string(),
                    key: id.to_string(),
                },
                ns
            ))
            .await;
    }
}
