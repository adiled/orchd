# 04 - systemd Platform

## Overview

The systemd platform generates `.service` unit files from Orchfile JSON and manages their lifecycle via `systemctl`. It is the first platform implemented in orchd.

## Scope Configuration

systemd supports two scopes:

| Scope | Unit directory | Manager command | Use case |
|-------|---------------|-----------------|----------|
| **system** (default) | `/etc/systemd/system/` | `systemctl` | Servers, LXC, VMs, root |
| **user** | `~/.config/systemd/user/` | `systemctl --user` | Desktop, rootless |

Configured via `ORCH_SYSTEMD_SCOPE=system|user` in `.orchrc` or env.

orchd generates units into `${ORCH_STATE_DIR}/units/` and symlinks them into the appropriate systemd directory.

## Unit File Generation

### Unit Naming

All units use the prefix `orch-` (or configured `ORCH_UNIT_PREFIX`):

- Service unit: `orch-<service_name>.service`
- Ready gate unit: `orch-<service_name>-ready.service` (for healthcheck-gated deps)
- Target: `orch.target` (groups all orchd-managed services)

### Template: Standard Service

```ini
[Unit]
Description=orch: <name>
PartOf=orch.target
After=orch-<dep>.service ...
BindsTo=orch-<requires_dep>.service ...

[Service]
Type=simple
ExecStartPre=<pre_start>
ExecStart=/bin/bash -c '<start_command>'
ExecStop=<stop_command>
ExecStopPost=<post_stop>
WorkingDirectory=<workdir>
Environment="KEY=value"
EnvironmentFile=<path>
User=<user>
Restart=<policy>
RestartSec=<delay>
TimeoutStartSec=<timeout_start>
TimeoutStopSec=<timeout_stop>
StartLimitBurst=<burst>
StartLimitIntervalSec=<interval>
MemoryMax=<memory>
CPUQuota=<cpus_percent>
LimitNOFILE=<limit>
LimitNPROC=<limit>
TasksMax=<max>
IOWeight=<weight>
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=orch.target
```

### Template: Oneshot Service

```ini
[Unit]
Description=orch: <name>
PartOf=orch.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c '<command>'
WorkingDirectory=<workdir>
TimeoutStartSec=<timeout_start>

[Install]
WantedBy=orch.target
```

### Template: Ready Gate (Healthcheck Companion)

For services that have healthchecks AND are depended upon by other services:

```ini
[Unit]
Description=orch: wait for <name> health
After=orch-<name>.service
BindsTo=orch-<name>.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c 'until <healthcheck_command>; do sleep 2; done'
TimeoutStartSec=<readiness_timeout>
```

Dependent services then declare `After=orch-<name>-ready.service` instead of `After=orch-<name>.service`.

### Template: Target Unit

```ini
[Unit]
Description=orch managed services

[Install]
WantedBy=multi-user.target
```

## Field Mapping Details

### ExecStart

Always wrapped in `/bin/bash -c '...'` to support shell features (pipes, env expansion, compound commands).

For host-mode services:
```ini
ExecStart=/bin/bash -c 'cd /path/to/workdir && python manage.py runserver 0.0.0.0:9090'
```

For container-mode services (with runtime):
```ini
ExecStartPre=/bin/bash -c 'nerdctl create --name orch-postgres ...'
ExecStart=/bin/bash -c 'nerdctl start --attach orch-postgres'
ExecStop=/bin/bash -c 'nerdctl stop orch-postgres'
```

### WorkingDirectory

Relative paths resolved against `ORCH_PROJECT_DIR`:

```rust
fn resolve_workdir(workdir: &Option<String>, project_dir: &Path) -> PathBuf {
    match workdir {
        Some(w) if Path::new(w).is_absolute() => PathBuf::from(w),
        Some(w) => project_dir.join(w),
        None => project_dir.to_path_buf(),
    }
}
```

### Environment

Each env entry becomes a separate `Environment=` line:

```ini
Environment="DJANGO_SETTINGS_MODULE=myapp.settings.dev"
Environment="POSTGRES_USER=postgres"
```

`env_files` entries map to `EnvironmentFile=`:

```ini
EnvironmentFile=/path/to/.env.local
```

### Restart Policy

