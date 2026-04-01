---
name: speed_optimizations
description: All crawl+qw speed optimizations achieved, bug fixes, build flags, profiling findings
type: project
---

## Speed Optimizations (1.95x total from original baseline)

### Build flags (crawl-build-optimised.py)
```
NOASSERTS=1 BUILD_LUA=yes CFOPTIMIZE="-O3 -march=native -flto -ffast-math" + PGO
```
- `BUILD_LUA=yes` statically links bundled Lua with LTO — enables cross-boundary inlining (14%)
- `-ffast-math` gives ~1% on top
- PGO two-stage: build with -fprofile-generate, train on seed 42, rebuild with -fprofile-use

### Runtime
- jemalloc via LD_PRELOAD (~16%) — auto-applied by debug-seed.py and run-1000.py
- `COROUTINE_THROTTLE=false` always (no overhead, -no-throttle flag handles throttle)
- `perf_event_paranoid=-1` needed for perf profiling (`sudo sysctl kernel.perf_event_paranoid=-1`)

### C++ patches in crawl repo (all committed)
- `map-knowledge.cc`: cached `known_map_bounds()` — was 30% of CPU (~15% speedup)
- `view.cc`: `_viewwindow_should_render()` returns false in headless
- `output.cc`: `print_stats()` early return in headless
- `libunix.cc`: `cprintf()` early return in headless
- `dbg-scan.cc`: `debug_item_scan()` skipped in headless mode

### qw Lua performance changes
- `source/map.lua`: cached `dist_map.map`/`excluded_map` and `pos.x`/`pos.y` in locals in hot distance map functions (~2% deep game)
- `source/init.lua`: Lua GC tuned with `setpause(400)` (~3% deep game)
- `source/debug.lua`: `note_decision()` gated on `qw.debug_mode` (except PERF)

### Bug fixes
- `source/plans.lua`: cascade no longer panics when plan returns true without advancing turn — skips plan instead (fixed seeds 18, 81 stuck forever)
- `source/plans-explore.lua`: `plan_move_towards_destination` detects unreachable destinations after 200 turns and clears them (fixed seed 44 stuck on D:1)
- `source/move.lua`: tracks `move_dest_start_turn` for stuck detection

### Tooling
- `claude/debug-seed.py`: --debug/--no-debug flags, jemalloc, COROUTINE_THROTTLE=false; session dirs in `debug-seed-runs/`
- `claude/run-parallel.py`: rewritten with --seeds, --total/--parallel, --debug, live monitoring (--fast removed; fast is now the default)
- `claude/run-1000.py`: jemalloc LD_PRELOAD
- `claude/crawl-build-optimised.py`: full PGO build script

### What didn't work
- LuaJIT: breaks dungeon generation (table iteration order, connectivity check fails 50/50)
- BOLT: needs LBR hardware not available on KVM VMs
- CPU pinning, NOWIZARD, stripping, -fno-plt: negligible

### Deep game profiling (seed 3, XL15, Spider:1)
- Lua interpreter is 45% of CPU in deep games (vs 15% early game)
- `luaV_gettable` at 12.8% — map tables use negative indices hitting hash part
- Remaining opportunity: offset map coords to [1,161] for Lua array-part O(1) lookup (~5% total)

### Measurement method
- Seed 42 deterministic: always 6831 turns, yak kill D:9
- In-game PERF at 1400 calls: original ~20400ms → best ~10440ms = 1.95x
- `perf record` for C++ profiling, `gprof` for initial analysis

**Why:** Enable faster batch testing and debugging iterations.
**How to apply:** Run `claude/crawl-build-optimised.py` for optimal crawl binary.
