#!/usr/bin/env python3
"""Build crawl with maximum performance for qw bot runs.

Uses -O3, LTO, PGO (profile-guided optimization), and disables assertions
and debug scans. The result is ~1.4x faster than the default `make` build.

Usage:
    python3 claude/crawl-build-optimised.py

Prerequisites:
    - crawl repo at ../crawl (sibling of qw repo)
    - libjemalloc2 installed (used at runtime, not build time)
"""

import os
import subprocess
import sys
from pathlib import Path

CRAWL_DIR = Path(os.environ.get("CRAWL_DIR", "/home/agent/repos/crawl/crawl-ref/source"))
QW_DIR = Path(__file__).resolve().parent.parent
MAKE_OPTS = "NOASSERTS=1 BUILD_LUA=yes"
BASE_OPT = "-O3 -march=native -flto -ffast-math"


def run(cmd, **kwargs):
    print(f"  $ {cmd}", flush=True)
    subprocess.run(cmd, shell=True, check=True, **kwargs)


def clean(pattern):
    """Delete files matching pattern under CRAWL_DIR."""
    for f in CRAWL_DIR.rglob(pattern):
        f.unlink()


def main():
    if not (CRAWL_DIR / "Makefile").exists():
        print(f"ERROR: crawl source not found at {CRAWL_DIR}")
        print("Set CRAWL_DIR to point to crawl-ref/source/")
        sys.exit(1)

    nproc = os.cpu_count() or 4

    # Stage 1: instrumented build
    print("=== PGO build: stage 1 (instrumented) ===", flush=True)
    clean("*.gcda")
    clean("*.o")
    run(f"make -j{nproc} {MAKE_OPTS} "
        f'CFOPTIMIZE="{BASE_OPT} -fprofile-generate" '
        f'LDFLAGS="-fprofile-generate"',
        cwd=CRAWL_DIR)

    print("\n=== Building qw.lua ===", flush=True)
    run("./make-qw.sh", cwd=QW_DIR)

    # Stage 2: training run
    print("\n=== PGO build: training run ===", flush=True)
    run(f"{sys.executable} {QW_DIR / 'claude' / 'debug-seed.py'} "
        f"--seed 42 --max-time 60")

    # Stage 3: optimised build
    print("\n=== PGO build: stage 2 (optimised) ===", flush=True)
    clean("*.o")
    run(f"make -j{nproc} {MAKE_OPTS} "
        f'CFOPTIMIZE="{BASE_OPT} -fprofile-use -fprofile-correction" '
        f'LDFLAGS="-fprofile-use -fprofile-correction"',
        cwd=CRAWL_DIR)

    # Report
    crawl_bin = CRAWL_DIR / "crawl"
    print(f"\nDone. Binary: {crawl_bin}", flush=True)
    run(f'strings "{crawl_bin}" | grep "^CFLAGS"')
    run(f'ls -lh "{crawl_bin}"')


if __name__ == "__main__":
    main()
