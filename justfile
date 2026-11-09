# orchd build + packaging. Run `just` (or `just --list`) to see recipes.
#
# Cross-platform: everywhere it builds orchd and its bare rootstock
# (orchd-rootstock-bare); on macOS it also builds the apple and applz
# rootstocks (orchd-rootstock-apple, orchd-rootstock-applz).
# Requires zig 0.17.1, and orch on PATH to bundle the parser. Install just with
# `brew install just`.

set shell := ["bash", "-uc"]

prefix   := env_var_or_default("PREFIX", "/usr/local")
opt      := "ReleaseSafe"
target   := if os() == "linux" { "-Dtarget=" + arch() + "-linux-musl" } else { "" }

# List recipes.
default:
    @just --list

# Build for this platform: orchd and bare everywhere, plus apple and applz on macOS.
build:
    #!/usr/bin/env bash
    set -euo pipefail
    just build-orchd
    just build-bare
    if [ "{{os()}}" = "macos" ]; then just build-apple && just build-applz; fi

build-orchd:
    zig build -Doptimize={{opt}} {{target}}

build-bare:
    cd orchd-rootstock-bare && zig build -Doptimize={{opt}} {{target}}

[macos]
build-apple:
    cd orchd-rootstock-apple && zig build -Doptimize={{opt}}

[macos]
build-applz:
    cd orchd-rootstock-applz && zig build -Doptimize={{opt}}

# Stage a self-contained dist/bin for this platform.
dist: build
    #!/usr/bin/env bash
    set -euo pipefail
    rm -rf dist && mkdir -p dist/bin
    cp zig-out/bin/orchd dist/bin/
    cp orchd-rootstock-bare/zig-out/bin/orchd-rootstock-bare dist/bin/
    if [ "{{os()}}" = "macos" ]; then
        cp orchd-rootstock-apple/zig-out/bin/orchd-rootstock-apple dist/bin/
        cp orchd-rootstock-applz/zig-out/bin/orchd-rootstock-applz dist/bin/
    fi
    if command -v orch >/dev/null; then cp "$(command -v orch)" dist/bin/; fi
    echo "staged -> dist/bin ($(ls dist/bin | tr '\n' ' '))"

# Install dist into PREFIX/bin.
install: dist
    #!/usr/bin/env bash
    set -euo pipefail
    install -d "{{prefix}}/bin"
    install dist/bin/* "{{prefix}}/bin/"
    echo "installed -> {{prefix}}/bin"

# Run the test suites for this platform.
test:
    #!/usr/bin/env bash
    set -euo pipefail
    zig build test
    (cd orchd-rootstock-bare && zig build test)
    if [ "{{os()}}" = "macos" ]; then
        (cd orchd-rootstock-apple && zig build test)
        (cd orchd-rootstock-applz && zig build test)
    fi

clean:
    rm -rf dist zig-out orchd-rootstock-bare/zig-out orchd-rootstock-apple/zig-out orchd-rootstock-applz/zig-out