| Orchfile | systemd |
|----------|---------|
| `no` | `Restart=no` |
| `always` | `Restart=always` |
| `on_failure` / `on-failure` | `Restart=on-failure` |

### Resource Limits

```ini
# MEMORY 4G
MemoryMax=4G

# CPUS 2
CPUQuota=200%

# CPU_QUOTA 150%
CPUQuota=150%

# LIMIT_NOFILE 65536
LimitNOFILE=65536

# LIMIT_NPROC 4096
LimitNPROC=4096

# TASKS_MAX 4096
TasksMax=4096

# IO_WEIGHT 500
IOWeight=500
```

CPUS to CPUQuota conversion: `cpus * 100` (e.g., 2 CPUs = 200%, 0.5 CPUs = 50%).

If both `cpus` and `cpu_quota` are set, `cpu_quota` takes precedence.

### Logging

Default: journald (no explicit directives needed).

If `logging.stdout` or `logging.stderr` are set in the Orchfile:

```ini
StandardOutput=file:/path/to/stdout.log
StandardError=file:/path/to/stderr.log
```

## Dependency Handling

### REQUIRES (hard dependency)

```ini
# REQUIRES postgres redis
BindsTo=orch-postgres.service orch-redis.service
After=orch-postgres.service orch-redis.service
```

`BindsTo=` means: if postgres stops, this service stops too. Combined with `After=` for ordering.

If the required service has a healthcheck, use the ready gate:

```ini
BindsTo=orch-postgres.service
After=orch-postgres-ready.service
```

### AFTER (soft dependency)

```ini
# AFTER localstack
After=orch-localstack.service
```

No `BindsTo=`. If localstack is not started or fails, this service still starts. Only ordering is enforced.

If the after-dep has a healthcheck:

```ini
After=orch-localstack-ready.service
```

### Ready Gate Decision Logic

A ready gate (`orch-<name>-ready.service`) is generated when ALL of:

1. The service has a `healthcheck` defined
2. At least one other enabled service lists it in `requires` or `after`

### Healthcheck Types in Ready Gates

```bash
# HTTP healthcheck
until curl -sf "http://localhost:9090/health" >/dev/null 2>&1; do sleep 2; done

# Command healthcheck
until pg_isready -h localhost -p 5433 -U postgres >/dev/null 2>&1; do sleep 2; done
```

## Lifecycle Operations

### generate

1. Parse orch JSON
2. Build ExecSets via runtime
3. Generate unit files into `${ORCH_STATE_DIR}/units/`
4. Symlink to systemd directory
5. Run `systemctl daemon-reload`

### start (up)

```bash
systemctl start orch-<name>.service
# or for all:
systemctl start orch.target
```

### stop (down)

```bash
systemctl stop orch-<name>.service
# or for all:
systemctl stop orch.target
```

### status

Query `systemctl show` for each managed unit:

```bash
systemctl show orch-<name>.service --property=ActiveState,SubState,MainPID,ExecMainStatus
```

Format into a table:

```
SERVICE          TYPE        STATUS      PID
-------          ----        ------      ---
postgres         host        running     1234
redis            host        running     1235
django           host        running     1240
celery           host        running     1241
```

### logs

```bash
journalctl -u orch-<name>.service --follow --lines 100
```

### health

Poll healthcheck commands/URLs for all enabled services with a configurable timeout. Report pass/fail per service.

## File Layout

```
${ORCH_STATE_DIR}/
  units/
    orch-postgres.service
    orch-postgres-ready.service
    orch-redis.service
    orch-django.service
    orch.target
```

Symlinked into:
- System scope: `/etc/systemd/system/orch-*.service`
- User scope: `~/.config/systemd/user/orch-*.service`

## Built-in Variable Expansion

Before writing unit files, orchd expands built-in variables in workdir, commands, and paths:

| Variable | Value |
|----------|-------|
| `${ORCH_PROJECT}` | Config: `orch_project_dir` |
| `${ORCH_DATA}` | Config: `orch_data_dir` |
| `${ORCH_STATE_DIR}` | Config: `orch_state_dir` |
| `${ORCH_CONTAINERS_DIR}` | Config: `orch_containers_dir` |

These are the same variables that orch preserves unresolved for runtime expansion.
