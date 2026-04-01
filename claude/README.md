## Main flow

1. ensure you have crawl repo at `../crawl`
1. ensure crawl repo is checked out to `0.32.1-qw` branch which have our necessary patches
1. from this repo root, build optimised crawl binary `python3 claude/crawl-build-optimised.py`
1. build qw `./make-qw.sh`
1. run a game with viewing it: `python3 claude/debug-seed.py --seed 42 --verbose --save-interval 200 --visual watch` (you cant interact)
1. command output shows you run uuid and dir path
1. you can restore save from prev game `python3 claude/debug-seed.py --restore 1600 --from 2026-03-22-10-30-seed-42-uuid-a1b2c3d4 --verbose --save-interval 200 --visual watch` - it will start new dir and session from provided save checkpoint
1. find its logs and morgue at provided dir path (`debug-seed-runs/*`)
1. `--visual watch` shows you the game in terminal, `--visual true` dont show, but runs save way under the hood, so the paly with same seed will be deterministic (exact same resukt). `--visual none` (default) will run much faster, but its result on same seed will be same only with same `--visual none` plays. Rendering in crawl affects how game flow is going and impacts the qw decision flow
1. you can use `--max-time 120` in seconds to force qw suicide after passed in-game time
1. `claude/run-parallel.py` recieves all params from `debug-seed.py` except `--restore`. Use it with `--total 100` to use seeds `1..100`. Use it with `--seeds 1,2,5` to run with specified seeds

## Metrics

1. `rm -fr debug-seed-runs/*`
1. `python3 claude/run-parallel.py --total 100 --parallel 12 --max-turns 20000 --verbose 2>&1 | tee /tmp/batch-100-output.txt`
1. `python claude/analyze-runs.py --name $(git rev-parse --short HEAD)`