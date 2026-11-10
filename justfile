# orchd build + packaging. Run `just` (or `just --list`) to see recipes.
#
# One zig build makes orchd and the rootstocks this platform runs: bare
# everywhere, containerd on Linux, apple and applz on macOS.
# Requires zig 0.17.1, and orch on PATH to bundle the parser. Install just with
# `brew install just`.

set shell := ["bash", "-uc"]

prefix   := env_var_or_default("PREFIX", "/usr/local")
opt      := "ReleaseSafe"
target   := if os() == "linux" { "-Dtarget=" + arch() + "-linux-musl" } else { "" }

# List recipes.
default:
    @just --list

# Build orchd and this platform's rootstocks into zig-out/bin.
build:
    zig build -Doptimize={{opt}} {{target}}

# Stage a self-contained dist/bin for this platform.
dist: build
    #!/usr/bin/env bash
    set -euo pipefail
    rm -rf dist && mkdir -p dist/bin
    cp zig-out/bin/* dist/bin/
    if command -v orch >/dev/null; then cp "$(command -v orch)" dist/bin/; fi
    echo "staged -> dist/bin ($(ls dist/bin | tr '\n' ' '))"

# Install dist into PREFIX/bin.
install: dist
    #!/usr/bin/env bash
    set -euo pipefail
    install -d "{{prefix}}/bin"
    install dist/bin/* "{{prefix}}/bin/"
    echo "installed -> {{prefix}}/bin"

# Check before a pull request: format, every test this machine runs, and the
# Linux builds cross-compiled.
check:
    #!/usr/bin/env bash
    set -euo pipefail
    zig fmt --check build.zig build.zig.zon src
    zig build test
    for target in x86_64-linux-musl aarch64-linux-musl; do
        zig build -Dtarget="$target" -p "$PWD/.zig-cache/check/$target"
    done
    echo "checks passed"

# Run every test this machine runs.
test:
    zig build test

clean:
    rm -rf dist zig-out
