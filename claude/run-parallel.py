#!/usr/bin/env python3
"""Parallel batch runner for qw DCSS bot games.

Runs a total of N games with up to P parallel processes, using debug-seed.py.
Seeds are sequential (1..N) by default, or configurable with --start-seed.

Usage:
    # 100 games, 8 at a time, no time limit
    python3 claude/run-parallel.py --total 100 --parallel 8

    # 30 games, all parallel, 5 min limit per game
    python3 claude/run-parallel.py --total 30 --parallel 30 --max-time 300

    # With verbose logging and saves
    python3 claude/run-parallel.py --total 30 --verbose --save-interval 200
"""

import argparse
import os
import re
import signal
import subprocess
import sys
import time

from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from threading import Lock, Event

# --- Configuration -----------------------------------------------------------

CRAWL_DIR = Path("/home/agent/repos/crawl/crawl-ref/source")

QW_DIR = Path(
    subprocess.check_output(
        ["git", "rev-parse", "--show-toplevel"],
        cwd=Path(__file__).resolve().parent,
    )
    .decode()
    .strip()
)
SESSIONS_DIR = QW_DIR / "debug-seed-runs"

SCRIPT_PATH = Path(__file__).resolve().parent / "debug-seed.py"

_print_lock = Lock()
_all_procs = []
_all_procs_lock = Lock()
_shutdown = Event()

# Live tracking: seed -> {pid, session_dir, start_time, status}
_live = {}
_live_lock = Lock()


def _safe_print(msg):
    with _print_lock:
        print(msg, flush=True)


# --- Worker ------------------------------------------------------------------

def run_worker(seed, save_interval, max_time, max_turns=0, verbose=False,
               visual="none"):
    """Run a single debug-seed.py process. Returns (seed, outcome, session_dir, stdout)."""
    cmd = [
        sys.executable, str(SCRIPT_PATH),
        "--seed", str(seed),
        "--save-interval", str(save_interval),
    ]
    if max_time > 0:
        cmd.extend(["--max-time", str(max_time)])
    if max_turns > 0:
        cmd.extend(["--max-turns", str(max_turns)])
    if verbose:
        cmd.append("--verbose")
    if visual != "none":
        cmd.extend(["--visual", visual])

    try:
        proc = subprocess.Popen(
            cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True, cwd=QW_DIR,
            preexec_fn=os.setpgrp)

        with _all_procs_lock:
            _all_procs.append(proc)

        # Extract session dir from early output
        session_dir = None
        lines = []
        timeout = max_time + 300 if max_time > 0 else None  # max_turns handled by game

        stdout, _ = proc.communicate(timeout=timeout)
        lines = stdout.split("\n")

        for line in lines:
            m = re.search(r"Output dir: (.+)", line)
            if m:
                session_dir = m.group(1).strip()
                break

        # Update live tracking
        with _live_lock:
            _live[seed] = {"status": "done", "session_dir": session_dir}

        # Parse outcome
        outcome = "UNKNOWN"
        if "Game ended: DEATH" in stdout:
            outcome = "DEATH"
        elif "Game ended: TIMEOUT" in stdout:
            outcome = "TIMEOUT"
        elif "Game ended: WIN" in stdout:
            outcome = "WIN"
        elif "Game ended: QUIT" in stdout:
            outcome = "QUIT"

        return (seed, outcome, session_dir, stdout)

    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except OSError:
            proc.kill()
        proc.wait()
        return (seed, "HUNG", None, "")
    except Exception as e:
        return (seed, "ERROR", None, str(e))


# --- Result parsing ----------------------------------------------------------

