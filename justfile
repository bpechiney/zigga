set quiet := true

default:
    just --list

build:
    nix develop -c zig build

run *args='':
    nix develop -c zig build run -- {{args}}

test:
    nix develop -c zig build test --summary all

# Merge gate: format check + top-level doc comment lint + run all tests.
check:
    nix develop -c zig fmt --check src/ build.zig
    scripts/lint-zig-module-doc-spacing.sh
    nix develop -c zig build test --summary all

fmt:
    nix develop -c zig fmt src/ build.zig

clean:
    rm -rf .zig-cache zig-out zig-pkg

# CI parity: verify everything is already formatted, no rewrites.
fmt-check:
    nix develop -c zig fmt --check src/ build.zig
