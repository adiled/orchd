# 02 - Runtime Interface

## Overview

A runtime translates container-mode services (`FROM`) into executable commands. Host-mode services (`RUN`) bypass the runtime entirely -- the engine uses `run_command` directly.

The runtime never interacts with the platform. It produces an `ExecSet` which the engine passes to the platform.

## The Runtime Trait

```rust
pub trait Runtime {
    /// Human-readable name for this runtime (e.g., "bare", "containerd")
    fn name(&self) -> &str;

    /// Check if this runtime's prerequisites are met.
    /// Called before any other method.
    /// Returns Err with a descriptive message if the runtime cannot operate.
    fn check(&self) -> Result<()>;

    /// Prepare a container-mode service for execution.
    /// For container runtimes: pull image, create container, create volumes.
    /// For bare runtime: create data directories, validate host software.
    /// No-op for host-mode services (engine skips this call).
    fn prepare(&self, service: &Service, config: &Config) -> Result<()>;

    /// Return the main executable command for a container-mode service.
    /// For bare: this is the run_command (from overlay-rewritten service).
    /// For containerd: "nerdctl start --attach <name>"
    /// For apple: "container start --attach <name>"
    /// No-op for host-mode services (engine uses run_command directly).
    fn exec_command(&self, service: &Service, config: &Config) -> Result<String>;

    /// Optional: return a command to run before the main process starts.
    /// For container runtimes: create the container.
    /// Default: None.
    fn pre_start(&self, service: &Service, config: &Config) -> Result<Option<String>> {
        Ok(None)
    }

    /// Optional: return a command to stop the service gracefully.
    /// For container runtimes: stop the container.
    /// Default: None (platform sends SIGTERM to the main process).
    fn stop_command(&self, service: &Service, config: &Config) -> Result<Option<String>> {
        Ok(None)
    }

    /// Optional: return a command to run after the main process exits.
    /// For container runtimes with recreate=always: remove the container.
    /// Default: None.
    fn post_stop(&self, service: &Service, config: &Config) -> Result<Option<String>> {
        Ok(None)
    }

    /// Clean up all resources for a service.
    /// For container runtimes: stop and remove containers, optionally remove volumes.
    /// For bare: remove created directories (if any).
    fn cleanup(&self, service_name: &str, config: &Config) -> Result<()>;
}
```

## Method Call Sequence

The engine calls runtime methods in this order:

```
1. runtime.check()                     # once at startup
2. for each container-mode service:
   a. runtime.prepare(service)         # create resources
   b. runtime.exec_command(service)    # --> ExecSet.start
   c. runtime.pre_start(service)       # --> ExecSet.pre_start
   d. runtime.stop_command(service)    # --> ExecSet.stop
   e. runtime.post_stop(service)       # --> ExecSet.post_stop
3. ExecSet passed to platform.generate()
```

For cleanup (e.g., `orchd clean`):

```
1. for each container-mode service:
   a. runtime.cleanup(service_name)
```

## ExecSet Assembly

The engine assembles runtime output into an `ExecSet`:

```rust
fn build_exec_set(
    service: &Service,
    runtime: &dyn Runtime,
    config: &Config,
) -> Result<ExecSet> {
    match service.mode {
        ServiceMode::Host => {
            // Host-mode: command comes from Orchfile directly
            Ok(ExecSet {
                start: service.run_command.clone()
                    .ok_or_else(|| anyhow!("host service {} has no run_command", service.name))?,
                ..Default::default()
            })
        }
        ServiceMode::Container => {
            // Container-mode: runtime provides all commands
            Ok(ExecSet {
                start: runtime.exec_command(service, config)?,
                pre_start: runtime.pre_start(service, config)?,
                stop: runtime.stop_command(service, config)?,
                post_stop: runtime.post_stop(service, config)?,
            })
        }
    }
}
```

## Implementing a Runtime

To add a new runtime, implement the `Runtime` trait:

```rust
pub struct ContainerdRuntime;

impl Runtime for ContainerdRuntime {
    fn name(&self) -> &str { "containerd" }

    fn check(&self) -> Result<()> {
        // Verify nerdctl/ctr is installed and containerd is running
        Command::new("nerdctl").arg("version").output()?;
        Ok(())
    }

    fn prepare(&self, service: &Service, config: &Config) -> Result<()> {
        // Pull image, create named volumes
        let image = service.image.as_ref().unwrap();
        Command::new("nerdctl").args(["pull", image]).status()?;
        // ... create volumes, network
        Ok(())
    }

    fn exec_command(&self, service: &Service, config: &Config) -> Result<String> {
        let container_name = format!("{}-{}", config.prefix, service.name);
        Ok(format!("nerdctl start --attach {}", container_name))
    }

    fn pre_start(&self, service: &Service, config: &Config) -> Result<Option<String>> {
        // Build the nerdctl create command with ports, volumes, env
        let container_name = format!("{}-{}", config.prefix, service.name);
        let image = service.image.as_ref().unwrap();
        let mut cmd = format!("nerdctl create --name {}", container_name);
        // ... add ports, volumes, env, resources
        cmd.push_str(&format!(" {}", image));
        Ok(Some(cmd))
    }

    fn stop_command(&self, service: &Service, config: &Config) -> Result<Option<String>> {
        let container_name = format!("{}-{}", config.prefix, service.name);
        Ok(Some(format!("nerdctl stop {}", container_name)))
    }

    fn post_stop(&self, service: &Service, config: &Config) -> Result<Option<String>> {
        match service.recreate {
            RecreatePolicy::Always => {
                let container_name = format!("{}-{}", config.prefix, service.name);
                Ok(Some(format!("nerdctl rm {}", container_name)))
            }
            RecreatePolicy::Never => Ok(None),
        }
    }

    fn cleanup(&self, service_name: &str, config: &Config) -> Result<()> {
        let container_name = format!("{}-{}", config.prefix, service_name);
        Command::new("nerdctl").args(["rm", "--force", &container_name]).status()?;
        Ok(())
    }
}
```

## Planned Runtimes

| Runtime | Status | Description |
|---------|--------|-------------|
| **bare** | Phase 4 | No containers. FROM services require Orchfile overlay to RUN. |
| **containerd** | Future | Linux containers via nerdctl/ctr. |
| **podman** | Future | OCI containers via podman. |
| **apple** | Future | Apple container runtime (macOS/Apple Silicon). |

See [05-bare-runtime.md](05-bare-runtime.md) for the bare runtime specification.
