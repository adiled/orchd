# 05 - Bare Runtime

## Overview

The bare runtime runs all services as host processes -- no container layer. Services defined with `FROM` in the Orchfile are converted to host-mode via Orchfile overlays before orchd processes them.

This is the default runtime and the first one implemented. It is designed for environments where containers are impractical (LXC, lightweight VMs) or unnecessary (all software installed natively).

## The Overlay Approach

The bare runtime relies on orch's multi-file merge system to convert container-mode services to host-mode:

### Base Orchfile (project-owned)

```
SERVICE postgres
FROM pgvector/pgvector:pg15
PUBLISH 5433:5432
VOLUME app-pgdata:/var/lib/postgresql/data
ENV POSTGRES_USER=postgres
CMD postgres -c config_file=/var/lib/postgresql/config/postgresql.dev.conf
HEALTHCHECK pg_isready -h localhost -p 5433
RESTART on-failure
RESTART_DELAY 5s
MEMORY 4G
```

### Bare Overlay (environment-specific)

```
SERVICE postgres
RUN postgres -c config_file=${ORCH_DATA}/postgres/config/postgresql.dev.conf -p ${postgres_port}
ENV PGDATA=${ORCH_DATA}/postgres/data/pgdata
USER postgres
```

### Merge Result

When parsed with `orch parse Orchfile bare.orch`:

1. `RUN` replaces `FROM` -- mode switches to host
2. Mode switch auto-clears container-only directives: `PUBLISH`, `VOLUME`, `CMD`, `ENTRYPOINT`
3. `ENV` merges: overlay's `PGDATA` added, base's `POSTGRES_USER` preserved
4. Everything else preserved: `HEALTHCHECK`, `RESTART`, `RESTART_DELAY`, `MEMORY`

Result: a valid host-mode service with the correct command, ports, paths, and all orchestration metadata intact.

## Why Overlays, Not Runtime Translation

An alternative design would have the bare runtime automatically translate container semantics (port mappings, volume mounts, CMD) into host equivalents at generation time. We chose overlays because:

1. **Explicit over implicit** -- the overlay makes it clear what command runs, what paths are used. No guessing.
2. **Stays within the spec** -- orch validates the merged result. The runtime doesn't need to bend constraints.
3. **Service-specific knowledge** -- a postgres container listens on port 5432 internally but the host binary might need `-p 5433` explicitly. Only the overlay author knows the right invocation.
4. **Composability** -- different bare overlays for different environments (LXC vs desktop vs CI).

## Runtime Implementation

```rust
pub struct BareRuntime;

impl Runtime for BareRuntime {
    fn name(&self) -> &str { "bare" }

    fn check(&self) -> Result<()> {
        // Verify orch binary is available (needed for overlay parsing)
        which::which("orch")
            .map_err(|_| anyhow!("orch binary not found in PATH"))?;
        Ok(())
    }

    fn prepare(&self, service: &Service, config: &Config) -> Result<()> {
        // Bare runtime only handles container-mode services that
        // survived without overlay (which is an error).
        // For host-mode services: create data directories if referenced.
        ensure_data_dirs(service, config)?;
        Ok(())
    }

    fn exec_command(&self, service: &Service, config: &Config) -> Result<String> {
        match service.mode {
            ServiceMode::Host => {
                // Should not be called for host services (engine handles directly)
                unreachable!("engine handles host-mode exec_command")
            }
            ServiceMode::Container => {
                // Container service without overlay = error
                Err(anyhow!(
                    "service '{}' is container-mode (FROM {}) but bare runtime \
                     has no container support. Create an overlay that redefines \
                     it with RUN, or use a container runtime.",
                    service.name,
                    service.image.as_deref().unwrap_or("unknown")
                ))
            }
        }
    }

    fn cleanup(&self, _service_name: &str, _config: &Config) -> Result<()> {
        // Nothing to clean up in bare mode
        Ok(())
    }
}
```

## Data Directory Preparation

The `prepare()` method creates directories that services expect to exist:

```rust
fn ensure_data_dirs(service: &Service, config: &Config) -> Result<()> {
    // Scan env values and run_command for ${ORCH_DATA} references
    // Create any directories under the data dir that don't exist
    let data_dir = &config.orch_data_dir;
    std::fs::create_dir_all(data_dir)?;

    // Create service-specific data directory
    let service_data = data_dir.join(&service.name);
    std::fs::create_dir_all(&service_data)?;

    Ok(())
}
```

## Bare Overlay Patterns

### Database services

```
SERVICE postgres
RUN postgres -c config_file=${ORCH_DATA}/postgres/config/postgresql.dev.conf -p ${postgres_port}
ENV PGDATA=${ORCH_DATA}/postgres/data/pgdata
USER postgres
```

Key translations from container to bare:
- Image ignored
- Port: process binds directly to `${postgres_port}` (no mapping)
- Data: `${ORCH_DATA}/postgres/data/` instead of named volume
- Config: `${ORCH_DATA}/postgres/config/` instead of container mount
- User: explicit (containers run as container's default user)

### Cache services

```
SERVICE redis
RUN redis-server --port ${redis_port} --dir ${ORCH_DATA}/redis
```

Simple translation: just the command with host port and data dir.

### Reverse proxies

```
SERVICE nginx
RUN nginx -c ${ORCH_DATA}/nginx/nginx.conf -g 'daemon off;'
```

Config file must be adapted for host networking (no container DNS, no gateway IP).

### Services that are hard to run bare

Some container services (e.g., LocalStack) have complex dependencies that make bare execution impractical. The overlay can either:

1. Provide a simplified bare command (if possible)
2. Mark the service as `DISABLED true` in the overlay
3. Be omitted from the overlay (orchd will error, prompting action)

## Bare Runtime Validation

During `orchd generate`, the bare runtime validates:

1. No container-mode services remain after overlay merge (all must be host-mode)
2. All referenced data directories are writable
3. Host binaries exist for critical services (optional, advisory warnings)

Validation 3 is advisory because orchd doesn't know what binary a `RUN python ...` command needs -- that's the user's responsibility. But for well-known services (postgres, redis, nginx), the runtime can check `which postgres` and warn.

## Example: Full Bare Overlay

```
# bare.orch -- converts all container services to host-mode for LXC/bare

SERVICE postgres
RUN postgres -c config_file=${ORCH_DATA}/postgres/config/postgresql.dev.conf -p ${postgres_port}
ENV PGDATA=${ORCH_DATA}/postgres/data/pgdata
USER postgres

SERVICE redis
RUN redis-server --port ${redis_port} --dir ${ORCH_DATA}/redis

SERVICE nginx
RUN nginx -c ${ORCH_DATA}/nginx/nginx.conf -g 'daemon off;'

SERVICE localstack
DISABLED true

SERVICE frontend-chat
DISABLED true
```

This overlay:
- Converts postgres, redis, nginx to host-mode
- Disables localstack and frontend-chat (too complex for bare, or not needed)
- Leaves all host-mode services (django, celery, etc.) untouched -- they pass through as-is
