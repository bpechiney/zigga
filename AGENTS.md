# zigga — Zig 0.16 Top-Down 2D Shooter

zigga is a Galaga clone in Zig 0.16, rendered with raylib via the `raylib-zig` bindings.

## Build, Test, Run

Run inside `nix develop` so the pinned Zig 0.16.0 is on PATH.

- just run            # zig build run
- just build          # zig build
- just test           # zig build test
- just fmt            # zig fmt; never bypass before commit
- just clean          # rm -rf .zig-cache zig-out zig-pkg
- just check          # CI / merge gate — see Validation
- just fmt-check      # `zig fmt --check` only — CI parity, no rewrites

## Validation (the merge gate)

**Always run `just check` before claiming work complete.** It runs `zig build test` inside the pinned Nix shell, then enforces structural lints that the compiler does not:

- Deprecation: `ArrayListUnmanaged`, default-init pattern. **Zig 0.16 deprecates via `///` doc-comments only — `zig build` emits no warnings.** This grep/awk lint is the *only* enforcement. Stdlib source at `/nix/store/.../zig-0.16.0/lib/std/` is the oracle when in doubt.
- Missing or excess blank line after `//!` block (exactly one blank line required between the last `//!` line and the first declaration).

## Architecture

Two modules, both built and tested by `build.zig`:

- `src/main.zig` — the `zigga` executable's root. Owns the raylib loop and window setup.
- `src/root.zig` — the `zigga` library module (currently effectively empty). Imported into the exe as `@import("zigga")`. Add reusable code here as the codebase grows.

The exe and the library are tested as **separate** test executables (`run_mod_tests`, `run_exe_tests`) wired into the `test` step — `zig test` only tests one module at a time, so each gets its own binary.

### macOS window quirks (`openWindow` in src/main.zig)

The helper carries several workarounds — read the comments before changing it:

- `FLAG_WINDOW_HIGHDPI` must be passed to `setConfigFlags` **before** `initWindow`; setting it after has no effect.
- The helper opens a hidden 1×1 probe window first, then resizes — `setWindowSize` and `getMonitorWidth/Height` both speak GLFW *screen coordinates* (points on macOS), not pixels. Don't divide by `getWindowScaleDPI` — it reports `(1, 1)` on some macOS configurations and is unreliable.
- `macos_chrome_height` (52 pt) is subtracted from the monitor height to leave room for the menu bar (~24 pt) and title bar (~28 pt); without it the window's bottom edge clips off-screen.
