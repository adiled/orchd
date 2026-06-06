#!/usr/bin/env bash
# Stage the inception example: build the static Linux orchd, fetch the
# containerd toolchain (nerdctl-full: containerd + runc + cni + nerdctl), and
# lay out tools/ exactly as the Orchfile mounts it. Idempotent.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
tools="$here/tools"

mkdir -p "$tools/bin"

echo "==> building static aarch64-linux orchd"
( cd "$repo" && just build-linux >/dev/null )
cp "$repo/target/aarch64-unknown-linux-musl/release/orchd" "$tools/bin/orchd"

echo "==> fetching nerdctl-full (containerd + runc + cni + nerdctl)"
if [ ! -e "$tools/bin/containerd" ]; then
  url="$(gh api repos/containerd/nerdctl/releases/latest \
        --jq '.assets[] | select(.name | test("nerdctl-full-.*-linux-arm64.tar.gz$")) | .browser_download_url' 2>/dev/null \
        || curl -fsSL https://api.github.com/repos/containerd/nerdctl/releases/latest \
           | grep -o 'https://[^"]*nerdctl-full-[^"]*-linux-arm64.tar.gz' | head -1)"
  echo "    $url"
  curl -fsSL "$url" | tar -xz -C "$tools"
fi

echo "==> copying the in-VM driver + inner workload into tools/"
cp "$here/run-test.sh" "$tools/run-test.sh"
cp "$here/inner-Orchfile" "$tools/inner-Orchfile"

echo "==> writing runnable Orchfile.run (absolute volume path)"
sed "s|__TOOLS__|$tools|" "$here/Orchfile" > "$here/Orchfile.run"

cat <<EOF

staged -> $tools ($(du -sh "$tools" | cut -f1))

Run it:
  ORCHD_APPLE_MODE=osx orchd --orchfile "$here/Orchfile.run" \\
    --runtime apple --platform orchdi --state-dir "$here/state" grow
  tail -f "$here/state/logs/orch.ctd.log"
EOF
