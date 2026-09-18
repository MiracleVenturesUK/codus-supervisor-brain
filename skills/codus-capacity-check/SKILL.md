---
name: codus-capacity-check
description: Before a codus Brain wakes more quadrants, fans work out across parallel lanes or git worktrees, opens new tabs of agents, or starts extra dev servers, check this Mac's live memory capacity and the codus supervisor's latest advice. Load whenever you are about to delegate to several quadrants at once or add agents, or when the user asks whether there is room for more agents.
---

# Capacity check before adding agents

Every agent costs memory (a codus agent is typically 150 to 300 MB, more
with the tests and servers it starts). On a busy Mac, one more lane can push
the whole fleet into swap and slow every agent down. This check takes one
file read.

## Check

1. Read `~/.codus-supervisor/snapshot.json` (or `$CODUS_SUPERVISOR_HOME`). Use
   `capacity.state`, `capacity.est_extra_agents`, `capacity.reason` and
   `generated_at`.
2. If the file is missing or more than 10 minutes old, take a live reading
   instead, if the supervisor skill is installed:
   `~/.claude/skills/codus-supervisor/scripts/fleet-sample.sh --summary`
   (the line starts with the state: `ok`, `tight` or `critical`).
   If neither exists, the supervisor is not installed: carry on as normal.
3. Also read `~/.codus-supervisor/advice.json` if it exists and is less than
   2 hours old. It is written by the supervisor Brain and may name stopped
   quadrants you can use, or say `hold`.

## Decide

| state | What to do |
|---|---|
| `critical` | Start no new agents or dev servers. Finish or queue the work in lanes that are already running, and tell the user in one line why. |
| `tight` | Do not wake stopped quadrants for new lanes. Keep work in running lanes or do it in sequence, and mention the memory state to the user if it delays them. |
| `ok` | You may add up to `est_extra_agents` new agents (and no more than `advice.json`'s `max_new_agents` if that is lower). |

- A `hold` in `advice.json` counts as tight even when the snapshot says ok.
- The snapshot is newer than the advice. If the snapshot says tight or critical,
  trust it over `room` advice.
- More agents are only worth it for independent work. Keep one owner per task,
  and give each parallel lane its own folder (a git worktree for the same repo).
- Never stop, kill or close another Brain's agents because of this check.
  Suggest it to the user instead.
