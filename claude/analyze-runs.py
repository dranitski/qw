#!/usr/bin/env python3
"""Analyze qw bot game results from debug-seed-runs.

Reads morgue files and decision logs from session directories,
extracts metrics, and prints a comprehensive analysis report.

Usage:
    # Analyze all sessions in debug-seed-runs/
    python3 claude/analyze-runs.py

    # Analyze specific sessions
    python3 claude/analyze-runs.py debug-seed-runs/2026-03-26-*

    # Output as JSON
    python3 claude/analyze-runs.py --json
"""

import argparse
import json
import os
import re
import sys
from collections import defaultdict
from pathlib import Path

QW_DIR = Path(__file__).resolve().parent.parent
DEFAULT_RUNS_DIR = QW_DIR / "debug-seed-runs"


# --- Morgue parsing ----------------------------------------------------------

def parse_morgue(path):
    """Extract all metrics from a morgue file."""
    text = path.read_text(errors="replace")
    g = {}

    # Seed
    m = re.search(r"Game seed:\s*(\d+)", text[:500])
    if m:
        g["seed"] = int(m.group(1))

    # Score — first number on the character summary line: "168 qw the Chopper ..."
    m = re.search(r"^(\d+) \S+ the ", text, re.MULTILINE)
    if m:
        g["score"] = int(m.group(1))

    # Outcome: WIN and QUIT have unique phrasing; everything else is DEATH
    if "escaped with the Orb" in text[:800]:
        g["outcome"] = "WIN"
    elif "Quit the game" in text[:800] or "quit the game" in text[:800]:
        g["outcome"] = "QUIT"
    else:
        g["outcome"] = "DEATH"

    # XL
    m = re.search(r"XL:\s+(\d+)", text)
    if m:
        g["xl"] = int(m.group(1))

    # Turns and Time from the summary line: "Turns: 3612, Time: 00:02:43"
    m = re.search(r"Turns:\s*(\d+),\s*Time:\s*(\d+):(\d+):(\d+)", text)
    if m:
        g["turns"] = int(m.group(1))
        g["game_time_s"] = int(m.group(2)) * 3600 + int(m.group(3)) * 60 + int(m.group(4))
        if g["game_time_s"] > 0:
            g["turns_per_sec"] = round(g["turns"] / g["game_time_s"], 1)

    # HP at death
    m = re.search(r"\(level \d+, (-?\d+)/(\d+) HPs?\)", text[:500])
    if m:
        g["hp"] = int(m.group(1))
        g["max_hp"] = int(m.group(2))

    # Killer — DCSS has many death verbs, so match the line after the title line
    # Look for patterns like "Slain by X", "Demolished by X", "Frozen to death by X", etc.
    m = re.search(r"(?:Slain by|Mangled by|Annihilated by|Demolished by|Frozen to death by|Constricted to death by|Splashed by|Shot with .* by|Killed from afar by|Killed by)\s+(.+?)(?:\n|$)", text[:800])
    if m:
        killer = m.group(1).strip()
        # Clean up: remove "... on level X of the Y" suffix and trailing damage
        killer = re.sub(r"\s*\.\.\..*", "", killer)
        killer = re.sub(r"\s*\(\d+ damage\)$", "", killer)
        g["killer"] = killer

    # Location at death
    m = re.search(r"on level (\d+) of the (.+?)\.", text[:800])
    if m:
        g["death_depth"] = int(m.group(1))
        g["death_branch"] = m.group(2).strip()
        g["death_location"] = f"{g['death_branch']}:{g['death_depth']}"

    # Gold
    m = re.search(r"collected (\d+) gold", text)
    if m:
        g["gold_collected"] = int(m.group(1))
    m = re.search(r"spent (\d+) gold", text)
    if m:
        g["gold_spent"] = int(m.group(1))

    # Branches visited
    m = re.search(r"visited (\d+) branch", text)
    if m:
        g["branches_visited"] = int(m.group(1))

    # Kills
    m = re.search(r"(\d+) creatures? vanquished", text)
    if m:
        g["kills"] = int(m.group(1))

    # Runes — count from Notes section
    runes = re.findall(r"Found .*?rune of Zot|Acquired the .* rune|pick up the.*rune", text)
    g["runes"] = len(runes)

    # Turns per branch from Notes section
    # Each note line: "  1234 | D:3      | some note"
    branch_turns = {}
    last_branch = None
    last_turn = 0
    for m in re.finditer(r"^\s*(\d+)\s*\|\s*(\S+)\s*\|", text, re.MULTILINE):
        turn = int(m.group(1))
        place = m.group(2)
        # Normalize: "D:3" -> "D", "Lair:2" -> "Lair"
        branch = place.split(":")[0] if ":" in place else place
        if branch != last_branch and last_branch is not None:
            # Attribute turns since last transition to the previous branch
            branch_turns[last_branch] = branch_turns.get(last_branch, 0) + (turn - last_turn)
        if branch != last_branch:
            last_branch = branch
            last_turn = turn
    # Final branch gets remaining turns
    if last_branch and g.get("turns"):
        branch_turns[last_branch] = branch_turns.get(last_branch, 0) + (g["turns"] - last_turn)
    if branch_turns:
        g["branch_turns"] = branch_turns

    # Deepest level per branch from Notes
    branch_depth = {}
    for m in re.finditer(r"^\s*\d+\s*\|\s*(\w+):(\d+)\s*\|", text, re.MULTILINE):
        branch = m.group(1)
        depth = int(m.group(2))
        branch_depth[branch] = max(branch_depth.get(branch, 0), depth)
    if branch_depth:
        g["branch_depth"] = branch_depth

    # God — "God:    Okawaru [*****.]" can appear mid-line or on its own line
    m = re.search(r"God:\s+(\S+(?:\s+\S+)*?)\s*\[", text)
    if m:
        g["god"] = m.group(1).strip()
    else:
        g["god"] = "No God"

    # Zot damage — permanent MHP reduction from Zot clock
    # Notes format: "Touched by the power of Zot (MHP 86 -> 69)"
    zot_damage = 0
    for m in re.finditer(r"Touched by the power of Zot \(MHP (\d+) -> (\d+)\)", text):
        zot_damage += int(m.group(1)) - int(m.group(2))
    g["zot_damage"] = zot_damage

    return g


