# Module: fleet-scripts

## Purpose

Measure this Mac's memory and every codus agent without spending tokens, and
turn changes into single-line events a Claude Code Brain can wake on.

## Access

Run by the supervisor Brain (`fleet-watch.sh --exit-on-event` as a background
job), by any Brain via `codus-capacity-check`, or by hand from a terminal.

## Features

- `fleet-sample.sh`: one snapshot as JSON, KEY=VALUE or a summary line.
  Machine (pressure level, available %, swap, compressor, load), agents (role,
  component or Brain id, cwd, session, own and tree memory, tree CPU, uptime,
  last activity, status), top memory groups, optional plan usage, capacity
  state and room estimate.
- `fleet-watch.sh`: sampling loop with events STATE, RECLAIM, TICK, ERROR,
  ALREADY_RUNNING; `--once`, `--exit-on-event`, `--stop`.
- `lib.sh`: settings with env > config.env > default precedence.

## Data (state files, `~/.codus-supervisor`)

| File | Owner | Notes |
|---|---|---|
| `config.env` | user | whitelisted KEY=VALUE, never executed |
| `snapshot.json` | watcher | schema 1, rewritten atomically each sample |
| `history.jsonl` | watcher | capped at `HISTORY_MAX_LINES` |
| `events.log`, `errors.log` | watcher | append-only |
| `watch.pid`, `watch.state` | watcher | single instance; hysteresis and cooldown memory |

## Interface

- `fleet-sample.sh [--summary | --kv | --out FILE]`
- `fleet-watch.sh [--once | --exit-on-event | --stop] [--interval SEC] [--max-minutes N]`
- Test-only overrides: `CS_TEST_PS_FILE`, `CS_TEST_CWD_FILE`, `CS_TEST_ACTIVITY_FILE`,
  `CS_TEST_NOW`, `CS_TEST_TOTAL_MB`, `CS_TEST_PRESSURE_LEVEL`, `CS_TEST_FREE_PCT`,
  `CS_TEST_SWAP` ("used total" in MB), `CS_TEST_COMPRESSED_MB`.

## Key files

- `skills/codus-supervisor/scripts/lib.sh`
- `skills/codus-supervisor/scripts/fleet-sample.sh`
- `skills/codus-supervisor/scripts/fleet-watch.sh`
- `tests/run.sh`

## Gotchas

- `ps` runs with `LC_ALL=C`, or `%cpu` can print with a decimal comma.
- `wc -l` pads with spaces on macOS; strip before numeric tests.
- Claude Code session folders: cwd with every non-alphanumeric character turned
  into `-`. codus may keep them under `~/.codus/accounts/<account>/projects`
  instead of `~/.claude/projects`; both are searched (including dot-folders).
- A new agent has no session file yet, so its status is `unknown`, not idle.
- The watcher's own timings are read at start; it restarts after every wake in
  `--exit-on-event` mode, so config changes apply from the next wake.
- In tests, a watchdog inside `$( )` must redirect its output or the
  substitution blocks until the watchdog's `sleep` ends.

## Build log

- 2026-09-18: initial sampler, watcher, settings and tests. See [main](../../data/build-log/branches/main.md).
