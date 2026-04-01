#!/usr/bin/env python3
"""Save/restore debugging tool for qw DCSS bot.

Runs a seeded game with periodic save checkpoints, enabling iterative debugging:
  1. Run a game with a known seed, saving every N turns
  2. When the bot dies, identify the last save before death
  3. Tweak qw source code
  4. Restore from a checkpoint and re-run to test the change

Each run (fresh or restore) gets a unique directory under debug-seed-runs/.

Usage:
    # Fast run (default: no saves, no debug channels)
    python3 claude/debug-seed.py --seed 42

    # With saves and verbose debug channels
    python3 claude/debug-seed.py --seed 42 --save-interval 200 --verbose

    # Watch in terminal with delays
    python3 claude/debug-seed.py --seed 42 --visual watch

    # Restore from turn 600 of a previous session (dir name from output)
    python3 claude/debug-seed.py --seed 42 --restore 600 --from 2026-03-22-10-30-seed-42-uuid-a1b2c3d4
"""

import argparse
import fcntl
import os
import pty
import re
import select
import shutil
import signal
import subprocess
import sys
import time
import uuid
from pathlib import Path

# --- Configuration -----------------------------------------------------------

CRAWL_DIR = Path("/home/agent/repos/crawl/crawl-ref/source")
CRAWL_BIN = CRAWL_DIR / "crawl"

QW_DIR = Path(
    subprocess.check_output(
        ["git", "rev-parse", "--show-toplevel"],
        cwd=Path(__file__).resolve().parent,
    )
    .decode()
    .strip()
)
SESSIONS_DIR = QW_DIR / "debug-seed-runs"

PLAYER_NAME = None  # set in main() as <uuid>-<seed>
HEALTH_POLL_INTERVAL = 3
STARTUP_TIMEOUT = 30
IDLE_DISMISS_TIMEOUT = 30
IDLE_QUIT_TIMEOUT = 60
IDLE_KILL_TIMEOUT = 90


# --- Utilities ---------------------------------------------------------------

def log(msg):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def save_file_path(session_dir):
    """Path to the active save file within a session directory."""
    return session_dir / "saves" / f"{PLAYER_NAME}.cs"




JEMALLOC_PATH = Path("/usr/lib/x86_64-linux-gnu/libjemalloc.so.2")


def generate_debug_rc(save_interval, max_time=0, max_turns=0,
                      decision_log_dir=None, verbose=False, visual="none"):
    """Generate a temporary rc file for bot runs.

    Visual modes:
      none  → headless: no rendering, fastest
      true  → renders + keyboard suppressed, slower but deterministic
      watch → renders + attached to terminal, with travel/explore delays

    Headless and visual produce DIFFERENT gameplay because DCSS rendering
    has side effects (viewwindow/monster::check_redraw). To compare runs
    deterministically, all must use the same mode (all headless or all visual).
    """
    rc_path = Path(decision_log_dir) / f"_debug-{PLAYER_NAME}.rc" if decision_log_dir else QW_DIR / f"_debug-{PLAYER_NAME}.rc"
    lines = [
        f"include = {QW_DIR / 'qw.rc'}",
        ": AUTO_START = true",
        f": SAVE_INTERVAL = {save_interval}",
        ": COROUTINE_THROTTLE = false",
        ": DELAYED = false",
        "reduce_animations = true",
        "use_animations =",
        "suppress_startup_errors = true",
    ]
    if visual == "watch":
        lines.append(": NO_HEADLESS = true")
        lines.append("travel_delay = 20")
        lines.append("explore_delay = 20")
        lines.append("show_travel_trail = true")
        lines.append("view_delay = 20")
    elif visual == "true":
        lines.append(": NO_HEADLESS = true")
        lines.append("travel_delay = 0")
        lines.append("explore_delay = 0")
        lines.append("show_travel_trail = false")
        lines.append("view_delay = 0")
    else:
        lines.append("travel_delay = 0")
        lines.append("explore_delay = 0")
        lines.append("show_travel_trail = false")
        lines.append("view_delay = 0")
    if verbose:
        lines.append(": DEBUG_MODE = true")
        lines.append(': DEBUG_CHANNELS = { "combat", "flee", "goals", "move", "plans", "plans-all", "shopping" }')
    else:
        lines.append(": DEBUG_MODE = false")
        lines.append(': DEBUG_CHANNELS = {}')
    if max_time > 0:
        lines.append(f": MAX_REALTIME = {max_time}")
    if max_turns > 0:
        lines.append(f": MAX_TURNS = {max_turns}")
    if decision_log_dir:
        lines.append(f': DECISION_LOG_DIR = "{decision_log_dir}"')
    rc_path.write_text("\n".join(lines) + "\n")
    return rc_path


