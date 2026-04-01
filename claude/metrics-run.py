#!/usr/bin/env python3
"""Run a full metrics batch: clean, run 300 games, analyze.

Usage:
    python3 claude/metrics-run.py
    python3 claude/metrics-run.py --note "baseline before refactor"
"""

import argparse
import os
import signal
import shutil
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

QW_DIR = Path(__file__).resolve().parent.parent
RUNS_DIR = QW_DIR / "debug-seed-runs"


def main():
    parser = argparse.ArgumentParser(description="Run a full metrics batch")
    parser.add_argument("--note", type=str, default=None,
                        help="Optional note appended to results filename")
    args = parser.parse_args()

    start_time = time.monotonic()
    start_dt = datetime.now()
    print(f"Batch started: {start_dt.strftime('%Y-%m-%d %H:%M:%S')}")

    # 1. Clean previous runs
    if RUNS_DIR.exists():
        shutil.rmtree(RUNS_DIR)
        print(f"Cleaned {RUNS_DIR}")
    RUNS_DIR.mkdir()

    # 2. Build qw.lua
    subprocess.run(["./make-qw.sh"], cwd=QW_DIR, check=True)

    # 3. Run 300 games
    #    --max-turns 30000: game-level turn limit
    #    --max-time 1200: 20-min wall-clock per game (kills stuck games)
    run_proc = subprocess.Popen([
        sys.executable, str(QW_DIR / "claude" / "run-parallel.py"),
        "--total", "300",
        "--parallel", "16",
        "--max-turns", "30000",
        "--max-time", "1200",
        "--no-progress",
    ], cwd=QW_DIR, preexec_fn=os.setpgrp)

    try:
        run_proc.wait()
    except KeyboardInterrupt:
        print("\nInterrupted, killing batch...")
        try:
            os.killpg(run_proc.pid, signal.SIGKILL)
        except OSError:
            run_proc.kill()
        run_proc.wait()
        sys.exit(1)

    end_dt = datetime.now()
    elapsed_min = (time.monotonic() - start_time) / 60
    print(f"\nBatch ended: {end_dt.strftime('%Y-%m-%d %H:%M:%S')}")
    print(f"Total elapsed: {elapsed_min:.1f} minutes")

    # 4. Analyze with timestamped name
    commit = subprocess.check_output(
        ["git", "rev-parse", "--short", "HEAD"],
        cwd=QW_DIR,
    ).decode().strip()

    timestamp = start_dt.strftime("%Y-%m-%d-%H-%M")
    name = f"{timestamp}-{commit}"
    if args.note:
        # Sanitize note for filename
        safe_note = args.note.replace(" ", "-").replace("/", "-")
        name = f"{name}-{safe_note}"

    subprocess.run([
        sys.executable, str(QW_DIR / "claude" / "analyze-runs.py"),
        "--name", name,
    ], cwd=QW_DIR)


if __name__ == "__main__":
    main()
