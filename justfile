# orchd build + packaging. Run `just` (or `just --list`) to see recipes.
#
# Cross-platform: on macOS it also builds the Apple container runtimes (orchd-apple,
# orchd-osx) and fetches the kernel; on Linux it builds just orchd (the systemd +
# podman/containerd path needs no extra binaries). Requires rust (cargo); macOS
# also needs zig 0.16 + zstd/curl for the kernel. Install just with `brew install just`.

set shell := ["bash", "-uc"]

prefix   := env_var_or_default("PREFIX", "/usr/local")
kernel   := env_var_or_default("HOME", "") / ".orch/osx/kernel/vmlinux"
kata_ver := "3.31.0"
opt      := "ReleaseSafe"

# List recipes.
default:
    @just --list

# Build for this platform: orchd everywhere, plus the Apple runtimes on macOS.
build:
    #!/usr/bin/env bash
    set -euo pipefail
    just build-orchd
    if [ "{{os()}}" = "macos" ]; then just build-apple && just build-osx; fi

build-orchd:
    cargo build --release

[macos]
build-apple:
    cd orchd-apple && zig build -Doptimize={{opt}}

# Build the host runtime + guest init, then ad-hoc sign for VZ.
[macos]
build-osx:
    cd orchd-osx && zig build -Doptimize={{opt}}
    cd orchd-osx && ./scripts/sign.sh

# Fetch our pinned Linux kernel into the user asset store (once).
[macos]
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

# Stage a self-contained dist/bin for this platform.
dist: build
    #!/usr/bin/env bash
    set -euo pipefail
    root="$PWD"
    rm -rf dist && mkdir -p dist/bin
    cp target/release/orchd dist/bin/
    if [ "{{os()}}" = "macos" ]; then
        cp orchd-apple/zig-out/bin/orchd-apple  dist/bin/
        cp orchd-osx/zig-out/bin/orchd-osx       dist/bin/
        cp orchd-osx/zig-out/bin/orchd-osx-init  dist/bin/
        (cd orchd-osx && ./scripts/sign.sh "$root/dist/bin/orchd-osx" >/dev/null)
    fi
    if command -v orch >/dev/null; then cp "$(command -v orch)" dist/bin/; fi
    echo "staged -> dist/bin ($(ls dist/bin | tr '\n' ' '))"

# Install dist into PREFIX/bin (and, on macOS, fetch the kernel).
install: dist
    #!/usr/bin/env bash
    set -euo pipefail
    install -d "{{prefix}}/bin"
    install dist/bin/* "{{prefix}}/bin/"
    if [ "{{os()}}" = "macos" ]; then just kernel; fi
    echo "installed -> {{prefix}}/bin"

# Run the test suites for this platform.
test:
    #!/usr/bin/env bash
    set -euo pipefail
    cargo test
    if [ "{{os()}}" = "macos" ]; then
        (cd orchd-apple && zig build test)
        (cd orchd-osx && ORCHD_OCI_SKIP_NET=1 zig build test)
    fi

clean:
    cargo clean
    rm -rf dist orchd-apple/zig-out orchd-osx/zig-out