# --- Decision log parsing ----------------------------------------------------

def parse_stats(path):
    """Read qw_stats.txt dumped by the bot at game end."""
    text = path.read_text(errors="replace")
    d = {}
    for line in text.strip().split("\n"):
        if "=" in line:
            k, v = line.split("=", 1)
            try:
                d[k.strip()] = int(v.strip())
            except ValueError:
                d[k.strip()] = v.strip()
    return d


# --- Session parsing ----------------------------------------------------------

def parse_session(session_dir):
    """Parse a single session directory."""
    session_dir = Path(session_dir)
    game = {"session": session_dir.name}

    # Find morgue
    morgues = list(session_dir.glob("morgue.txt")) + list(session_dir.glob("morgue-*.txt"))
    # Filter out .lst files
    morgues = [m for m in morgues if m.suffix == ".txt"]
    if morgues:
        game.update(parse_morgue(morgues[0]))

    # Read bot stats (dumped by qw at game end)
    stats_file = session_dir / "qw_stats.txt"
    if stats_file.exists():
        game.update(parse_stats(stats_file))

    # Read reason.txt if it exists (authoritative exit reason)
    reason_file = session_dir / "reason.txt"
    if reason_file.exists():
        try:
            lines = reason_file.read_text().strip().split("\n")
            reason = lines[0]
            detail = lines[1] if len(lines) > 1 else ""
            if reason == "ERROR":
                game["outcome"] = "ERROR"
                game["error_msg"] = detail
            elif reason == "TURN-LIMIT":
                game["outcome"] = "TURN-LIMIT"
            elif reason == "TIMEOUT":
                game["outcome"] = "TIMEOUT"
        except OSError:
            pass

    # Read seed from seed.txt if not in morgue
    if "seed" not in game:
        seed_file = session_dir / "seed.txt"
        if seed_file.exists():
            try:
                game["seed"] = int(seed_file.read_text().strip())
            except ValueError:
                pass

    return game


# --- Reporting ----------------------------------------------------------------