def parse_session_result(session_dir):
    """Extract game details from a session directory."""
    if not session_dir:
        return {}
    session_path = Path(session_dir)
    info = {}

    # Find morgue file
    morgue = session_path / "morgue.txt"
    if not morgue.exists():
        morgues = list(session_path.glob("morgue-*.txt"))
        if morgues:
            morgue = morgues[0]
    if not morgue.exists():
        for f in session_path.glob("*.txt"):
            if not f.name.startswith("qw_decisions") and f.name != "debug.log":
                morgue = f
                break

    if morgue.exists():
        try:
            content = morgue.read_text(errors="replace")
        except Exception:
            return info

        # Turns from "Turns: NNNN" line (more reliable than game-lasted)
        m = re.search(r"Turns:\s*(\d+)", content[:500])
        if m:
            info["turns"] = int(m.group(1))

        # Also try "The game lasted ... (NNNN turns)"
        if "turns" not in info:
            m = re.search(r"\((\d+) turns\)", content[:500])
            if m:
                info["turns"] = int(m.group(1))

        m = re.search(r"XL:\s+(\d+)", content[:500])
        if m:
            info["xl"] = int(m.group(1))

        # Location from place line
        for pat in [r"You (?:are|were) on level (\d+) of the (.+?)\.",
                     r"Place:\s*(.+)"]:
            m = re.search(pat, content[:1500])
            if m:
                info["location"] = m.group(0).split(":")[-1].strip() if "Place" in pat else f"{m.group(2)}:{m.group(1)}"
                break

        # Killer
        for line in content[:2000].split("\n"):
            m = re.search(r"(?:Slain|Mangled|Killed|Shot|Constricted).*?by (.+?)(?:\s*\(\d+ damage\))?$", line.strip())
            if m:
                info["killer"] = m.group(1).strip()
                break

    return info


def format_result_line(seed, total, outcome, session_dir):
    info = parse_session_result(session_dir)
    parts = []
    if info.get("xl"):
        parts.append(f"XL{info['xl']}")
    if info.get("turns"):
        parts.append(f"t{info['turns']}")
    if info.get("location"):
        parts.append(info["location"])
    if info.get("killer"):
        parts.append(info["killer"])
    if session_dir:
        parts.append(Path(session_dir).name)
    detail = f" {' '.join(parts)}" if parts else ""
    return f"  seed {seed:>4}: {outcome:<8}{detail}"


# --- Live monitoring ---------------------------------------------------------

def monitor_loop(total_seeds, start_seed, poll_interval):
    """Periodically show status of running games."""
    while not _shutdown.is_set():
        _shutdown.wait(poll_interval)
        if _shutdown.is_set():
            break

        with _live_lock:
            done = sum(1 for v in _live.values() if v.get("status") == "done")
            running = total_seeds - done

        if running == 0:
            break

        # Check alive processes
        alive_info = []
        with _all_procs_lock:
            for proc in _all_procs:
                if proc.poll() is None:
                    alive_info.append(proc.pid)

        _safe_print(f"\n--- {time.strftime('%H:%M:%S')} | "
                     f"{done}/{total_seeds} done, {len(alive_info)} running ---")


# --- Main --------------------------------------------------------------------

def get_commit_hash():
    try:
        return subprocess.check_output(
            ["git", "rev-parse", "--short", "HEAD"], cwd=QW_DIR
        ).decode().strip()
    except Exception:
        return "unknown"


def signal_handler(signum, frame):
    _shutdown.set()
    with _all_procs_lock:
        for proc in _all_procs:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except Exception:
                try:
                    proc.kill()
                except Exception:
                    pass
    sys.exit(1)


