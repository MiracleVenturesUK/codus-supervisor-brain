# Build log: main

- **Branch:** main
- **Base branch:** none (new repository)
- **Started:** 2026-09-18
- **Modules touched:** fleet-scripts, skills, packaging
- **Goal:** A shareable "supervisor Brain" for codus. A zero-token background
  sampler watches macOS memory pressure and every codus quadrant/Brain agent.
  One Brain wakes only on real changes, reports capacity to the user and, in
  advise mode, tells other Brains when there is room for more parallel
  quadrants and when to hold. Public on GitHub so other codus users can install it.

## Why this shape

The request was "a Brain that monitors quadrant / RAM usage and instructs other
Brains to use more quadrants to maximise efficiency". Measuring a real 16 GB
machine first changed the design:

- Quadrants were not scarce: 40 existed, 13 had an agent running, 1 was busy.
- RAM was: macOS memory pressure at warning, swap 4.1 of 5.1 GB, each agent
  roughly 130 to 300 MB resident.
- So a supervisor that only says "use more" would make things worse. It has to
  say "hold" as well as "go", and it must cost almost nothing while idle.

Decisions:

- **Sampling is shell + awk, not the LLM.** A Brain reading numbers every
  minute burns tokens and RAM. The sampler costs nothing; the Brain wakes only
  on events. Rejected: a `/loop` that has the Brain poll codus tools each tick
  (one `get_ai_usage_status` call alone returned ~15k tokens).
- **macOS kernel pressure level is the primary signal**
  (`kern.memorystatus_vm_pressure_level`: 1 normal, 2 warn, 4 critical), with
  `kern.memorystatus_level` (available %) as the secondary. Rejected: swap
  percentage as a state signal, because macOS grows swap files on demand, so a
  high used/total ratio is common on a healthy machine.
- **Background Bash that exits on the first event** re-invokes a Claude Code
  Brain, so there is one wake per event plus an hourly TICK. Rejected as the
  primary: the Monitor tool (30-minute cap, not in every Claude Code version)
  and CronCreate (session-only, expires after 7 days, fires only when idle).
- **Advisory only.** The supervisor never kills processes, stops agents, closes
  tabs, repins quadrants, switches accounts or touches git. codus has no tool to
  stop a single idle agent cleanly, and many live sessions are not confirmed as
  resumable, so a kill could lose an agent's place.
- **Report mode by default.** Messages to other Brains land in their terminals
  as a turn, so advise mode is opt-in, change-driven and rate-limited per Brain.
- **Pull as well as push.** Every Brain can load `codus-capacity-check` before
  fanning out; it reads the sampler's snapshot, so most Brains never need to be
  interrupted.

## Entries

### 2026-09-18: scaffold
- Files: `VERSION` (0.1.0), `.gitignore`, `data/build-log/branches/main.md`.
- Repo-local git identity uses the GitHub noreply address, so no personal
  email lands in public history.

### 2026-09-18: settings loader (`skills/codus-supervisor/scripts/lib.sh`)
- Precedence: environment > `config.env` > default. Only whitelisted keys are
  read, and values are assigned, never executed (`eval "$KEY=\$val"`).
- `cs_num` validates whole numbers and falls back to the default with a warning.
- Rejected: `. config.env` (sourcing runs arbitrary shell from a user file).

### 2026-09-18: sampler (`scripts/fleet-sample.sh`)
- One pass of `ps` (with `LC_ALL=C`, so `%cpu` always uses a dot), then `lsof -d cwd`
  for the agent pids only, then session-file mtimes, then one awk program
  that prints JSON, KEY=VALUE or a summary line.
- Agent = first word of the command is in `AGENT_BINARIES` (default `claude codex`).
  Role comes from the codus launch shape: `/mcp/<n>` in the command = quadrant
  component n; cwd `~/.codus/brains/<id>` = Brain; `~/.codus/codus-brain` = Brain
  `main`; any other `~/.codus/...` = codus helper agent.
- Tree accounting: every process is charged to its nearest agent ancestor, so a
  quadrant's `tree_mb` includes the test runners and servers its agent started.
- Activity: newest `*.jsonl` in the agent's Claude project folder (slug =
  cwd with every non-alphanumeric turned into `-`), searched in
  `~/.claude/projects` and codus per-account folders `~/.codus/accounts/*/projects`
  (found on the reference machine; agents launched under an account keep
  sessions there). Codex: newest `rollout-*.jsonl` from the last 3 days whose first
  line carries the same `"cwd"`.