def parse_morgue(morgue_path):
    """Extract key information from a morgue file."""
    if not morgue_path or not morgue_path.exists():
        return {}
    content = morgue_path.read_text(errors="replace")
    info = {}

    # Outcome
    if "escaped with the Orb" in content:
        info["outcome"] = "WIN"
    elif "Quit the game" in content:
        info["outcome"] = "QUIT"
    else:
        info["outcome"] = "DEATH"

    # XL
    m = re.search(r"\(level\s+(\d+)", content[:500])
    if m:
        info["xl"] = int(m.group(1))
    else:
        m = re.search(r"XL:\s+(\d+)", content)
        if m:
            info["xl"] = int(m.group(1))

    # HP at death
    m = re.search(r"(-?\d+)/(\d+)\s+HPs?\)", content[:500])
    if m:
        info["hp_at_death"] = int(m.group(1))
        info["max_hp"] = int(m.group(2))

    # Turns — check both "Turns: N" stat line and "(N turns)" in header
    m = re.search(r"Turns:\s*(\d+)", content[:1000])
    if m:
        info["turns"] = int(m.group(1))
    else:
        m = re.search(r"\((\d+) turns?\)", content[:1000])
        if m:
            info["turns"] = int(m.group(1))

    # Location — from header "on level N of the X" or body
    m = re.search(r"on level (\d+) of the (.+?)\.", content[:1000])
    if m:
        info["location"] = f"{m.group(2)}:{m.group(1)}"
    else:
        m = re.search(r"You (?:are|were) on level (\d+) of the (.+?)\.", content)
        if m:
            info["location"] = f"{m.group(2)}:{m.group(1)}"

    # Killer
    death_patterns = [
        r"(?:Slain|[Kk]illed|Blown up|Annihilated|Mangled|Demolished) by "
        r"(.*?)(?:\s*\(\d+ damage\))?$",
        r"Constricted to death by (.*?)(?:\s*\(\d+ damage\))?$",
        r"Frozen to death by (.*?)(?:\s*\(\d+ damage\))?$",
        r"Drained of all life by (.*?)(?:\s*\(\d+ damage\))?$",
        r"Killed from afar by (.*?)(?:\s*\(\d+ damage\))?$",
        r"Poisoned by (.*?)(?:\s*\(\d+ damage\))?$",
        r"Shot with .+ by (.*?)(?:\s*\(\d+ damage\))?$",
    ]
    for line in content[:1500].split("\n"):
        line_s = line.strip()
        for pat in death_patterns:
            m = re.search(pat, line_s)
            if m:
                info["killer"] = m.group(1).strip()
                info["death_line"] = line_s
                break
        if "killer" in info:
            break

    # Seed
    m = re.search(r"Game seed:\s*(\d+)", content[:500])
    if m:
        info["seed"] = int(m.group(1))

    return info


