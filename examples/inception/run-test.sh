#!/bin/sh
# Runs INSIDE the orchd-osx VM (Debian). Brings up containerd from the mounted
# nerdctl-full toolchain, then has our Linux orchd drive it via the containerd
# runtime. Verbose so the detached supervisor's logfile tells the whole story.
set -u
log(){ echo "[inception] $*"; }
export PATH=/opt/tools/bin:$PATH
# debian-slim ships no CA bundle, so containerd's TLS can't verify the registry.
# Point Go's TLS at the host CA bundle we mounted in.
export SSL_CERT_FILE=/opt/tools/ca-bundle.crt

log "STAGE 0: $(uname -m); cgroup=$(stat -fc %T /sys/fs/cgroup 2>/dev/null); ip=$(ip -4 addr show 2>/dev/null | awk '/inet /{print $2}' | grep -v 127 | head -1)"

# Put the CA bundle where apt/openssl look too (not just Go's SSL_CERT_FILE),
# so apt-get over https works to install iptables below.
mkdir -p /etc/ssl/certs
cp /opt/tools/ca-bundle.crt /etc/ssl/certs/ca-certificates.crt

# nerdctl looks for CNI plugins at /opt/cni/bin by default; point it at the
# mounted plugins so container networking works.
mkdir -p /opt/cni
ln -sf /opt/tools/libexec/cni /opt/cni/bin

# nerdctl's default bridge needs iptables; the toolchain has none and the VM has
# outbound network, so pull it at runtime.
if ! command -v iptables >/dev/null 2>&1; then
  log "installing iptables..."
  if apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq iptables >/dev/null 2>&1; then
    log "iptables ok"
  else
    log "iptables install FAILED (container networking may not work)"
  fi
fi

log "STAGE 1: start containerd"
mkdir -p /run/containerd /var/lib/containerd
containerd >/var/log/containerd.log 2>&1 &
for i in $(seq 1 20); do ctr version >/dev/null 2>&1 && break; sleep 1; done
if ! ctr version >/dev/null 2>&1; then
  log "containerd did NOT come up:"; tail -25 /var/log/containerd.log; exit 1
fi
log "containerd up: $(ctr --version 2>/dev/null)"

log "STAGE 2: orchd drives containerd (the runtime under test)"
mkdir -p /run/orchd
orchd --orchfile /opt/tools/inner-Orchfile --runtime containerd --platform orchdi --state-dir /run/orchd grow
log "orchd grow rc=$?"
sleep 8
log "--- orchd survey ---"; orchd --platform orchdi --state-dir /run/orchd survey
log "--- nerdctl ps -a (what orchd started via containerd) ---"; nerdctl ps -a 2>&1
log "--- supervisor logs ---"; tail -25 /run/orchd/logs/*.log 2>/dev/null
log "=== DONE ==="
sleep 5
