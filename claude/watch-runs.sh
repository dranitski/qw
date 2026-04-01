#!/bin/bash
D=debug-seed-runs
TOTAL=${1:-0}

started=$(ls -d $D/*/ 2>/dev/null | wc -l)
finished=$(find $D -name "morgue*.txt" 2>/dev/null | wc -l)
errors=$(find $D -name reason.txt 2>/dev/null | wc -l)
running=$((started - finished - errors))
pending=$((TOTAL - started))

echo "pending: $pending  running: $running  finished: $finished  error: $errors"
