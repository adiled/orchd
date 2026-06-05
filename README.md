# orchd

Execution engine for the [Orch specification](https://github.com/adiled/orch). Takes parsed Orchfile JSON and turns it into running, supervised services.

```
Orchfile → orch parse (JSON) → Runtime (ExecSet) → Platform (native artifacts)
```

**Runtime** produces execution commands from service definitions. **Platform** consumes them and generates native service manager artifacts.

| Layer    | Implemented          | Planned                |
|----------|----------------------|------------------------|
| Runtime  | `bare`, `apple`      | `containerd`, `podman` |
| Platform | `systemd`, `launchd` | (none)|

The [`apple`](orchd-apple/) runtime runs container-mode services on macOS 26+
via Apple's native [container](https://github.com/apple/container) framework. It
is a standalone Zig co-process (`orchd-apple/`) that speaks XPC to
`container-apiserver`; build it with `cd orchd-apple && zig build`.

The `launchd` platform supervises services via [`orchd supervise`](src/supervise.rs),
a launchd-native leaf process that renders the dependency ordering and stop/post-stop
teardown launchd lacks natively, driven by the runtime-neutral `ExecSet`.

## Install

```sh
cargo build --release
ln -sf target/release/orchd /usr/local/bin/orchd
```

Requires [orch](https://github.com/adiled/orch) in `PATH`.

## Commands

```
orchd generate [--force]
orchd up [services...] [--no-generate]
orchd down [services...]
orchd restart [services...]
orchd status [--json]
orchd logs <service> [-n lines] [--follow]
orchd health [--timeout 60s] [-v]
orchd list [--enabled] [--disabled] [--json]
orchd clean [--keep-data]
```

### Composable rows

The same work, exposed as pipe-able stages so a consuming project can splice its
own steps between them. Each reads JSON on stdin and writes JSON on stdout;
`tend` is the only one with side effects.

```
orchd sow      # spec (orch parse JSON)  ->  sown (each service + its ExecSet)
orchd plant    # sown                    ->  artifacts (units/plists/specs + paths)
orchd tend     # artifacts               ->  written, installed, started
```

```sh
orch parse Orchfile \
  | orchd --runtime apple sow \
  | jq '.trees |= map(select(.service.disabled | not))' \   # your policy, not orchd's
  | orchd --platform launchd --namespace orch plant \
  | orchd --platform launchd --namespace orch tend
```

`sow` takes `--runtime`; `plant` and `tend` take `--platform`. orchd holds no
composition policy (profiles, manifests, namespaces); those are the consuming
project's, built over the rows' JSON. See [`ORCHARD.md`](ORCHARD.md).


## Global Flags

```
--orchfile <path>       Path to Orchfile (default: ./Orchfile)
--overlay <path>        Overlay file (repeatable)
--runtime <name>        bare (default), apple
--namespace <name>      Unit prefix (default: orch)
--state-dir <path>      Artifact directory (default: ~/.orch)
--data-dir <path>       Service data (default: <state-dir>/data)
--orch-bin <path>       orch binary (default: orch)
-v, --verbose
-q, --quiet
```

## Configuration

`.orchrc` in project directory or `$HOME`, one `KEY=VALUE` per line:

```
runtime=bare
namespace=myapp
state_dir=/var/lib/myapp
```

Supported keys: `runtime`, `platform`, `namespace`, `state_dir`, `data_dir`, `orch_bin`, `orchfile`.

Merge order: CLI > environment > `.orchrc` > defaults.

## Example

A three-service stack (Postgres, a one-shot migration, and an app) wired with
dependencies and health checks. This runs on the implemented Linux path
(`bare` runtime + `systemd`).

**`Orchfile`**

```
ARG pg_port=5432
ARG app_port=8000

SERVICE postgres
RUN /usr/lib/postgresql/16/bin/postgres -D /var/lib/postgresql/16/main -p ${pg_port}
USER postgres
HEALTHCHECK pg_isready -h localhost -p ${pg_port}
RESTART on-failure
RESTART_DELAY 2s
MEMORY 1G

SERVICE migrate
RUN /srv/app/bin/migrate
WORKDIR /srv/app
ENV DATABASE_URL=postgres://localhost:${pg_port}/app
REQUIRES postgres
ONESHOT true

SERVICE app
RUN /srv/app/bin/server --port ${app_port}
WORKDIR /srv/app
ENV DATABASE_URL=postgres://localhost:${pg_port}/app
REQUIRES postgres
AFTER migrate
HEALTHCHECK http://localhost:${app_port}/health
RESTART on-failure
TIMEOUT_START 30s
```

**Generate and run**

```sh
orchd generate                 # Orchfile -> systemd units in ~/.orch/units
orchd up                       # start the orch.target (deps ordered automatically)
orchd status                   # SERVICE / STATE / SUB / PID table
orchd health --timeout 30s -v  # poll each HEALTHCHECK until green
orchd logs app --follow        # tail a service
orchd clean                    # stop everything and remove generated artifacts
```

**Generated `orch-app.service`** (produced from the `app` service above)

```ini
[Unit]
Description=orch: app
PartOf=orch.target
After=orch-postgres-ready.service orch-migrate.service
BindsTo=orch-postgres.service

[Service]
Type=simple
ExecStart=/bin/bash -c '/srv/app/bin/server --port 8000'
WorkingDirectory=/srv/app
Environment="DATABASE_URL=postgres://localhost:5432/app"
Restart=on-failure
TimeoutStartSec=30s

[Install]
WantedBy=orch.target
```

Because `postgres` has a `HEALTHCHECK` and is required, orchd generates a
`orch-postgres-ready.service` gate so dependents start only once Postgres is
actually accepting connections, not merely once its process is up:

```ini
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c 'until pg_isready -h localhost -p 5432 >/dev/null 2>&1; do sleep 2; done'
TimeoutStartSec=120s
```

> On macOS the same Orchfile generates launchd plists instead (`--platform launchd`,
> the default there); container-mode services (`FROM …`) use the `apple` runtime.


## Tests

```sh
cargo test                        # 113 unit tests
cargo test -- --include-ignored   # + integration test (needs orch binary)
```

## License

Licensed under the Apache License, Version 2.0. See [`LICENSE`](LICENSE).