def find_morgue(morgue_dir=None):
    """Find the most recent morgue file for the debug player."""
    search_dir = morgue_dir or SESSIONS_DIR
    morgues = sorted(
        search_dir.glob(f"morgue-{PLAYER_NAME}-*.txt"),
        key=lambda p: p.stat().st_mtime,
        reverse=True,
    )
    if morgues:
        return morgues[0]
    # Also check for dump file without timestamp
    dump = search_dir / f"{PLAYER_NAME}.txt"
    if dump.exists():
        return dump
    return None


def get_descendant_cpu_time(pid):
    """Get CPU time of the process (and direct children) via /proc."""
    try:
        total = 0
        # Read the target process's own CPU time
        with open(f"/proc/{pid}/stat") as f:
            fields = f.read().split()
            utime = int(fields[13])
            stime = int(fields[14])
            # fields[15] and [16] are cutime/cstime — waited-for children
            cutime = int(fields[15])
            cstime = int(fields[16])
            total = utime + stime + cutime + cstime
        return total
    except (FileNotFoundError, IndexError, ValueError, PermissionError):
        return None


# --- Terminal game runner ----------------------------------------------------

def run_game_terminal(seed, rc_path, debug_dir, is_restore=False,
                      on_checkpoint=None, max_time=0, session_start=None):
    """Run crawl attached to the real terminal for spectating.

    Checkpoint monitoring runs in a background thread. Returns the same
    (exit_reason, save_turn) tuple as run_game.
    """
    import threading

    if session_start is None:
        session_start = time.time()
    session_saves = debug_dir / "saves"
    session_saves.mkdir(parents=True, exist_ok=True)

    crawl_args = [
        str(CRAWL_BIN),
        "-lua-max-memory", "256",
        "-no-throttle",
        "-name", PLAYER_NAME,
        "-morgue", str(debug_dir),
        "-rcdir", str(QW_DIR),
        "-rc", str(rc_path),
        "-extra-opt-first", f"save_dir={session_saves}/",
    ]
    if not is_restore and not save_file_path(debug_dir).exists():
        crawl_args.extend(["-seed", str(seed)])

    env = os.environ.copy()
    if JEMALLOC_PATH.exists():
        env["LD_PRELOAD"] = str(JEMALLOC_PATH)

    # Run crawl with inherited stdio so the user sees the game.
    proc = subprocess.Popen(crawl_args, cwd=CRAWL_DIR, env=env)

    # Background checkpoint monitor
    monitor_stop = threading.Event()
    save_path = save_file_path(debug_dir)
    last_save_mtime = save_path.stat().st_mtime if save_path.exists() else 0

    def monitor():
        nonlocal last_save_mtime
        while not monitor_stop.is_set():
            monitor_stop.wait(HEALTH_POLL_INTERVAL)
            if monitor_stop.is_set():
                break
            if save_path.exists():
                cur_mtime = save_path.stat().st_mtime
                if cur_mtime > last_save_mtime:
                    last_save_mtime = cur_mtime
                    if on_checkpoint:
                        on_checkpoint(debug_dir)

    monitor_thread = threading.Thread(target=monitor, daemon=True)
    monitor_thread.start()

    try:
        proc.wait()
    except KeyboardInterrupt:
        proc.terminate()
        proc.wait()
    finally:
        monitor_stop.set()
        monitor_thread.join(timeout=3)

    # Final checkpoint sweep
    if on_checkpoint:
        on_checkpoint(debug_dir)

    morgue = find_morgue(debug_dir)
    info = parse_morgue(morgue) if morgue else {}
    outcome = info.get("outcome", "UNKNOWN").lower()

    # Show death/win summary and pause so the user can read the terminal
    print()
    if not info:
        print("  ** Game ended (no morgue found — possible crash) **")
    elif outcome == "death":
        killer = info.get("killer", "unknown")
        loc = info.get("location", "?")
        turns = info.get("turns", "?")
        xl = info.get("xl", "?")
        hp = info.get("hp_at_death", "?")
        mhp = info.get("max_hp", "?")
        print(f"  ** DIED: {killer} on {loc} **")
        print(f"  ** XL {xl}, turn {turns}, HP {hp}/{mhp} **")
    elif outcome == "win":
        turns = info.get("turns", "?")
        print(f"  ** WON THE GAME! (turn {turns}) **")
    elif outcome == "quit":
        print("  ** Quit **")
    print()
    try:
        input("  Press Enter to continue...")
    except (EOFError, KeyboardInterrupt):
        pass

    if outcome == "win":
        return "win", None
    elif outcome == "quit":
        return "quit", None
    elif outcome == "death":
        return "death", None
    return "unknown", None


