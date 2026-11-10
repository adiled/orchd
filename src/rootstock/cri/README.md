# orchd-rootstock-cri

Runs each container tree on any runtime that speaks Kubernetes' Container
Runtime Interface: CRI-O, containerd's built-in CRI, or Docker through
cri-dockerd. It talks CRI's gRPC on the runtime's socket; no `crictl`, no
kubelet.

`ORCHD_CRI_ENDPOINT` names the socket (`unix:///run/crio/crio.sock` or a bare
path). Without it, the first of these that answers CRI is used:

```
/run/containerd/containerd.sock
/run/crio/crio.sock
/var/run/cri-dockerd.sock
```

A containerd with its CRI plugin off, as Docker ships it, is passed over.

## A tree

`exec-set` turns a container service into one foreground
`orchd-rootstock-cri run --spec-base64 …`, which:

1. removes any pod an earlier run of this service left behind;
2. pulls the image if the runtime lacks it;
3. binds every PUBLISH on the host, then runs a pod sandbox on the runtime's
   pod network (its CNI), with the host's DNS and the service's name as
   hostname;
4. creates and starts the container in it: ENTRYPOINT and CMD as CRI's command
   and args, ENV and env files, volumes as bind mounts, USER, WORKDIR, and
   MEMORY, CPUS or CPU_QUOTA, TASKS_MAX as cgroup limits;
5. forwards each PUBLISH to the pod's IP, follows the container's log to its
   own stdout and stderr, and its state until it exits, then exits with its
   code;
6. on SIGTERM, stops the container with a 5 second grace, then stops and
   removes the pod.

## Publishing

`PUBLISH [address:]host:container` is served by the tree itself: it listens on
the address (every interface when none is given) and forwards each connection
to the container's port in the pod. So a loopback-only address stays loopback
only, a port already taken fails the grow by name, a service is reachable from
other pods at the host's address, and it behaves the same on every runtime.
The container sees connections arrive from the pod network's gateway.

`check` needs the runtime's pod network to be ready. `ORCHD_CRI_NETWORK=host`
puts pods on the host's network instead; a container's ports are then the
host's, so only `PUBLISH port:port` on every address is accepted.

Pods carry the labels `orchd.grove` and `orchd.service`; `crictl pods` shows
them. `remove` (contract 2) sweeps any pod left by a run that was killed.

## Limits

- CRI cannot start a container again once it has exited, so every grow is a
  fresh container: RECREATE `never` cannot keep a container's writable layer.
  Keep state in volumes.
- LIMIT_NOFILE and IO_WEIGHT have no place in CRI and are not applied.

## Source

```
src/rootstock/cri/
├── main.zig     verbs, and finding the endpoint
├── plugin.zig   envelope to exec set and run spec
├── cri.zig      the CRI messages, field by field from runtime/v1/api.proto
├── run.zig      the run leaf: pod, container, log, wait, teardown
└── log.zig      the CRI log format, and following a log file
```
