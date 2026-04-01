# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

qw is a bot for [DCSS](https://github.com/crawl/crawl) (Dungeon Crawl Stone Soup), the first bot to win DCSS with no human assistance. It's written entirely in Lua, executed within DCSS's clua scripting environment. The bot is maintained by the DCSS devteam.

## Build / Run

There is no compilation step for qw itself. The build process combines Lua source files into a single output:

```bash
# Produce qw.lua (recommended for development)
./make-qw.sh
```

There are no tests, linter, or formatter for this codebase.

### Crawl binary

qw requires a crawl binary from `../crawl/crawl-ref/source`. The crawl repo must be on the `0.32.1-qw` branch (has necessary patches). Build with PGO optimization (~1.4x faster):

```bash
python3 claude/crawl-build-optimised.py
```

### Running games

```bash
# Single game, watch in terminal (--visual watch)
python3 claude/debug-seed.py --seed 42 --visual watch

# Headless (fastest, default) — same seed may differ from visual due to rendering side-effects
python3 claude/debug-seed.py --seed 42

# With save checkpoints and verbose debug logging
python3 claude/debug-seed.py --seed 42 --save-interval 200 --verbose --visual watch

# Restore from a checkpoint
python3 claude/debug-seed.py --restore 1600 --from <session-dir> --visual watch
```

Visual mode determinism: `--visual watch` and `--visual true` produce identical gameplay for the same seed. `--visual none` (default/headless) runs faster but produces different gameplay because DCSS rendering has side-effects on game flow. Compare runs only within the same visual mode.

### Batch running and metrics

```bash
# Parallel batch: 100 games, 12 workers, 20k turn limit
python3 claude/run-parallel.py --total 100 --parallel 12 --max-turns 20000

# Specific seeds
python3 claude/run-parallel.py --seeds 15,18,44,73

# Analyze results (--name is required, output goes to results-<NAME>.txt)
python3 claude/analyze-runs.py --name $(git rev-parse --short HEAD)

# Analyze a single session
python3 claude/analyze-runs.py --single debug-seed-runs/<session-dir> --name test
```

Session output (morgues, decision logs, saves) goes to `debug-seed-runs/<session-dir>/`.

## Architecture

All source is in `source/` (~18k lines of Lua). Files are concatenated by `make-qw.sh` in a specific order: `source/variables.lua` first (declares all shared locals), then remaining `source/*.lua` files sorted alphabetically.

### Key architectural concepts

**Global state**: Two main local tables — `qw` (runtime state) and `const` (constants/enums). Game-persistent state uses DCSS's `c_persist` table.

**Plan cascade system**: The core decision engine. Each turn, qw runs a cascade of *plan functions* in priority order. A plan returns `true` (took action), `false` (did nothing), or `nil` (rerun). The main turn cascade in `set_plan_turn()` (`source/plans.lua`) chains sub-cascades:

```
save → quit → emergency → attack → rest → pre_explore → explore → pre_explore2 → explore2 → stuck
```

Each sub-cascade (e.g., `plans.emergency`, `plans.attack`) is itself a cascade of plan functions defined in the corresponding `plans-*.lua` file.

**Turn memoization**: `turn_memo()` and `turn_memo_args()` in `source/turn.lua` cache expensive computations per turn.

### Source file organization

| File(s) | Purpose |
|---|---|
| `variables.lua` | All shared local variable declarations (loaded first) |
| `main.lua` | Entry point: `ready()`, `start()`/`stop()`, main coroutine |
| `init.lua` | Game/session initialization, `c_persist` setup |
| `turn.lua` | Per-turn update logic, turn memoization |
| `plans.lua` | Cascade engine, main turn cascade, `set_plan_turn()` |
| `plans-emergency.lua` | Emergency survival plans (largest file) |
| `plans-attack.lua` | Combat engagement plans |
| `plans-explore.lua` | Exploration and autoexplore plans |
| `plans-items.lua` | Item pickup, identification, usage |
| `plans-stairs.lua` | Stair usage decisions |
| `plans-rest.lua` | Resting logic |
| `plans-religion.lua` | God ability usage |
| `plans-spells.lua` | Spell casting |
| `plans-stuck.lua` | Recovery when stuck |
| `plans-abyss.lua`, `plans-pan.lua`, `plans-orbrun.lua` | Branch-specific plans |
| `goals.lua` | Goal parsing, sequencing, and branch routing |
| `equipment.lua`, `equipment-compare.lua`, `equipment-props.lua` | Equipment evaluation and swapping |
| `attack.lua` | Attack targeting and damage calculations |
| `monsters.lua`, `monster-class.lua` | Monster assessment and classification |
| `move.lua`, `move-retreat.lua`, `move-flee.lua`, `move-tactics.lua`, `move-kiting.lua` | Movement subsystem |
| `map.lua` | Level map data, distance maps, traversal maps |
| `travel.lua` | Inter-level travel and stair navigation |
| `branches.lua` | Branch data and branch-specific logic |
| `skills.lua` | Skill training decisions |
| `religion.lua` | God data and worship logic |
| `stairs.lua` | Stair tracking and safety evaluation |
| `player.lua` | Player state queries |
| `items.lua` | Item property evaluation |
| `terrain.lua` | Terrain/feature queries |
| `los.lua` | Line-of-sight calculations |
| `io.lua` | Input/output helpers, `magic()` for sending keys, `do_command()` for named commands |
| `debug.lua` | Debug output, diagnostic functions |
| `util.lua` | General utility functions |

## Code Conventions

- All shared state is declared as `local` in `variables.lua` — this is critical because all files are concatenated into one scope.
- Plan functions follow the naming pattern `plan_<name>()` and return `true`/`false`/`nil`.
- Cascades are defined via `set_plan_<name>()` functions that call `cascade{}`.
- DCSS clua API functions (e.g., `you.turns()`, `crawl.process_keys()`, `magic()`) are used throughout — see DCSS source for API docs.
- Configuration variables are set in `qw.rc` as Lua globals (lines starting with `:`) and read in `initialize_rc_variables()`.
- Commit messages are short imperative statements; no co-author tags.

## Debugging

Use `--verbose` flag in `debug-seed.py` to enable all debug channels. Available channels: `combat`, `flee`, `goals`, `items`, `map`, `move`, `plans`, `plans-all`, `ranged`, `retreat`, `skills`, `throttle`.

All logging goes to `note_decision()` which writes to an external file (`qw_decisions_*.log`). Categories include: ACTION, ATTACK, BRANCH, COMBAT, COUNTER, DEBUG, EMERGENCY, EQUIP, EXPLORE, FLEE, GOAL, HEAL, INIT, ITEM, KITING, MAP, MEMORY, MONSTER, MOVE, NOTE, PANIC, PLAN, QUIT, RANGED, RELIGION, REST, RETREAT, SAVE, SHOP, SHOUT, SKILL, SPELL, STAIR, TACTICAL, TRAVEL, ZIG.

Key debug functions (usable from clua console): `override_goal()`, `toggle_single_step()`, `toggle_debug()`, `toggle_debug_channel()`, `get_vars()`.

## Project Knowledge

Accumulated project knowledge is in `claude/memories/`. Read these files when you need context about architecture, debugging workflow, optimization history, or game mechanics. Key files:

- `project_dcss_game_knowledge.md` — DCSS branches, runes, resistances, dangers
- `project_qw_execution_architecture.md` — DCSS game loop, ready() hook, cascade, magic() ESC pattern
- `project_speed_optimizations.md` — Build flags, C++ patches, runtime optimizations