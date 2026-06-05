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
Orchfiles --graft--> spec --sow--> sown --plant--> artifacts --tend--> running grove
         (compose)        (runtime)       (platform)          (init system)
```

| Stage | Verb | Transform | Owner |
|-------|------|-----------|-------|
| compose overlays | **graft** | base + overlays + args into one merged spec | `orch` (the parser) |
| runtime | **sow** | spec into each service annotated with its ExecSet | `orchd sow` |
| platform | **plant** | sown into native artifacts (units / plists / specs) | `orchd plant` |
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

Runtime transform. Annotates each service with the execution commands for the
chosen runtime. Pure: no image pulls, no I/O. (Pulls become a `pre_start` command,
run later at tend time.)

```
stdin:   Spec        (the `orch parse` JSON)
stdout:  Sown
flags:   --runtime {bare|apple|containerd|podman}
```

### `orchd plant --platform <name> --namespace <ns>`

Platform transform. Renders each sown tree into the native artifacts its init
system plants and tends.

```
stdin:   Sown
stdout:  Artifacts
flags:   --platform {systemd|launchd}  --namespace <ns>  --scope {user|system}
```

### `orchd tend`

Activation. Writes artifacts to the init system, installs, and starts. The only
side-effecting row. `orchd tend <label>` (single service) is the supervising leaf
the platform points launchd/systemd at.

```
stdin:   Artifacts   (or reads a directory)
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

### Sown (sow to plant)

The spec, with each service paired to its ExecSet. The runtime's knowledge is now
fully captured in command strings; `plant` never needs to know which runtime ran.

```json
{
  "version": "0.2.1",
  "runtime": "apple",
  "trees": [
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

### Artifacts (plant to tend)

The native files plus where they go. `kind` lets `tend` install each correctly.

```json
{
  "platform": "launchd",
  "namespace": "orch",
  "scope": "user",
  "artifacts": [
    { "kind": "plist",         "label": "orch.nginx", "path": "~/Library/LaunchAgents/orch.nginx.plist", "content": "<?xml ..." },
    { "kind": "supervise-spec","label": "orch.nginx", "path": "~/.orch/supervise/orch.nginx.json",       "content": "{ ... }" }
  ]
}
```

On systemd the same shape carries `kind: "unit"`, `kind: "ready-gate"`, and a
`kind: "target"` for the grove handle.

## The walks (porcelain): sugar over rows

Convenience commands are nothing but pre-composed walks over the rows. They exist
for the common path; they are never the only path.

```
orchd grow    ==  orch parse $files | orchd sow | orchd plant | orchd tend
orchd survey  ==  status of a grove (walk it, query the init system, report health)
orchd fell    ==  tend --stop, then remove artifacts (down + clean)
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
grafted, the Artifacts it planted) wherever and however it wants. orchd does not
prescribe a manifest format; it emits the material a manifest would be made of.

## Splicing: the whole point

A consuming project inserts its own intelligence between any two rows:

```sh
orch parse base.orch staging.orch --arg env=staging \
  | orchd sow --runtime apple \
  | jq '.trees |= map(select(.service.disabled | not))' \   # their policy, not orchd's
  | my-secret-injector \                                     # their step
  | orchd plant --platform launchd --namespace staging \
  | tee staging.artifacts.json \                             # their manifest, their format
  | orchd tend
```

orchd sees none of this. It transformed Spec into Sown and Sown into Artifacts; the
grower arranged the orchard.

## Today to target

The mechanism already exists inside the monolithic `generate`/`up`; the work is to
expose the seams, not to invent new logic.

| Concern | Today | Target |
|---------|-------|--------|
| runtime transform | `runtime::exec_set` inside `engine::generate` | `orchd sow` (pipe) |
| platform transform | `platform::generate_all` inside `engine::generate` | `orchd plant` (pipe) |
| activation | `platform::install` + `lifecycle::start` | `orchd tend` |
| image pull | eager `runtime::prepare` at generate | a `pre_start` command run at tend |
| common path | `generate` / `up` (monolith) | `grow` (walk over rows) |
| composition / manifests | implicit (flags + prefix scan) | the grower's policy, over the rows' JSON |

`ExecSet` is already serde-serializable, so the first seam is open. The rest is
lifting the internal calls to `stdin/stdout` boundaries and letting the walks
re-express as compositions of the rows.

## Litmus

> A grower should be able to splice a step between `sow` and `plant` without touching
> orchd. If they can, orchd is an orchard tool: it fits any grove anyone designs. If
> they can only `grow`, it is a walled garden.