- Status: busy (session write < BUSY_MIN or tree CPU >= 10%), idle (no write for
  IDLE_MIN and tree CPU < 3%), recent, unknown (no session file yet).
- State: critical if pressure level 4 or available < FREE_CRIT_PCT; tight if
  level 2 or available < FREE_TIGHT_PCT; else ok.
- Room estimate (only when ok): (available − RESERVE_PCT of RAM) / average agent
  size, halved when swap used >= SWAP_HEAVY_PCT of RAM, capped at MAX_EXTRA_AGENTS.
  First live run said "room for 8 more" with 5.2 GB swapped, which is too eager,
  so defaults moved to RESERVE 30%, cap 4, plus the swap penalty.
- Optional plan usage from codus's local `*-usage-cache.json` via jq; null when
  jq or the files are missing.
- JSON strings are escaped char by char in awk (avoids gsub backslash rules that
  differ between awk builds).

### 2026-09-18: watcher (`scripts/fleet-watch.sh`)
- Samples every INTERVAL_SEC into `snapshot.json` (atomic rename via a per-pid tmp
  file), appends `history.jsonl` (capped), and prints events: STATE, RECLAIM,
  TICK, ERROR, ALREADY_RUNNING. Every event is also appended to `events.log`.
- Hysteresis: a new state must hold for two samples; critical fires at once.
  `watch.state` persists last state, pending state and the RECLAIM cooldown
  across restarts, since `--exit-on-event` restarts the watcher after every wake.
- First run sets a baseline and emits nothing, so starting never wakes the Brain.
- One watcher per state folder: pidfile checked with `kill -0` and a `ps` command
  match (a recycled pid is not mistaken for a watcher). `--stop` ends it.

### 2026-09-18: supervisor playbook (`skills/codus-supervisor/SKILL.md`, `config.example.env`)
- Start: `--once` reading, full review, then the watcher as a Claude Code
  background job with `--exit-on-event`; every exit re-invokes the Brain, which
  reviews and restarts it. A Codex Brain is told to hand the role to a Claude
  Code Brain (no background re-invocation there).
- Light review on TICK (snapshot only); full review on STATE/RECLAIM or when
  `advice.json` is older than 2 hours. Full review adds `brain_list_all_quadrants`
  and `brain_list_brains` (plus `brain_get_project` per Brain in advise mode
  only). Deliberately not `get_ai_usage_status`: it returned ~15k tokens on the
  reference machine; usage comes from the snapshot's optional `usage` block.
- Findings the review looks for: stopped quadrants, pin/cwd mismatch (seen live:
  a quadrant repinned while its agent kept working in the old folder), orphan
  quadrant agents, duplicate Brain names (seen live: two Brains with the same
  name), idle agents, accounts at 90%+.
- Report mode posts only on change, deduped through `reported.log`. Advise mode
  adds HOLD / ALLCLEAR / ROOM messages by Brain id, to *active* Brains only,
  with a per-Brain cooldown logged in `sent.log`. Templates are self-contained
  because the receiving Brain has none of the supervisor's context.
- Examples in the playbook use made-up project names; nothing from the
  reference machine is published.

### 2026-09-18: capacity check (`skills/codus-capacity-check/SKILL.md`)
- For every Brain before it fans out: read `snapshot.json` (live reading via
  `fleet-sample.sh --summary` if stale), then `advice.json` if under 2 hours old.
  critical = start nothing, tight = no new lanes, ok = up to `est_extra_agents`.
- The snapshot beats older `room` advice; `hold` advice counts as tight.

### 2026-09-18: installer (`install.sh`)
- Copies both skills into `~/.claude/skills` (or `--dest`), writes a marker file
  in each, and seeds `~/.codus-supervisor/config.env` (MODE=report) once.
- Refuses to overwrite a same-named skill without our marker unless `--force`.
- `--uninstall` stops a running watcher and removes only marked skills;
  `--purge` also deletes the state folder, refusing `/`, `$HOME` or empty.
- `--agents` also installs into `~/.agents/skills`.

### 2026-09-18: tests (`tests/run.sh`)
- 53 checks, all offline except one read-only live snapshot: parse under
  sh/bash/dash; fixture process table covering quadrant, Brain, main Brain,
  codus helper, plain claude, codex quadrant, Chrome helpers and the Claude
  desktop app (must not count as an agent); capacity state matrix; room maths
  incl. swap penalty and cap; config precedence and bad-number fallback;
  watcher baseline, TICK, immediate critical, two-sample tight, RECLAIM and its
  cooldown across restarts, single instance, `--stop`; installer install,
  reinstall, foreign-skill refusal, uninstall, purge and the purge guard.