# --- Game runner -------------------------------------------------------------

def run_game(seed, rc_path, debug_dir, is_restore=False,
             on_checkpoint=None, max_time=0, session_start=None):
    """Run a single crawl game session. Returns (exit_reason, save_turn).

    exit_reason: "death" | "quit" | "win" | "timeout" | "hung" | "error"
    save_turn: unused (None), kept for API compat

    With non-exiting checkpoint saves, the game runs continuously. Checkpoints
    are detected by dump file mtime changes and handled via on_checkpoint.
    """
    if session_start is None:
        session_start = time.time()
    # Ensure session saves dir exists
    session_saves = debug_dir / "saves"
    session_saves.mkdir(parents=True, exist_ok=True)

    master_fd = None
    try:
        crawl_args = [
            str(CRAWL_BIN),
            "-lua-max-memory", "256",
            "-no-throttle",
            "-name", PLAYER_NAME,
            "-morgue", str(debug_dir),
            "-rcdir", str(QW_DIR),
            "-rc", str(rc_path),
            "-extra-opt-first", f"save_dir={session_saves}/",
        ]
        # Only pass -seed for new games, not restores
        if not is_restore and not save_file_path(debug_dir).exists():
            crawl_args.extend(["-seed", str(seed)])

        env = os.environ.copy()
        env["TERM"] = "xterm"
        if JEMALLOC_PATH.exists():
            env["LD_PRELOAD"] = str(JEMALLOC_PATH)

        master_fd, slave_fd = pty.openpty()
        proc = subprocess.Popen(
            crawl_args,
            cwd=CRAWL_DIR,
            stdin=slave_fd,
            stdout=slave_fd,
            stderr=slave_fd,
            env=env,
        )
        os.close(slave_fd)

        # --- Startup phase ---
        game_started = False
        startup_deadline = time.time() + STARTUP_TIMEOUT
        buf = b""

        while time.time() < startup_deadline:
            r, _, _ = select.select([master_fd], [], [], 1.0)
            if r:
                try:
                    data = os.read(master_fd, 8192)
                    buf += data
                except OSError:
                    break
                text = buf.decode("latin-1", errors="replace")
                clean = re.sub(r"\x1b[\[\(][0-9;?]*[a-zA-Z=lh]?", "", text)
                # Also strip the buffer to last 4KB to avoid unbounded growth
                if len(buf) > 8192:
                    buf = buf[-4096:]

                if "--more--" in clean:
                    os.write(master_fd, b" ")
                    buf = b""
                elif "Choose Game" in clean or "Load game" in clean:
                    os.write(master_fd, b"\r")
                    buf = b""
                elif "Welcome back" in clean or "Press ? for" in clean:
                    # Game loaded from save, skip welcome
                    os.write(master_fd, b" ")
                    buf = b""
                elif "PLANNING" in clean or "Waypoint" in clean or "Health:" in clean:
                    game_started = True
                    break

                for err in re.findall(r"Lua error[^\n]*", clean):
                    log(f"  Lua error during startup: {err[:200]}")

            if proc.poll() is not None:
                log(f"  Exited during startup rc={proc.returncode}")
                break

        if not game_started and proc.poll() is None:
            os.write(master_fd, b"\r")
            time.sleep(2)
            os.write(master_fd, b"\t")
            time.sleep(3)

        # --- Monitoring phase ---
        flags = fcntl.fcntl(master_fd, fcntl.F_GETFL)
        fcntl.fcntl(master_fd, fcntl.F_SETFL, flags | os.O_NONBLOCK)

        # Continuous pty drain thread — prevents crawl from blocking on
        # a full pty buffer. Uses select() to avoid busy-waiting.
        import threading
        drain_stop = threading.Event()
        def drain_pty():
            while not drain_stop.is_set():
                try:
                    r, _, _ = select.select([master_fd], [], [], 0.1)
                    if r:
                        os.read(master_fd, 65536)
                except (OSError, ValueError):
                    drain_stop.wait(0.1)
        drain_thread = threading.Thread(target=drain_pty, daemon=True)
        drain_thread.start()

        game_start_time = time.time()
        last_cpu_time = get_descendant_cpu_time(proc.pid)
        last_activity = time.time()
        poll_count = 0
        # Track save file mtime to detect non-exiting checkpoint saves.
        # The C++ do_pending_checkpoint() updates the .cs file every N turns.
        save_path = save_file_path(debug_dir)
        last_save_mtime = save_path.stat().st_mtime if save_path.exists() else 0

        while True:
            time.sleep(HEALTH_POLL_INTERVAL)
            poll_count += 1

            if proc.poll() is not None:
                break

            cpu_time = get_descendant_cpu_time(proc.pid)
            if cpu_time is not None and cpu_time != last_cpu_time:
                last_activity = time.time()
                last_cpu_time = cpu_time

            idle = time.time() - last_activity

            # Detect non-exiting checkpoint saves: the .cs file mtime changes
            # when crawl's do_pending_checkpoint() writes a checkpoint.
            if save_path.exists():
                cur_mtime = save_path.stat().st_mtime
                if cur_mtime > last_save_mtime:
                    last_save_mtime = cur_mtime
                    if on_checkpoint:
                        on_checkpoint(debug_dir)

            # Safety net: kill if bot didn't quit itself (grace period)
            if max_time > 0 and time.time() - session_start > max_time + 30:
                log("  Safety timeout reached (bot failed to quit)")
                try:
                    os.write(master_fd, b"\x11yes\r")
                except OSError:
                    pass
                time.sleep(5)
                if proc.poll() is None:
                    proc.kill()
                    proc.wait()
                try:
                    os.close(master_fd)
                except OSError:
                    pass
                # Write reason.txt (overwrites any existing)
                reason_path = debug_dir / "reason.txt"
                elapsed = int(time.time() - session_start)
                reason_path.write_text(
                    f"TIMEOUT\nwall-clock timeout after {elapsed}s\n")
                return "timeout", None

            # Graduated idle handling
            if idle > IDLE_DISMISS_TIMEOUT and poll_count > 6:
                try:
                    os.write(master_fd, b" \r")
                except OSError:
                    pass

            if idle > IDLE_QUIT_TIMEOUT and poll_count > 12:
                morgue_found = any(
                    debug_dir.glob(f"morgue-{PLAYER_NAME}-*.txt"))
                if morgue_found or idle > IDLE_QUIT_TIMEOUT + 15:
                    log(f"  Idle {idle:.0f}s, sending quit")
                    try:
                        os.write(master_fd, b"\x11yes\r")
                    except OSError:
                        pass
                    time.sleep(5)
                    if proc.poll() is not None:
                        break

            if idle > IDLE_KILL_TIMEOUT:
                log(f"  HUNG, killing after {idle:.0f}s idle")
                proc.kill()
                proc.wait()
                try:
                    os.close(master_fd)
                except OSError:
                    pass
                return "hung", None

        # --- Determine exit reason ---
        drain_stop.set()
        drain_thread.join(timeout=2)
        try:
            os.close(master_fd)
        except OSError:
            pass
        master_fd = None

        # Check morgue for outcome
        morgue = find_morgue(debug_dir)
        if morgue:
            info = parse_morgue(morgue)
            outcome = info.get("outcome", "UNKNOWN").lower()
            if outcome == "win":
                return "win", None
            elif outcome == "quit":
                return "quit", None
            else:
                return "death", None

        return "unknown", None

    except Exception as e:
        log(f"  EXCEPTION: {e}")
        return "error", None

    finally:
        if master_fd is not None:
            try:
                os.close(master_fd)
            except OSError:
                pass


