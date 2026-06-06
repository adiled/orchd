#!/usr/bin/env bash
# Stage the inception example: build the static Linux orchd, fetch the container
# runtime (containerd + runc), and lay out tools/ exactly as the Orchfile mounts
# it. Idempotent.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
tools="$here/tools"

mkdir -p "$tools/bin"

echo "==> building static aarch64-linux orchd"
( cd "$repo" && just build-linux >/dev/null )
cp "$repo/target/aarch64-unknown-linux-musl/release/orchd" "$tools/bin/orchd"

echo "==> fetching containerd + runc (the runtime)"
if [ ! -e "$tools/bin/containerd" ]; then
  cver="$(gh api repos/containerd/containerd/releases/latest --jq '.tag_name' | sed 's/^v//')"
  echo "    containerd ${cver}"
  curl -fsSL "https://github.com/containerd/containerd/releases/download/v${cver}/containerd-${cver}-linux-arm64.tar.gz" \
    | tar -xz -C "$tools"   # -> bin/containerd, bin/ctr, bin/containerd-shim-runc-v2
fi
if [ ! -e "$tools/bin/runc" ]; then
  rurl="$(gh api repos/opencontainers/runc/releases/latest \
        --jq '.assets[] | select(.name=="runc.arm64") | .browser_download_url')"
  echo "    $rurl"
  curl -fsSL "$rurl" -o "$tools/bin/runc"
  chmod +x "$tools/bin/runc"
fi

echo "==> copying the in-VM driver + inner workload into tools/"
cp "$here/run-test.sh" "$tools/run-test.sh"
cp "$here/inner-Orchfile" "$tools/inner-Orchfile"

echo "==> staging a CA bundle (debian-slim has none; containerd needs it for registry TLS)"
if [ -f /etc/ssl/cert.pem ]; then
  cp /etc/ssl/cert.pem "$tools/ca-bundle.crt"
else
  curl -fsSL https://curl.se/ca/cacert.pem -o "$tools/ca-bundle.crt"
fi

echo "==> writing runnable Orchfile.run (absolute volume path)"
sed "s|__TOOLS__|$tools|" "$here/Orchfile" > "$here/Orchfile.run"

cat <<EOF

staged -> $tools ($(du -sh "$tools" | cut -f1))

Run it:
  ORCHD_APPLE_MODE=osx orchd --orchfile "$here/Orchfile.run" \\
    --runtime apple --platform orchdi --state-dir "$here/state" grow
  tail -f "$here/state/logs/orch.ctd.log"
EOF