def main():
    parser = argparse.ArgumentParser(
        description="Run qw games in parallel via debug-seed.py",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""Examples:
  # 100 games, 8 parallel (fast by default)
  python3 claude/run-parallel.py --total 100 --parallel 8

  # Specific seeds with verbose logging and saves
  python3 claude/run-parallel.py --seeds 15,18,44,73,81 --verbose --save-interval 200

  # Seeds 50-149, with saves every 200 turns
  python3 claude/run-parallel.py --total 100 --parallel 8 --start-seed 50 --save-interval 200
""",
    )
    parser.add_argument("--total", "-n", type=int, default=None,
                        help="Total number of games (default: 30, ignored with --seeds)")
    parser.add_argument("--seeds", type=str, default=None,
                        help="Comma-separated list of specific seeds to run")
    parser.add_argument("--parallel", "-p", type=int, default=None,
                        help="Max parallel processes (default: nproc)")
    parser.add_argument("--max-time", type=int, default=0,
                        help="Max seconds per game (default: 0 = no limit)")
    parser.add_argument("--max-turns", type=int, default=0,
                        help="Quit after this many game turns (deterministic, 0=no limit)")
    parser.add_argument("--save-interval", type=int, default=0,
                        help="Save checkpoint interval (default: 0 = no saves)")
    parser.add_argument("--verbose", action="store_true",
                        help="Enable all debug log channels")
    parser.add_argument("--visual", type=str, nargs="?", const="true",
                        default="none", choices=["none", "true", "watch"],
                        help="Visual mode: none (default), true (render), watch (terminal delays)")
    parser.add_argument("--start-seed", type=int, default=1,
                        help="First seed number (default: 1)")
    parser.add_argument("--monitor", type=int, default=30,
                        help="Status poll interval in seconds (default: 30)")
    parser.add_argument("--progress", action=argparse.BooleanOptionalAction,
                        default=True,
                        help="Show per-game results and monitor status (default: on)")
    args = parser.parse_args()

    parallel = args.parallel or os.cpu_count() or 4

    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)

    commit = get_commit_hash()

    if args.seeds:
        seeds = [int(s.strip()) for s in args.seeds.split(",")]
    else:
        total = args.total or 30
        seeds = list(range(args.start_seed, args.start_seed + total))

    total = len(seeds)
    seed_desc = ",".join(str(s) for s in seeds) if len(seeds) <= 10 else f"{seeds[0]}-{seeds[-1]}"
    print(f"=== qw parallel: {total} games, {parallel} parallel, "
          f"seeds [{seed_desc}] ===")
    print(f"Commit: {commit} | max-time: {args.max_time or 'none'} | "
          f"max-turns: {args.max_turns or 'none'} | "
          f"verbose: {args.verbose} | save-interval: {args.save_interval}")
    print()

    start_time = time.time()
    results = []

    # Start monitor thread
    import threading
    if args.progress:
        monitor = threading.Thread(target=monitor_loop,
                                    args=(total, seeds[0], args.monitor),
                                    daemon=True)
        monitor.start()

    with ThreadPoolExecutor(max_workers=parallel) as executor:
        futures = {}
        for seed in seeds:
            future = executor.submit(
                run_worker, seed, args.save_interval, args.max_time, args.max_turns, args.verbose, args.visual)
            futures[future] = seed
            time.sleep(0.2)  # stagger launches

        for future in as_completed(futures):
            try:
                seed, outcome, session_dir, stdout = future.result()
            except Exception as e:
                seed = futures[future]
                outcome, session_dir, stdout = "ERROR", None, str(e)
            results.append((seed, outcome, session_dir, stdout))
            if args.progress:
                line = format_result_line(seed, total, outcome, session_dir)
                _safe_print(line)

    _shutdown.set()
    results.sort(key=lambda r: r[0])
    elapsed = time.time() - start_time

    # Summary
    counts = {}
    total_turns = 0
    max_xl = 0
    for seed, outcome, session_dir, _ in results:
        counts[outcome] = counts.get(outcome, 0) + 1
        info = parse_session_result(session_dir)
        total_turns += info.get("turns", 0)
        max_xl = max(max_xl, info.get("xl", 0))

    print(f"\n{'='*60}")
    labels = {"WIN": "wins", "DEATH": "deaths", "TIMEOUT": "timeouts",
              "QUIT": "quits", "HUNG": "hung", "ERROR": "errors",
              "UNKNOWN": "unknown"}
    parts = [f"{n} {labels.get(k, k)}" for k, n in sorted(counts.items()) if n > 0]
    print(f"Results: {', '.join(parts)}")
    print(f"Total turns: {total_turns:,} | Max XL: {max_xl}")
    print(f"Wall time: {elapsed:.0f}s | "
          f"Throughput: {total_turns/max(elapsed,1):.0f} turns/sec aggregate")


if __name__ == "__main__":
    main()
