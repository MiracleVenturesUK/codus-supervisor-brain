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
