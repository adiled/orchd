#!/bin/sh
# Runs INSIDE the orchd-osx VM (Debian). Starts containerd from the mounted
# toolchain, then has our Linux orchd drive it via the in-process containerd
# backend (the container runs in the host netns, so no CNI/iptables). Verbose so
# the detached supervisor's logfile tells the whole story.
set -u
log(){ echo "[inception] $*"; }
export PATH=/opt/tools/bin:$PATH

# containerd pulls images itself; debian-slim ships no CA bundle, so give it one
# (system path + the env Go reads) for registry TLS.
mkdir -p /etc/ssl/certs
cp /opt/tools/ca-bundle.crt /etc/ssl/certs/ca-certificates.crt
export SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt

log "STAGE 0: $(uname -m); cgroup=$(stat -fc %T /sys/fs/cgroup 2>/dev/null)"

log "STAGE 1: start containerd"
mkdir -p /run/containerd /var/lib/containerd
containerd >/var/log/containerd.log 2>&1 &
for i in $(seq 1 20); do ctr version >/dev/null 2>&1 && break; sleep 1; done
if ! ctr version >/dev/null 2>&1; then
  log "containerd did NOT come up:"; tail -25 /var/log/containerd.log; exit 1
fi
log "containerd up: $(ctr --version 2>/dev/null)"

log "STAGE 2: orchd drives containerd via its gRPC API"
mkdir -p /run/orchd
orchd --orchfile /opt/tools/inner-Orchfile --runtime containerd --platform orchdi --state-dir /run/orchd grow
log "orchd grow rc=$?"
sleep 8
log "--- orchd survey (what orchd supervises) ---"
orchd --platform orchdi --state-dir /run/orchd survey
log "--- containerd's own view (ctr), proving the task is real ---"
for n in $(ctr namespaces ls -q 2>/dev/null); do
  log "namespace=$n"; ctr -n "$n" tasks ls 2>&1; ctr -n "$n" containers ls 2>&1
done
log "--- supervisor log ---"; tail -20 /run/orchd/logs/*.log 2>/dev/null
log "=== DONE ==="
sleep 5
