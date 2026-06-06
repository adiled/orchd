# orchd build + packaging. Run `just` (or `just --list`) to see recipes.
#
# Requires: rust (cargo), zig 0.16. The osx runtime also needs zstd + curl for
# the one-time kernel fetch. Install just itself with `brew install just`.

set shell := ["bash", "-uc"]

prefix   := env_var_or_default("PREFIX", "/usr/local")
kernel   := env_var_or_default("HOME", "") / ".orch/osx/kernel/vmlinux"
kata_ver := "3.31.0"
opt      := "ReleaseSafe"

# List recipes.
default:
    @just --list

# Build everything (orchd + both Zig co-processes), release mode.
build: build-orchd build-apple build-osx

build-orchd:
    cargo build --release

build-apple:
    cd orchd-apple && zig build -Doptimize={{opt}}

# Build the host runtime + guest init, then ad-hoc sign for VZ.
build-osx:
    cd orchd-osx && zig build -Doptimize={{opt}}
    cd orchd-osx && ./scripts/sign.sh

# Fetch our pinned Linux kernel into the user asset store (once). macOS/arm64.
kernel:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ -f "{{kernel}}" ]; then echo "kernel present: {{kernel}}"; exit 0; fi
    mkdir -p "$(dirname "{{kernel}}")"
    echo "fetching kata {{kata_ver}} arm64 kernel (streamed, ~40MB kept)..."
    tmp="$(mktemp -d)"
    url="https://github.com/kata-containers/kata-containers/releases/download/{{kata_ver}}/kata-static-{{kata_ver}}-arm64.tar.zst"
    curl -sSL "$url" | zstd -dc | tar -x -C "$tmp" -f - '*vmlinux-*'
    src="$(find "$tmp" -name 'vmlinux-*' ! -name '*debug*' ! -name '*confidential*' ! -name '*gpu*' ! -name '*dragonball*' | head -1)"
    cp "$src" "{{kernel}}"
    rm -rf "$tmp"
    echo "kernel -> {{kernel}}"

# Stage a self-contained dist/bin (binaries side by side, no env vars needed).
dist: build
    #!/usr/bin/env bash
    set -euo pipefail
    root="$PWD"
    rm -rf dist && mkdir -p dist/bin
    cp target/release/orchd                 dist/bin/
    cp orchd-apple/zig-out/bin/orchd-apple  dist/bin/
    cp orchd-osx/zig-out/bin/orchd-osx      dist/bin/
    cp orchd-osx/zig-out/bin/orchd-osx-init dist/bin/
    if command -v orch >/dev/null; then cp "$(command -v orch)" dist/bin/; \
      else echo "note: 'orch' not on PATH; install it (cargo install --git https://github.com/adiled/orch)"; fi
    (cd orchd-osx && ./scripts/sign.sh "$root/dist/bin/orchd-osx" >/dev/null)
    echo "staged -> dist/bin ($(ls dist/bin | tr '\n' ' '))"

# Install dist into PREFIX/bin and fetch the kernel. PREFIX defaults to /usr/local.
install: dist kernel
    install -d "{{prefix}}/bin"
    install dist/bin/* "{{prefix}}/bin/"
    @echo "installed -> {{prefix}}/bin   (kernel at {{kernel}})"

# Run every test suite.
test:
    cargo test
    cd orchd-apple && zig build test
    cd orchd-osx && ORCHD_OCI_SKIP_NET=1 zig build test

clean:
    cargo clean
    rm -rf dist orchd-apple/zig-out orchd-osx/zig-out