# --- Main workflow -----------------------------------------------------------

def run_debug_session(seed, save_interval, max_time, max_turns, debug_dir,
                      verbose=False, visual="none"):
    """Run a full debug session: play game with periodic saves."""
    debug_dir.mkdir(parents=True, exist_ok=True)
    (debug_dir / "seed.txt").write_text(str(seed))
    (debug_dir / "player.txt").write_text(PLAYER_NAME)

    # Point decision log and morgue output at the debug dir
    rc_path = generate_debug_rc(save_interval, max_time=max_time,
                                max_turns=max_turns,
                                decision_log_dir=str(debug_dir),
                                verbose=verbose, visual=visual)
    session_start = time.time()
    total_saves = 0
    last_backup_turn = 0

    log(f"Starting debug session: seed={seed} interval={save_interval} "
        f"max_time={max_time} max_turns={max_turns}")
    log(f"Output dir: {debug_dir}")

    # Track which turn files we've already seen so we only log new ones
    seen_turn_files = set()

    # Checkpoint callback: called when save file mtime changes (non-exiting save)
    # The C++ checkpoint code writes turn-NNNNN.cs files into saves/.
    def handle_checkpoint(d):
        nonlocal total_saves, last_backup_turn
        saves_dir = d / "saves"
        for tf in sorted(saves_dir.glob("turn-*.cs")):
            if tf.name in seen_turn_files:
                continue
            seen_turn_files.add(tf.name)
            total_saves += 1
            m = re.match(r"turn-(\d+)\.cs", tf.name)
            turn_num = int(m.group(1)) if m else total_saves * save_interval
            last_backup_turn = turn_num
            log(f"  Saved checkpoint: {tf.name} "
                f"({tf.stat().st_size} bytes)")

    try:
        is_restore = save_file_path(debug_dir).exists()
        if is_restore:
            log(f"Resuming from save ({save_file_path(debug_dir).stat().st_size} bytes)...")
        else:
            log(f"Starting new game with seed {seed}...")

        runner = run_game_terminal if visual == "watch" else run_game
        exit_reason, _ = runner(
            seed, rc_path, debug_dir, is_restore=is_restore,
            on_checkpoint=handle_checkpoint, max_time=max_time,
            session_start=session_start)

        # --- Report results ---
        elapsed = time.time() - session_start

        # Find morgue from the actual game ending (now in debug_dir)
        morgue = find_morgue(debug_dir)
        info = parse_morgue(morgue) if morgue else {}

        # Only use morgue info if the game actually ended (not timeout)
        if exit_reason == "timeout":
            info = {}

        # Write TURN-LIMIT reason if game quit at max turns
        if (exit_reason == "quit" and max_turns > 0
                and info.get("turns", 0) >= max_turns):
            (debug_dir / "reason.txt").write_text(
                f"TURN-LIMIT\nturn {info['turns']} of {max_turns}\n")

        # Rename morgue to a stable name for easy access
        if morgue and exit_reason != "timeout" and morgue.name != "morgue.txt":
            morgue.rename(debug_dir / "morgue.txt")

        log("")
        log("=" * 60)
        log(f"Game ended: {exit_reason.upper()}")
        if info:
            if info.get("turns"):
                log(f"  Turns: {info['turns']}")
            if info.get("xl"):
                log(f"  XL: {info['xl']}")
            if info.get("location"):
                log(f"  Location: {info['location']}")
            if info.get("killer"):
                log(f"  Killer: {info['killer']}")
            if info.get("death_line"):
                log(f"  Death: {info['death_line']}")
            if info.get("hp_at_death") is not None:
                log(f"  HP: {info['hp_at_death']}/{info.get('max_hp', '?')}")
        if exit_reason == "timeout":
            log(f"  Reached ~turn {last_backup_turn} before timeout")
        log(f"  Checkpoints: {total_saves}")
        if total_saves > 0:
            # List available backups
            backups = sorted((debug_dir / "saves").glob("turn-*.cs"))
            if backups:
                log(f"  Available restores: {backups[0].stem} ... "
                    f"{backups[-1].stem}")
                if info.get("turns") and last_backup_turn > 0:
                    death_turn = info["turns"]
                    # Find closest backup before death
                    best = None
                    for b in backups:
                        m = re.match(r"turn-(\d+)", b.stem)
                        if m:
                            t = int(m.group(1))
                            if t <= death_turn:
                                best = t
                    if best is not None:
                        log(f"  Closest backup before death: turn-{best:05d} "
                            f"({death_turn - best} turns before death)")
                        log(f"  To restore: python3 claude/debug-seed.py "
                            f"--restore {best} --from {debug_dir.name}")
        log(f"  Wall time: {elapsed:.0f}s")
        log(f"  Output dir: {debug_dir}")
        decisions_log = debug_dir / f"qw_decisions_{PLAYER_NAME}.log"
        if decisions_log.exists():
            lines = decisions_log.read_text(errors="replace").strip().split("\n")
            log(f"  Decision log: {decisions_log} ({len(lines)} lines)")
        log("=" * 60)

    finally:
        # RC and its .persist file live in the session dir — no cleanup needed.
        pass


