---
name: qw execution architecture
description: Complete execution architecture of qw bot inside DCSS — loading, game loop, cascade, magic(), hooks, state management
type: project
---

## How qw Lives Inside DCSS

### Loading
```
qw.rc  →  "include = qw.lua"  →  DCSS loads all Lua into one scope
make-qw.sh  →  variables.lua first (declares locals), then all *.lua alphabetically
```

All ~18k lines become a single Lua scope. Shared state lives in `local qw = {}`, `local const = {}`, `local plans = {}`.

### The Game Loop (one turn)

```
DCSS _input()                          ← main.cc, runs once per turn
 │
 ├─ if you_are_delayed():              ← resting, auto-travel, etc.
 │   handle_delay()                    ← DCSS handles turn natively
 │   world_reacts()                    ← monsters move, effects apply
 │   return                            ← ready() IS NOT CALLED
 │
 ├─ if !has_pending_input():
 │   clua.callfn("ready")             ← CALLS QW
 │   │
 │   ├─ ready() → run_qw()
 │   │   │
 │   │   ├─ Resume/create coroutine(qw_main)
 │   │   │   │
 │   │   │   ├─ turn_update()          ← reset caches, sync turn count,
 │   │   │   │                           update monsters, map, danger,
 │   │   │   │                           skills, equipment, goals
 │   │   │   │
 │   │   │   ├─ crawl.flush_input()    ← clear stale keystrokes
 │   │   │   │
 │   │   │   └─ plans.turn()           ← THE CASCADE
 │   │   │       │
 │   │   │       ├─ plan_save()     → false (skip)
 │   │   │       ├─ plan_quit()     → false (skip)
 │   │   │       ├─ plan_shop()     → false (skip)
 │   │   │       ├─ plans.emergency → false (no danger)
 │   │   │       ├─ plans.attack    → false (no enemies)
 │   │   │       ├─ plans.rest      → false (full HP)
 │   │   │       ├─ plans.explore   → plan_autoexplore()
 │   │   │       │                     magic("o")  ← queues "o\x1b\x1b\x1b"
 │   │   │       │                     qw.did_magic = true
 │   │   │       │                     return true  ← CASCADE STOPS
 │   │   │       X  (plans.stuck never reached)
 │   │   │
 │   │   ├─ Coroutine dies (finished)
 │   │   ├─ qw.did_magic=true → no dummy action needed
 │   │   └─ Return
 │   │
 │   └─ Return to DCSS
 │
 ├─ _get_next_cmd()                    ← reads "o" from buffer
 ├─ process_command(CMD_EXPLORE)       ← executes one explore step
 │   └─ ESC chars stop explore immediately
 ├─ world_reacts()                     ← monsters move, lua_calls_no_turn = 0
 └─ Loop back to _input()             ← next turn
```

### The Cascade Priority

```
plans.turn = cascade {
    plan_save,           -- 1. Checkpoint saves
    plan_quit,           -- 2. Graceful exit
    plan_shop,           -- 3. Buy from shop (if standing on one)
    plans.emergency,     -- 4. SURVIVAL (flee, heal, berserk, abilities)
    plans.attack,        -- 5. COMBAT (melee, ranged, spells)
    plans.rest,          -- 6. REST (wait, long rest)
    plans.pre_explore,   -- 7. Pre-explore setup
    plans.explore,       -- 8. EXPLORE (autoexplore, travel, stairs)
    plans.pre_explore2,  -- 9. More setup (read scrolls, drop items)
    plans.explore2,      -- 10. Shopping travel, portals, branch entry
    plans.stuck,         -- 11. FALLBACK (random step, teleport)
}
```

Each sub-cascade (e.g., `plans.emergency`) is itself a cascade of 20-50 plan functions. A plan returns:
- `true` → "I acted, stop cascade"
- `false` → "Nothing to do, try next plan"
- `nil` → "Rerun cascade from the top"

### The magic() → ESC Pattern

```lua
function magic(command)
    crawl.process_keys(command .. ESC .. ESC .. ESC)
    qw.did_magic = true
end
```

The 3 ESC chars are critical: they stop any multi-turn operation (explore, travel, rest) after **one step**, giving the bot per-turn control. Without them, DCSS would run the operation to completion while skipping `ready()`.

### The Dummy Action

If the coroutine yields without calling `magic()` (e.g., during expensive computation that spans multiple `ready()` calls), the dummy action sends `":" + ESC` — opens the annotation prompt then cancels it. This gives DCSS something to process, preventing the 1000-call infinite loop detector from triggering.

### Key Hooks DCSS Calls Into qw

| Hook | When | qw Handler |
|------|------|------------|
| `ready()` | Before each player action (if no pending input) | `main.lua` → cascade |
| `c_message(text, channel)` | Every game message | `io.lua` → tracks "Done exploring", rune pickup, etc. |
| `c_answer_prompt(prompt)` | Yes/no prompts | `io.lua` → auto-answers stair, equipment, trap prompts |
| `c_trap_is_safe(trap)` | Stepping on traps | `terrain.lua` → marks traps as safe |

### Persistent State

| Scope | Variable | Survives |
|-------|----------|----------|
| Per-turn | `qw.turn_memos` | Cleared each turn (memoization cache) |
| Per-session | `qw.*` | Lives until game ends |
| Per-game | `c_persist.*` | Survives save/load, level transitions |

### Why magic() ESC pattern is load-bearing

When DCSS is in a "delay" (auto-travel, autoexplore, resting), `ready()` is NOT called — the `you_are_delayed()` branch in `_input()` handles the turn via `handle_delay()` and returns early. This means qw's entire turn_update() / cascade / danger assessment is skipped.

The ESC chars after magic("o") stop autoexplore after one step, ensuring `ready()` fires next turn and qw gets full per-turn control. Without ESC, qw would be blind for hundreds of turns while DCSS runs explore/rest/travel natively.

### crawl.do_commands() vs magic()

`crawl.do_commands({"CMD_X"})` calls `process_command_on_record(CMD_X)` — the exact same function magic() triggers after key-to-command mapping. It's strictly better for atomic (single-turn) commands because it's key-binding independent and doesn't need the ESC workaround.

For multi-turn delay commands (CMD_EXPLORE, CMD_REST), `do_commands` starts the delay and DCSS handles subsequent turns natively — skipping ready(). This is why magic() with ESC is needed for these: the bot needs per-turn control.

**Rule: Use do_commands for atomic commands. Use magic() for multi-turn commands where the bot needs per-turn control.**
