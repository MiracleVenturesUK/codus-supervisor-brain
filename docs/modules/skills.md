# Module: skills

## Purpose

The playbooks codus Brains follow: `codus-supervisor` makes one Brain the fleet
supervisor; `codus-capacity-check` lets every Brain check capacity before it
adds agents.

## Access

Installed into `~/.claude/skills`; codus agents discover them on their next
turn. The supervisor role needs a Claude Code Brain (background jobs that
re-invoke it). The capacity check works in any Brain that can read a file.

## Features

- Supervisor: start (reading, full review, background watcher), event handling
  (STATE / RECLAIM / TICK / ERROR / ALREADY_RUNNING), light and full reviews,
  `advice.json`, report mode (default), advise mode (HOLD / ALLCLEAR on capacity
  changes; ROOM when the watcher says a nudge is due, with a decline command in
  the message), DONE handling for quiet quadrants, closed-Brain cleanup
  (`ON_BRAIN_CLOSE=report|free`), stop, mode changes, and a documented "push
  harder" profile.
- Capacity check: snapshot first, live reading if stale, advice if fresh;
  critical = start nothing, tight = no new lanes, ok = up to the room estimate.

## Data

| File | Owner | Notes |
|---|---|---|
| `advice.json` | supervisor Brain | state, advice, max_new_agents, stopped quadrants, per-Brain ownership, notes |
| `closed.json` | supervisor Brain | closed Brains and their quadrants still pending |
| `freed.log` | supervisor Brain | every freeing action with the old folder |
| `sent.log` | supervisor Brain | one line per message to a Brain |
| `reported.log` | supervisor Brain | one line per problem already reported to the user |

## codus tools used

`brain_list_all_quadrants`, `brain_list_brains`, `brain_get_project`,
`brain_send_to_brain` (advise mode), `chat_say`; with `ON_BRAIN_CLOSE=free` also
`brain_quadrant_status`, `brain_stop_aux`, `brain_set_quadrant_cwd` and
`brain_close_tab`. Deliberately not
`get_ai_usage_status` on every review (large output); usage comes from the
snapshot.

## Key files

- `skills/codus-supervisor/SKILL.md`
- `skills/codus-supervisor/config.example.env`
- `skills/codus-capacity-check/SKILL.md`

## Gotchas

- Brain names can repeat; always address Brains by id.
- A message to a Brain lands in its terminal as a turn, so advise mode only
  messages working Brains: HOLD / ALLCLEAR on a change, ROOM at the configured
  cadence, and a Brain with nothing to split can pause ROOM with `--decline`.
- Watcher wakes are automated turns: no user bubble, and chat only when there
  is news.
- Examples must use made-up project names (public repo).
- codus forgets a Brain's project when it closes (`brain_get_project` fails), so
  closed-Brain cleanup relies on the ownership cached in `advice.json`.

## Build log

- 2026-09-18: closed Brains read cached ownership (codus forgets their projects). See [main](../../data/build-log/branches/main.md).
- 2026-09-18: DONE nudges and closed-Brain cleanup (`ON_BRAIN_CLOSE`). See [main](../../data/build-log/branches/main.md).
- 2026-09-18: queued (tab closed) nudges pause that Brain via `--decline`. See [main](../../data/build-log/branches/main.md).
- 2026-09-18: ROOM driven by watcher events, stronger ROOM template, push-harder profile. See [main](../../data/build-log/branches/main.md).
- 2026-09-18: initial supervisor and capacity-check skills. See [main](../../data/build-log/branches/main.md).