- Isolation: temporary HOME and state folder, known env keys unset.
- Gotcha found while writing it: a timeout watchdog started inside `$( )` must
  not inherit stdout, or the substitution waits for its `sleep` to finish.
- Result: 53 passed, 0 failed (bash 3.2 as /bin/sh, macOS 26.5); sampler and
  watcher also run clean under dash.

### 2026-09-18: docs (`README.md`, `LICENSE`, `CLAUDE.md`, `docs/modules/*.md`)
- README: why "hold" matters (anonymised aggregate numbers from the reference
  machine), what it does and never does, install, use, settings, how it works,
  cost, limits, and an upstream wishlist of what codus could build natively.
- Root `CLAUDE.md` holds rules and the module registry; module docs sit in
  `docs/modules/` (not next to the code) because skill folders are copied into
  users' `~/.claude/skills` by the installer.
- SKILL: added "Change mode or thresholds" (edit `config.env` only when asked;
  sampler rereads it every sample, watcher timings apply from its next restart).
- MIT licence, copyright MiracleVenturesUK.

### 2026-09-18: published
- Public repo: https://github.com/MiracleVenturesUK/codus-supervisor-brain
  (topics: codus, claude-code, ai-agents, macos, developer-tools).
- Pushed with the owning account's token through a one-off git credential
  helper, so the machine's active gh account was not switched and no token was
  written to `.git/config`.
- Verified from a fresh public clone: 53 passed, 0 failed; `./install.sh` into a
  throwaway HOME installed both skills and seeded `config.env`.

### 2026-09-18: ROOM nudges in the watcher ("push harder")
- Request: advise mode that pushes Brains to use more quadrants, checking every
  5 minutes instead of hourly.
- Decision: the watcher decides when a nudge is due, not the Brain. It already
  samples every minute at no cost; the Brain wakes only when a ROOM event is due
  and just sends the messages. Rejected: `TICK_MIN=5` with the Brain reviewing on
  every tick (12 LLM wakes an hour whether or not anything is due, each carrying
  the Brain's whole context).
- `fleet-sample.sh`: finds the agent it runs under (walks its own ppid chain to
  the nearest agent) and reports `self` plus `active_brains` (Brains that are busy
  or recent, excluding self). `CS_TEST_SELF_PID` for tests.
- `fleet-watch.sh`: ROOM event in advise mode when state is ok,
  `est_extra >= ROOM_MIN`, and a working Brain has not been nudged within
  `ROOM_EVERY_MIN` (per-Brain times in `room.state`) and has not declined within
  `ROOM_DECLINE_MIN` (`decline.log`). STATE events now carry `brains=` for HOLD.
  New `--decline <id>` lets a Brain with nothing to split pause its nudges with
  one shell command, which costs no supervisor wake.
- New settings: `ROOM_MIN` (2), `ROOM_EVERY_MIN` (60), `ROOM_DECLINE_MIN` (60).
  Public defaults stay conservative; the "push harder" profile (advise, cap 8,
  reserve 20%, nudge every 5 min, decline pause 30 min) is documented in
  `config.example.env`, the README and the skill.
- SKILL: ROOM event row, stronger ROOM template with the decline command,
  `brains` ownership map in `advice.json` (advise mode) for naming each Brain's
  stopped quadrants, updated hard rule on when Brains may be messaged.
- Tests: 13 new (self detection, active Brains, ROOM fires, per-Brain interval,
  repeat, decline and bad id, report mode silent, no ROOM when tight or below
  ROOM_MIN, STATE lists Brains). 66 passed, 0 failed. Live check from this Brain:
  `self` resolved to the supervisor's own Brain id, three working Brains listed.

### 2026-09-18: fix `--stop` racing a restart
- Found live: `--stop` printed "stopped" while the old watcher was still alive
  inside `sleep 60`, because a POSIX shell runs a trapped signal only after the
  foreground command finishes. A restart straight after it hit ALREADY_RUNNING.
- Fix: the loop sleeps in the background and `wait`s on it (a signal interrupts
  `wait` at once), the INT/TERM/HUP trap kills that sleep, and `--stop` polls
  until the process is gone (up to 10 s, non-zero exit if it is not).
- Tests: the single-instance test now uses a 30 s interval so the watcher is
  mid-sleep when stopped; new checks that `--stop` returns within 5 s and that a
  restart straight after it works. 68 passed, 0 failed.
- SKILL: Brain ownership subtracts `excluded` quadrant ids.
