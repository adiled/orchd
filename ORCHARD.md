# The Orchard Model

How `orchd` is structured: a set of small, stateless transforms joined by JSON
contracts. orchd grows things; it does not tell you how to arrange your orchard.

## Principle: mechanism, not policy

orchd provides **mechanism**: pure transforms from an Orchfile spec to a running,
supervised service, each stage addressable as a `stdin -> stdout` pipe. It holds **no
policy**. Composition strategy, environment naming, persisted manifests, project
discovery, and drift tracking belong to the *consuming project*, which arranges
orchd's stages however it likes.

The test: a grower must be able to splice their own step between any two stages
without forking orchd. If they can, orchd fits any orchard anyone designs.

## The pipeline

```
Orchfiles --graft--> spec --sow--> cuttings --plant--> beds --tend--> trees (in a grove)
         (compose)        (runtime)         (platform)         (init system)
```

| Stage | Verb | Transform | Owner |
|-------|------|-----------|-------|
| compose overlays | **graft** | base + overlays + args into one merged spec | `orch` (the parser) |
| runtime | **sow** | spec into a cutting per service (service + its ExecSet) | `orchd sow` |
| platform | **plant** | cuttings into beds (each service's native files) | `orchd plant` |
| activate + supervise | **tend** | install + start; keep alive | `orchd tend` |

Why the words earn their place:
- **graft**: joining plant tissues, exactly what overlay merge is (the spec's
  "systemd drop-in inspired" model).
- **sow**: choose the growing method and prepare each thing to be planted; the
  runtime deciding bare-soil vs container.
- **plant**: put it in ground the OS understands, a systemd unit or launchd plist.
- **tend**: keep it alive. `orchd tend <service>` *is* the supervisor leaf.

Names flex; the **contracts** are the commitment. We do not rename things that
don't map to a real transform. `logs` stays `logs`.

## The rows (plumbing): pure, pipe-able

Each row reads JSON on stdin, writes JSON on stdout, takes only its own stage's
flags, and is stateless. Only `tend` has side effects.

### `orchd sow --runtime <name>`

Runtime transform. Takes a cutting of each service: the service plus the
execution commands for the chosen runtime. Pure: no image pulls, no I/O. (Pulls
become a `pre_start` command, run later at tend time.)

```
stdin:   Spec        (the `orch parse` JSON)
stdout:  Cuttings
flags:   --runtime {bare|apple|containerd|podman}
```

### `orchd plant --platform <name> --namespace <ns>`

Platform transform. Prepares a bed for each cutting: the native files its init
system plants and tends, grouped per service.

```
stdin:   Cuttings
stdout:  Beds
flags:   --platform {systemd|launchd}  --namespace <ns>  --scope {user|system}
```

### `orchd tend`

Activation. Writes every bed's files to the init system, installs, and starts.
The only side-effecting row. `orchd tend <label>` (single service) is the
supervising leaf the platform points launchd/systemd at.

```
stdin:   Beds   (or reads a directory)
effects: install + start; or supervise one service for its lifetime
flags:   --start/--no-start  --scope
```

## The contracts

Three JSON shapes flow through the rows. They are versioned wire formats, not
internal types. Splice freely.

### Spec (graft to sow)

The merged Orchfile, emitted by `orch parse`. Abbreviated:

```json
{
  "version": "0.2.1",
  "args": { "app_port": "8000" },
  "services": [
    {
      "name": "nginx",
      "mode": "container",
      "image": "docker.io/library/nginx:alpine",
      "publish": [{ "host": 8080, "container": 80 }],
      "healthcheck": "http://localhost:8080",
      "requires": [], "after": [],
      "recreate": "always",
      "restart": { "policy": "on_failure", "delay": "2s" },
      "resources": {}, "timeouts": {}, "logging": {}
    }
  ]
}
```

### Cuttings (sow to plant)

A cutting per service: the service paired to its ExecSet. The runtime's knowledge
is now fully captured in command strings; `plant` never needs to know which
runtime ran.

```json
{
  "version": "0.2.1",
  "runtime": "apple",
  "cuttings": [
    {
      "service": { "...": "the full Service object from the spec" },
      "exec": {
        "pre_start": "container image pull docker.io/library/nginx:alpine",
        "start":     "container run --name <ns>-nginx --init --publish 8080:80 docker.io/library/nginx:alpine",
        "stop":      "container stop <ns>-nginx",
        "post_stop": "container delete --force <ns>-nginx"
      }
    }
  ]
}
```

`exec` is the orthogonality contract: every runtime writes it, every platform reads
it, neither knows the other. (This is why `ExecSet` is serde-serializable.)

### Beds (plant to tend)

One bed per service, grouping that service's native files (so a plist and its
supervise-spec, or a unit and its ready-gate, stay together). The grove handle
gets its own bed. `kind` lets `tend` install each file correctly.

