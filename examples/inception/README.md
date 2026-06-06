# Inception: orchd running containerd, inside a container orchd booted

A composability test, and the most demanding one in this repo. It exercises
**both** of orchd's runtimes at once, nested:

```
  macOS host
   └─ orchd  --runtime apple (osx mode)      <- boots a Linux microVM, no daemon
       └─ Debian VM  (sized + mounted from the Orchfile spec)
            └─ orchd  --runtime containerd    <- drives containerd inside the VM
                 └─ containerd -> a container (alpine)
```

orchd orchestrates orchd, two runtimes deep, in a box orchd created. If the
spec isn't honored end to end, this doesn't run: the outer VM needs the
**memory** and **cpus** from the Orchfile, and the containerd toolchain is
**mounted** in as a volume (not baked into an image, which would never fit the
in-RAM initramfs). So this doubles as the proof that orchd-osx honors the full
service spec (memory / cpus / volumes).

## What's here

| file | role |
|------|------|
| `Orchfile` | the **outer** unit: boot a Debian VM, sized, with the toolchain mounted, running the driver |
| `run-test.sh` | runs **inside** the VM: starts containerd, then has the inner orchd drive it |
| `inner-Orchfile` | the **inner** workload the containerd runtime runs (an alpine container) |
| `setup.sh` | stages `tools/` (builds the Linux orchd, fetches the containerd toolchain) and writes a runnable `Orchfile.run` |

`tools/` (containerd + runc + the Linux orchd) is fetched/built by
`setup.sh`, not committed.

## Run it

```sh
cd examples/inception
./setup.sh                 # builds the linux orchd, fetches containerd + runc, stages tools/
ORCHD_APPLE_MODE=osx \
  orchd --orchfile Orchfile.run --runtime apple --platform orchdi \
        --state-dir ./state grow
# watch the nested test:
tail -f ./state/logs/orch.ctd.log
```

You should see, from inside the VM: containerd come up, then
`orchd --runtime containerd grow` pull and run the inner alpine container, and
containerd's own `ctr tasks ls` report it RUNNING.

## Requirements

- macOS on Apple silicon, the orchd-osx runtime built + signed (`just build-osx`)
  and the kernel fetched (`just kernel`).
- **~3 GiB of free RAM.** The Orchfile asks for a 3 GiB / 3 cpu VM; containerd
  plus a nested container needs the room. On an 8 GiB machine, close other VMs
  and memory-heavy apps first (`colima stop`, `container system stop`, browsers)
  or the VM start fails with `BootFailed` (the host simply can't spare the RAM).
