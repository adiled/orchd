# orchd-rootstock-containerd

Runs each container tree on containerd through its own API: images, snapshots,
containers and tasks over gRPC on containerd's socket, with no `ctr` or
`nerdctl`.

| Setting | Default | |
|---|---|---|
| `ORCHD_CONTAINERD_SOCKET` | `/run/containerd/containerd.sock` | containerd's socket |
| `ORCHD_CONTAINERD_NETWORK` | `pod` | `host` puts trees on the host's network |
| `ORCHD_CNI_PATH` | `/opt/cni/bin:/usr/libexec/cni:/usr/lib/cni` | where the CNI plugins are |
| `ORCHD_CONTAINERD_NO_PIVOT_ROOT` | | `1` when the host root cannot pivot (an initramfs) |

## A tree's network

containerd's API has no networking, so the tree brings its own, as nerdctl does:

1. a network namespace of its own, pinned at `/run/orchd/netns/<grove>-<service>`;
2. the CNI `loopback` and `bridge` plugins attach it to the bridge `orchd0` on
   `10.87.0.0/16`, with masquerading out (iptables);
3. the task joins that namespace, and resolves through the host's
   resolv.conf, or systemd-resolved's upstream file when the host only has a
   loopback stub;
4. each `PUBLISH [address:]host:container` is bound on the host by the tree and
   forwarded to the container's address, so a loopback-only address stays
   loopback only, a port already taken fails the grow by name, and one tree
   reaches another's published port at `10.87.0.1`.

When the tree stops, it detaches from CNI and unpins its namespace; `remove`
sweeps whatever a killed tree left behind. `check` needs the `bridge`,
`host-local` and `loopback` plugins
([containernetworking/plugins](https://github.com/containernetworking/plugins)).

With `ORCHD_CONTAINERD_NETWORK=host`, a container's ports are the host's, so only
`PUBLISH port:port` on every address is accepted.

## RECREATE

`never` (the default) keeps the container and its snapshot between runs and
wakes it while its definition holds; `always` replants on every grow.