```json
{
  "platform": "launchd",
  "namespace": "orch",
  "scope": "user",
  "beds": [
    {
      "label": "orch.nginx",
      "artifacts": [
        { "kind": "supervise-spec", "path": "~/.orch/supervise/orch.nginx.json",     "content": "{ ... }" },
        { "kind": "plist",          "path": "~/Library/LaunchAgents/orch.nginx.plist","content": "<?xml ..." }
      ]
    }
  ]
}
```

On systemd a service bed carries `kind: "unit"` (plus `kind: "ready-gate"` when it
is a healthchecked dependency), and the grove gets a bed of one `kind: "target"`.

## The walks (porcelain): sugar over rows

Convenience commands are nothing but pre-composed walks over the rows. They exist
for the common path; they are never the only path.

```
orchd grow    ==  orch parse $files | orchd sow | orchd plant | orchd tend
orchd survey  ==  status of a grove (walk it, query the init system, report health)
orchd fell    ==  stop the grove, then remove its beds
```

A grower who wants control reaches past `grow` for the individual rows. orchd never
owns *how* the walk is arranged.

## Groves (namespaces)

A **grove** is a named cluster of tended trees, a namespace. Many groves share one
orchard (machine); each is surveyed and felled independently. A grove's identity is
the `--namespace` carried through `plant`/`tend`; on systemd it is also a real
`<ns>.target`, on launchd a `<ns>.`-prefixed set.

Naming a grove, pinning which composition produced it, detecting drift: these are
**policy**. A consuming project layers them by capturing the rows' JSON (the Spec it
grafted, the Beds it planted) wherever and however it wants. orchd does not
prescribe a manifest format; it emits the material a manifest would be made of.

## Splicing: the whole point

A consuming project inserts its own intelligence between any two rows:

```sh
orch parse base.orch staging.orch --arg env=staging \
  | orchd sow --runtime apple \
  | jq '.cuttings |= map(select(.service.disabled | not))' \   # their policy, not orchd's
  | my-secret-injector \                                       # their step
  | orchd plant --platform launchd --namespace staging \
  | tee staging.beds.json \                                    # their manifest, their format
  | orchd tend
```

orchd sees none of this. It transformed Spec into Cuttings and Cuttings into Beds;
the grower arranged the orchard.

## Status

The rows ship as real subcommands. `sow` and `plant` are pure pipes; `tend` is
the side-effecting activator. The porcelain (`generate`/`up`) still exists
unchanged and remains the common path.

| Concern | Implementation | Row |
|---------|----------------|-----|
| runtime transform | `runtime::exec_set` | `orchd sow` (pure pipe, shipped) |
| platform transform | `platform` generators | `orchd plant` (pure pipe, shipped) |
| activation | write + `install` + `start` | `orchd tend` (shipped) |
| image pull | `pre_start` command run at tend | (no eager prepare in the rows) |
| common path | `generate` / `up` (monolith) | porcelain, unchanged |
| composition / manifests | the grower's policy, over the rows' JSON | out of scope, by design |

Worked end to end on a real Mac:

```sh
orch parse Orchfile \
  | orchd --runtime bare  sow \
  | jq '.cuttings |= map(select(.service.name != "worker"))' \   # a grower's own step
  | orchd --platform launchd --namespace orch --user plant \
  | orchd --platform launchd --namespace orch --user tend     # service running under launchd
```

Two contracts to remember when piping by hand:
- `sow` is the only stage that takes `--runtime`; `plant`/`tend` take `--platform`.
- `plant` bakes absolute paths into each artifact from its config, so `plant` and
  `tend` must be given the same `--namespace` / `--scope` / `--state-dir`. The
  porcelain and any single flag set do this for you.

Still future work: re-expressing `generate`/`up` as a `grow` walk over the rows so
there is one code path, not two.

## Litmus

> A grower should be able to splice a step between `sow` and `plant` without touching
> orchd. If they can, orchd is an orchard tool: it fits any grove anyone designs. If
> they can only `grow`, it is a walled garden.
