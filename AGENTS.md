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

- Missing or excess blank line after `//!` block (exactly one blank line required between the last `//!` line and the first declaration).

Zig 0.16 deprecates via `///` doc-comments only, so `zig build` emits no warnings for `ArrayListUnmanaged` or default-init patterns. Treat the stdlib source at `/nix/store/.../zig-0.16.0/lib/std/` as the oracle when in doubt.

## Architecture

The exe (`src/main.zig`) owns the raylib window + audio device; everything else is the `zigga` library module, re-exported through `src/root.zig`:

- `world.zig` — sim state: `Player`, pools for bullets/enemy_bullets/enemies/particles, runtime `Bounds`, `sim_prng` ref. **Sim-pure**: holds no pointers to audio/shake.
- `systems.zig` — `simTick` (player → fire → enemies → bullets → collide → sweep), `updateEnemies`, `collide`, `updateParticles`. Functions take `*Audio`/`*Shake` by parameter.
- `audio.zig` — frame-batched SFX queue with per-tag `Policy` (`always`/`coalesce`/`latest`); music stubs.
- `shake.zig` — trauma model; `offset()` polar-samples a disk and is called **only from render**.
- `pool.zig` — fixed-capacity generational `Pool(T)` over `MultiArrayList`. Kill is deferred; `sweep` reclaims at end of tick.
- `game.zig` — owns allocators, PRNGs, `World`, `Audio`, `Shake`; drives the frame loop.
- `math.zig` — `Vec2`, `clamp`.

The exe and the library are tested as **separate** test executables (`run_mod_tests`, `run_exe_tests`) wired into the `test` step — `zig test` only tests one module at a time, so each gets its own binary.

### Frame loop & rate domains

Per frame: `pollInput → accumulator += clamp(getFrameTime, 5·sim_dt) → N×simTick(sim_dt) → updateParticles(frame_dt) → shake.update(frame_dt) → audio.flush() → render`.

- Sim phases run at fixed 60 Hz `sim_dt` and are deterministic.
- Particles and shake update on `frame_dt` (cosmetic, replay-irrelevant).
- `audio.flush()` runs **once per frame**, not per tick — multi-tick frames correctly merge coalesce events.

### Design invariants

- **Sim purity.** `World` knows nothing about audio/shake. `collide(world, audio, shake)` and `simTick(world, audio, shake, input, dt)` take them by parameter.
- **PRNG split.** `world.sim_prng` drives all sim randomness (enemy AI, bullet jitter, particle initial vel). `game.shake_prng` (seeded `+% 0x9E37_79B9_7F4A_7C15`) drives `shake.offset()` only. Never drain `sim_prng` from frame-paced code or replay tests will flake.
- **Killer owns FX.** On a fatal hit, the killer emits the audio tag, spawns particles, kicks shake, **then** calls `kill()`. The dying entity is silent for the rest of the tick.
- **Bounds come from the window.** `world_mod.Bounds` is threaded into `World.init` from window dims at runtime (`Bounds.default = 700×900` is for tests). Don't bake screen size into `world.zig`.

### macOS window quirks (`openWindow` in src/main.zig)

The helper carries several workarounds — read the comments before changing it:

- `FLAG_WINDOW_HIGHDPI` must be passed to `setConfigFlags` **before** `initWindow`; setting it after has no effect.
- **Don't drop the HIGHDPI flag.** Without it, the 1×1 probe-then-resize dance on macOS Retina leaves raylib with a framebuffer that doesn't match the window — the screen renders all-black. Keep HIGHDPI on; if world points and framebuffer pixels diverge, bridge them with a Camera2D zoom (`zoom = getRenderHeight() / bounds.height`) in `drawCurrent`, not by toggling the flag.
- The helper opens a hidden 1×1 probe window first, then resizes — `setWindowSize` and `getMonitorWidth/Height` both speak GLFW *screen coordinates* (points on macOS), not pixels. Don't divide by `getWindowScaleDPI` — it reports `(1, 1)` on some macOS configurations and is unreliable.
- `macos_chrome_height` (52 pt) is subtracted from the monitor height to leave room for the menu bar (~24 pt) and title bar (~28 pt); without it the window's bottom edge clips off-screen.
- HUD / overlays draw in pixel space (`getRenderWidth/Height`); world entities draw inside the camera zoom in point space (`bounds.width/height`). Don't mix.

## Gotchas

- `audio.zig` placeholder sine waves point at a static `[N]i16` buffer. `loadSoundFromWave` copies the samples, so the wave handle is dropped without calling `rl.unloadWave` — calling it would `free()` static storage. If you switch to runtime-allocated waves, restore the unload.
- `rl.getFrameTime` must never be reachable from any function under `simTick`. The sim only sees `sim_dt`. If a determinism test flakes, grep for it.