def make_session_id(seed):
    """Generate a unique session UUID and derived names.

    Returns (dir_name, player_name, short_uuid).
    Dir format: YYYY-MM-DD-HH-MM-seed-<seed>-uuid-<uuid8>
    Player name format: <uuid8>-<seed>
    """
    timestamp = time.strftime("%Y-%m-%d-%H-%M")
    short_uuid = uuid.uuid4().hex[:8]
    dir_name = f"{timestamp}-seed-{seed}-uuid-{short_uuid}"
    player_name = f"{short_uuid}-{seed}"
    return dir_name, player_name, short_uuid


def find_backup(source_dir, restore_turn):
    """Find a checkpoint save file in the source directory's saves/."""
    saves_dir = source_dir / "saves"
    backup_path = saves_dir / f"turn-{restore_turn:05d}.cs"
    if backup_path.exists():
        return backup_path
    # Try finding with different zero-padding
    candidates = list(saves_dir.glob(f"turn-*{restore_turn}.cs"))
    if candidates:
        return candidates[0]
    # Fall back to session root for old-format dirs
    backup_path = source_dir / f"turn-{restore_turn:05d}.cs"
    if backup_path.exists():
        return backup_path
    return None


def restore_save(source_dir, restore_turn, target_dir):
    """Copy a checkpoint save from source_dir into the target session's saves."""
    backup_path = find_backup(source_dir, restore_turn)
    if not backup_path:
        log(f"ERROR: Backup not found for turn {restore_turn} in {source_dir}")
        log("Available backups:")
        for b in sorted((source_dir / "saves").glob("turn-*.cs")):
            log(f"  {b.name}")
        sys.exit(1)

    log(f"Restoring {backup_path.name} from {source_dir.name}...")

    # Place the backup into the target session's save slot
    target_save = save_file_path(target_dir)
    target_save.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(str(backup_path), str(target_save))
    log(f"Restored save: {target_save} ({target_save.stat().st_size} bytes)")