def print_report(games, title=None):
    """Print a comprehensive analysis report."""
    if not games:
        print("No games found.")
        return

    total = len(games)
    print(f"\n{'='*70}")
    header = f"QW BATCH ANALYSIS — {total} games"
    if title:
        header += f" — {title}"
    print(header)
    print(f"{'='*70}\n")

    # --- Outcomes ---
    outcomes = defaultdict(int)
    for g in games:
        outcomes[g.get("outcome", "UNKNOWN")] += 1

    print("OUTCOMES")
    for outcome in ["WIN", "DEATH", "TURN-LIMIT", "TIMEOUT", "ERROR", "UNKNOWN"]:
        count = outcomes.get(outcome, 0)
        if count:
            pct = count / total * 100
            print(f"  {outcome:10s} {count:4d}  ({pct:.0f}%)")
    if outcomes.get("ERROR", 0):
        error_msgs = defaultdict(int)
        for g in games:
            if g.get("outcome") == "ERROR" and g.get("error_msg"):
                error_msgs[g["error_msg"][:80]] += 1
        for msg, cnt in sorted(error_msgs.items(), key=lambda x: -x[1])[:5]:
            print(f"    {cnt:4d}x {msg}")
    print()

    # --- Core metrics ---
    def stats(values, label):
        if not values:
            print(f"  {label:24s}  (no data)")
            return
        values = sorted(values)
        n = len(values)
        total = sum(values)
        mean = total / n
        median = values[n // 2]
        p90 = values[int(n * 0.9)]
        best = values[-1]
        print(f"  {label:24s}  mean={mean:8.1f}  median={median:8.1f}  p90={p90:8.1f}  best={best:8.1f}  total={round(total, 1):>10}")

    print("CORE METRICS")
    stats([g["score"] for g in games if "score" in g], "Score")
    stats([g["xl"] for g in games if "xl" in g], "XL")
    stats([g["turns"] for g in games if "turns" in g], "Turns")
    stats([g["game_time_s"] for g in games if "game_time_s" in g], "Time (s)")
    stats([g.get("turns_per_sec", 0) for g in games if g.get("turns_per_sec")], "Turns/sec")
    stats([g["kills"] for g in games if "kills" in g], "Kills")
    stats([g["runes"] for g in games if "runes" in g], "Runes")
    stats([g["gold_collected"] for g in games if "gold_collected" in g], "Gold collected")
    stats([g["gold_spent"] for g in games if "gold_spent" in g], "Gold spent")
    stats([g.get("zot_damage", 0) for g in games], "Zot damage")
    print()

    # --- Branch reach ---
    print("BRANCH REACH (% of games)")
    branch_reach = defaultdict(int)
    branch_max_depth = defaultdict(int)
    for g in games:
        for branch, depth in g.get("branch_depth", {}).items():
            branch_reach[branch] += 1
            branch_max_depth[branch] = max(branch_max_depth[branch], depth)
    for branch, count in sorted(branch_reach.items(), key=lambda x: -x[1]):
        pct = count / total * 100
        max_d = branch_max_depth[branch]
        print(f"  {branch:12s} {count:4d}  ({pct:5.1f}%)  deepest={max_d}")
    print()

    # --- Turns per branch ---
    print("TURNS PER BRANCH (mean, across games that visited)")
    branch_turn_totals = defaultdict(list)
    for g in games:
        for branch, turns in g.get("branch_turns", {}).items():
            branch_turn_totals[branch].append(turns)
    for branch, turns_list in sorted(branch_turn_totals.items(), key=lambda x: -sum(x[1])):
        mean = sum(turns_list) / len(turns_list)
        total_t = sum(turns_list)
        print(f"  {branch:12s} mean={mean:7.1f}  total={total_t:8d}  games={len(turns_list)}")
    print()

    # --- Top killers ---
    print("TOP KILLERS")
    killers = defaultdict(int)
    for g in games:
        if g.get("killer") and g.get("outcome") == "DEATH":
            killers[g["killer"]] += 1
    for killer, count in sorted(killers.items(), key=lambda x: (-x[1], x[0]))[:15]:
        pct = count / total * 100
        print(f"  {count:4d}  ({pct:4.1f}%)  {killer}")
    print()

    # --- Death locations ---
    print("DEATH LOCATIONS")
    death_locs = defaultdict(int)
    for g in games:
        loc = g.get("death_location")
        if loc and g.get("outcome") == "DEATH":
            death_locs[loc] += 1
    for loc, count in sorted(death_locs.items(), key=lambda x: -x[1])[:15]:
        print(f"  {count:4d}  {loc}")
    print()

    # --- QW internal metrics ---
    print("QW BOT METRICS (per game, from qw_stats.txt)")
    games_with_stats = [g for g in games if "stuck_turns" in g]
    if games_with_stats:
        stats([g["stuck_turns"] for g in games_with_stats], "Stuck turns")
        stats([g["flees"] for g in games_with_stats], "Flees")
        stats([g["teleports"] for g in games_with_stats], "Teleports")
        stats([g["berserks"] for g in games_with_stats], "Berserks")
        stats([g["heals"] for g in games_with_stats], "Heals")
        stats([g["stairdances"] for g in games_with_stats], "Stairdances")
        stats([g["purchases"] for g in games_with_stats], "Purchases")
        stats([g["explore_stuck"] for g in games_with_stats], "Explore stuck")
        stats([g.get("wanted_altars", 0) for g in games_with_stats], "Wanted altars")
    else:
        print("  (no qw_stats.txt files found — run games with current qw build)")
    print()

    # --- Per-game table ---
    print("PER-GAME RESULTS (sorted by score)")
    print(f"  {'Seed':>5s} {'Outcome':>10s} {'Score':>7s} {'XL':>3s} {'Turns':>7s} {'Time':>5s} {'T/s':>6s} {'Kills':>5s} {'Runes':>5s} {'Gold':>5s} {'Zot':>4s} {'Alt':>3s} {'God':>10s} {'Location':>12s} {'Killer'}")
    print(f"  {'─'*5} {'─'*10} {'─'*7} {'─'*3} {'─'*7} {'─'*5} {'─'*6} {'─'*5} {'─'*5} {'─'*5} {'─'*4} {'─'*3} {'─'*10} {'─'*12} {'─'*30}")
    for g in sorted(games, key=lambda x: (x.get("score", 0), x.get("seed", 0)), reverse=True):
        seed = g.get("seed", "?")
        outcome = g.get("outcome", "?")
        score = g.get("score", "?")
        xl = g.get("xl", "?")
        turns = g.get("turns", "?")
        time_s = g.get("game_time_s", "")
        tps = g.get("turns_per_sec", "")
        kills = g.get("kills", "?")
        runes = g.get("runes", 0)
        gold = g.get("gold_spent", "")
        zot = g.get("zot_damage", 0)
        zot_str = str(zot) if zot > 0 else ""
        altars = g.get("wanted_altars", "")
        alt_str = str(altars) if altars else ""
        god = g.get("god", "?")
        # Shorten god names for table
        god_short = god.replace("the Shining One", "TSO").replace("No God", "-")
        if len(god_short) > 10:
            god_short = god_short[:10]
        loc = g.get("death_location", "?")
        killer = g.get("killer", "")
        if outcome == "ERROR":
            killer = g.get("error_msg", "(error)")[:30]
        elif outcome == "TURN-LIMIT":
            killer = "(turn limit)"
        elif outcome == "TIMEOUT":
            killer = "(wall-clock timeout)"
        elif outcome == "QUIT":
            killer = g.get("error_msg", "(quit)")
        print(f"  {seed:>5} {outcome:>10s} {str(score):>7s} {str(xl):>3s} {str(turns):>7s} {str(time_s):>5s} {str(tps):>6s} {str(kills):>5s} {str(runes):>5s} {str(gold):>5s} {zot_str:>4s} {alt_str:>3s} {god_short:>10s} {str(loc):>12s} {killer[:30]}")
    print()


# --- Main ---------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="Analyze qw bot game results",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""Examples:
  python3 claude/analyze-runs.py --name baseline                  # analyze debug-seed-runs/
  python3 claude/analyze-runs.py --name baseline --dir path/to/   # analyze specific runs dir
  python3 claude/analyze-runs.py --name test --single path/to/s   # analyze one session
""",
    )
    parser.add_argument("--dir", type=str, default=None,
                        help="Directory containing session subdirs (default: debug-seed-runs/)")
    parser.add_argument("--single", type=str, default=None,
                        help="Single session directory to analyze")
    parser.add_argument("--name", type=str, required=True,
                        help="Name for output file: results-<NAME>.txt")
    parser.add_argument("--json", action="store_true",
                        help="Output raw game data as JSON")
    args = parser.parse_args()

    # Resolve session directories
    if args.single:
        session_dirs = [Path(args.single)]
        source_label = str(Path(args.single).resolve())
    elif args.dir:
        runs_dir = Path(args.dir)
        if not runs_dir.exists():
            print(f"Directory not found: {runs_dir}")
            sys.exit(1)
        session_dirs = sorted([
            d for d in runs_dir.iterdir()
            if d.is_dir() and not d.name.startswith(".")
        ])
        source_label = str(runs_dir.resolve())
    else:
        if not DEFAULT_RUNS_DIR.exists():
            print(f"No runs directory at {DEFAULT_RUNS_DIR}")
            sys.exit(1)
        session_dirs = sorted([
            d for d in DEFAULT_RUNS_DIR.iterdir()
            if d.is_dir() and not d.name.startswith(".")
        ])
        source_label = str(DEFAULT_RUNS_DIR.resolve())

    games = []
    for d in session_dirs:
        game = parse_session(d)
        if game.get("outcome") or game.get("turns"):
            games.append(game)

    out_path = QW_DIR / f"results-{args.name}.txt"

    if args.json:
        output = json.dumps(games, indent=2, default=str)
    else:
        # Capture print_report output to string
        import io as _io
        buf = _io.StringIO()
        old_stdout = sys.stdout
        sys.stdout = buf
        print_report(games, title=source_label)
        sys.stdout = old_stdout
        output = buf.getvalue()

    # Write to file only, print path
    out_path.write_text(output)
    print(str(out_path))


if __name__ == "__main__":
    main()
