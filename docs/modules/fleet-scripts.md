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
- `fleet-watch.sh`: sampling loop with events STATE, RECLAIM, ROOM (advise mode),
  DONE, BRAIN_CLOSED, TICK, ERROR, ALREADY_RUNNING; `--once`, `--exit-on-event`, `--stop`,
  `--decline <brain id>`.
- Self detection: the sampler reports the agent it runs under (`self`) and the
  Brains working right now (`active_brains`), so ROOM never targets the supervisor.
- `lib.sh`: settings with env > config.env > default precedence.

## Data (state files, `~/.codus-supervisor`)

| File | Owner | Notes |
|---|---|---|
| `config.env` | user | whitelisted KEY=VALUE, never executed |
| `snapshot.json` | watcher | schema 1, rewritten atomically each sample |
| `history.jsonl` | watcher | capped at `HISTORY_MAX_LINES` |
| `events.log`, `errors.log` | watcher | append-only |
| `watch.pid`, `watch.state` | watcher | single instance; hysteresis and cooldown memory |
| `room.state` | watcher | last ROOM nudge time per Brain |
| `decline.log` | other Brains via `--decline` | Brains with nothing to split right now |
| `done.state` | watcher | last DONE report time per quadrant |

## Interface

- `fleet-sample.sh [--summary | --kv | --out FILE]`
- `fleet-watch.sh [--once | --exit-on-event | --stop | --decline ID] [--interval SEC] [--max-minutes N]`
- Test-only overrides: `CS_TEST_PS_FILE`, `CS_TEST_CWD_FILE`, `CS_TEST_ACTIVITY_FILE`,
  `CS_TEST_NOW`, `CS_TEST_TOTAL_MB`, `CS_TEST_PRESSURE_LEVEL`, `CS_TEST_FREE_PCT`,
  `CS_TEST_SWAP` ("used total" in MB), `CS_TEST_COMPRESSED_MB`, `CS_TEST_SELF_PID`.

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
- A shell runs a trapped signal only after the foreground command ends, so the
  watcher sleeps with `sleep & wait`; `--stop` also polls until the pid is gone.

## Build log

- 2026-09-18: DONE and BRAIN_CLOSED events, `brains_live` / `idle_quadrants`. See [main](../../data/build-log/branches/main.md).
- 2026-09-18: `--stop` waits for the watcher to exit; the sleep no longer delays signals. See [main](../../data/build-log/branches/main.md).
- 2026-09-18: ROOM nudges decided in the watcher, `--decline`, self detection. See [main](../../data/build-log/branches/main.md).
- 2026-09-18: initial sampler, watcher, settings and tests. See [main](../../data/build-log/branches/main.md).