# --- Entry point -------------------------------------------------------------

def signal_handler(signum, frame):
    log("Interrupted, cleaning up...")
    # Try to kill any crawl processes we started
    try:
        subprocess.run(
            ["pkill", "-f", f"-name {PLAYER_NAME}"],
            capture_output=True, timeout=5,
        )
    except Exception:
        pass
    sys.exit(1)


def main():
    parser = argparse.ArgumentParser(
        description="Save/restore debugging tool for qw DCSS bot",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""Examples:
  # Fresh run with seed 42
  python3 claude/debug-seed.py --seed 42

  # With saves and verbose logging
  python3 claude/debug-seed.py --seed 42 --save-interval 200 --verbose

  # Restore from turn 600 (seed read from session's seed.txt)
  python3 claude/debug-seed.py --restore 600 --from 2026-03-22-10-30-seed-42-uuid-a1b2c3d4
""",
    )
    parser.add_argument(
        "--seed", type=int, default=None, help="Game seed (required for fresh, read from seed.txt on restore)"
    )
    parser.add_argument(
        "--save-interval",
        type=int,
        default=0,
        help="Save every N turns (default: 0 = no saves)",
    )
    parser.add_argument(
        "--max-time",
        type=int,
        default=0,
        help="Max real-time seconds per game (default: 0=no limit)",
    )
    parser.add_argument(
        "--max-turns",
        type=int,
        default=0,
        help="Quit after this many game turns (deterministic, 0=no limit)",
    )
    parser.add_argument(
        "--verbose",
        action="store_true",
        help="Enable all debug log channels",
    )
    parser.add_argument(
        "--visual",
        type=str,
        nargs="?",
        const="true",
        default="none",
        choices=["none", "true", "watch"],
        help="Visual mode: none (default), true (render), watch (render + terminal delays)",
    )
    parser.add_argument(
        "--restore",
        type=int,
        default=None,
        metavar="TURN",
        help="Restore from checkpoint at this turn and re-run",
    )
    parser.add_argument(
        "--from", dest="from_dir",
        type=str,
        default=None,
        metavar="DIR",
        help="Session dir containing the checkpoint (required with --restore)",
    )
    args = parser.parse_args()

    if args.restore is not None and not args.from_dir:
        parser.error("--restore requires --from <session_dir>")

    if args.max_time and args.visual != "none":
        parser.error("--max-time cannot be used with --visual (only headless mode)")

    # Resolve seed and player name.
    # On restore: read from source session's seed.txt/player.txt.
    # On fresh: generate new player name from UUID.
    seed = args.seed
    restored_player = None
    if args.restore is not None:
        source_dir = Path(args.from_dir)
        if not source_dir.is_absolute():
            source_dir = SESSIONS_DIR / source_dir
        if seed is None:
            seed_file = source_dir / "seed.txt"
            if not seed_file.exists():
                parser.error(f"No --seed given and no seed.txt in {source_dir}")
            seed = int(seed_file.read_text().strip())
            log(f"Read seed {seed} from {seed_file}")
        player_file = source_dir / "player.txt"
        if player_file.exists():
            restored_player = player_file.read_text().strip()
            log(f"Reusing player name: {restored_player}")
    if seed is None:
        parser.error("--seed is required for fresh runs")

    # Generate session ID; reuse original player name on restore
    dir_name, player_name, _ = make_session_id(seed)
    global PLAYER_NAME
    PLAYER_NAME = restored_player or player_name

    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)

    # Every run (fresh or restore) gets its own unique directory
    debug_dir = SESSIONS_DIR / dir_name

    # For restore: copy the checkpoint save into the session dir before starting.
    # After this, run_debug_session behaves identically for fresh and restore.
    if args.restore is not None:
        source_dir = Path(args.from_dir)
        if not source_dir.is_absolute():
            source_dir = SESSIONS_DIR / source_dir
        if not source_dir.exists():
            log(f"ERROR: Source dir not found: {source_dir}")
            sys.exit(1)
        restore_save(source_dir, args.restore, debug_dir)

    run_debug_session(
        seed, args.save_interval, args.max_time, args.max_turns, debug_dir,
        verbose=args.verbose, visual=args.visual,
    )


if __name__ == "__main__":
    main()
