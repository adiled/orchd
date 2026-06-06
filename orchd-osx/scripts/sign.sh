#!/bin/sh
# Ad-hoc codesign orchd-osx with the virtualization entitlement, so it can use
# Virtualization.framework locally. No Apple Developer account needed.
#
#   zig build && ./scripts/sign.sh
#
set -e
DIR="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${1:-$DIR/zig-out/bin/orchd-osx}"
codesign --force --sign - \
  --entitlements "$DIR/macos.entitlements" \
  "$BIN"
echo "signed: $BIN"
codesign -d --entitlements - "$BIN" 2>/dev/null | grep -A1 virtualization || true
