# codus supervisor Brain

Turn one codus Brain into a supervisor for your whole fleet. It watches your
Mac's memory and every quadrant and Brain agent, tells you when memory is
tight, and can tell your other Brains when there is room to run more quadrants
in parallel and when to hold back.

The watching is done by two small shell scripts, so it uses no tokens. The
Brain only wakes when something changes.

## Why a supervisor should say "hold" as well as "go"

Running more quadrants in parallel only helps when there is memory to spare.
On one 16 GB Mac running 40 quadrants and 6 Brains, the numbers looked like this:

- 13 quadrants had an agent running, and only 1 of them was busy.
- macOS memory pressure was at *warning*, with 4 GB already swapped out.
- Each agent was using 130 to 300 MB, and 12 idle ones held about 1.9 GB.

Adding quadrants there would have slowed every agent down. So this supervisor
tells Brains to add lanes when there's room, tells them to hold when memory is
tight, and points out which idle agents are holding memory.

## What it does

- **Samples every minute, for free:** macOS memory pressure, available memory,
  swap, and for every `claude` and `codex` agent: which quadrant or Brain it
  belongs to, its folder, memory (including anything it started, such as tests
  or dev servers), CPU, and when it last did anything.
- **Wakes the Brain only on events:** a capacity change (ok, tight or critical),
  a reclaim hint (idle agents holding memory while it is short), a ROOM nudge
  that is due (advise mode), or an hourly tick.
- **Reports** to you in one or two sentences in Brain Chat, only when something
  changed.
- **Advises** (opt-in) your other Brains: HOLD when memory gets tight, ALL CLEAR
  when it recovers, and ROOM when there is memory for more agents. ROOM nudges
  go to Brains that are working right now and repeat every `ROOM_EVERY_MIN`
  minutes while the room lasts. A Brain with nothing to split runs one command
  to pause its nudges.
- **Spots problems:** a quadrant whose agent is working in a different folder from
  the one it is pinned to, agents with no quadrant, Brains with duplicate names,
  plan accounts near their limit.
- **Lets any Brain check before fanning out:** the `codus-capacity-check` skill
  reads the latest snapshot, so Brains can size their own lanes without being
  messaged.

## What it never does

It never kills a process (apart from its own watcher), stops an agent, closes a
tab, repins a quadrant, switches accounts or providers, or runs git in your
projects. It suggests; you and your Brains decide.

## Requirements

- macOS (Apple silicon or Intel). The sampler reads macOS-only memory counters.
- codus, with the supervisor running in a **Claude Code** Brain. It needs
  background jobs that wake the Brain when they finish, which Codex Brains do not
  have. Other Brains can be Claude Code or Codex.
- `jq` is optional (preinstalled on macOS 15 and later). Without it, the plan
  usage section is left out.

## Install

```sh
git clone https://github.com/MiracleVenturesUK/codus-supervisor-brain.git
cd codus-supervisor-brain
./install.sh
```

This copies two skills into `~/.claude/skills` and writes default settings to
`~/.codus-supervisor/config.env` (report mode). codus agents pick up new skills on
their next turn.

## Use

In a codus Brain running Claude Code, say:

> Load the codus-supervisor skill and start supervising.

It takes a first reading, reviews your quadrants, starts the background
watcher, and tells you the current state. After that it stays quiet until
something changes.

| Ask the supervisor Brain | What happens |
|---|---|
| "How's capacity?" | a one-line reading from the sampler |
| "Switch to advise mode" | sets `MODE=advise`; it starts messaging other Brains |
| "Stop supervising" | stops the watcher and leaves your settings |

Any Brain can check capacity before adding agents; the `codus-capacity-check`
skill loads on its own when a Brain is about to fan out.

From a terminal:

```sh
~/.claude/skills/codus-supervisor/scripts/fleet-sample.sh --summary
# ok: memory pressure normal, 48% available; swap 1.2 of 2.0 GB; 12 agents (3 busy, 4 idle holding 0.7 GB); room for 4 more
```

## Settings

Edit `~/.codus-supervisor/config.env`. Environment variables with the same names
win over the file.

| Key | Default | Meaning |
|---|---|---|
| `MODE` | `report` | `report`: tell you only. `advise`: also message other Brains. |
| `INTERVAL_SEC` | 60 | seconds between samples |
| `TICK_MIN` | 60 | wake the Brain at least this often |
| `BUSY_MIN` | 3 | session written this recently = busy |
| `IDLE_MIN` | 30 | nothing written for this long and no CPU = idle |
| `FREE_TIGHT_PCT` | 20 | available memory below this = tight |
| `FREE_CRIT_PCT` | 10 | available memory below this = critical |
| `RESERVE_PCT` | 30 | share of RAM kept free for browsers, builds and servers |
| `SWAP_HEAVY_PCT` | 25 | swap above this share of RAM halves the room estimate |
| `MAX_EXTRA_AGENTS` | 4 | never suggest more new agents than this at once |
| `RECLAIM_MB` | 1024 | idle agents holding this much while memory is short = reclaim hint |
| `COOLDOWN_MIN` | 60 | minutes between HOLD / ALL CLEAR messages to the same Brain |
| `ROOM_MIN` | 2 | nudge only when at least this many more agents fit |
| `ROOM_EVERY_MIN` | 60 | minutes between ROOM nudges to the same Brain |
| `ROOM_DECLINE_MIN` | 60 | how long a Brain's "nothing to split" pauses its nudges |
| `AGENT_BINARIES` | `claude codex` | process names that count as agents |

**Push harder.** To have Brains use every quadrant memory allows, set
`MODE=advise`, `MAX_EXTRA_AGENTS=8`, `RESERVE_PCT=20`, `ROOM_EVERY_MIN=5` and
`ROOM_DECLINE_MIN=30`. The monitor still checks every minute; working Brains are
nudged every 5 minutes while there's room. Each nudge is a turn for the Brain
that receives it, so it uses plan usage.

## How it works

```
fleet-watch.sh  (background job in the supervisor Brain, no tokens)
   │  every 60 s: fleet-sample.sh → snapshot.json + history.jsonl
   │  exits on STATE / RECLAIM / ROOM / TICK
   ▼
supervisor Brain wakes
   │  reads snapshot.json, lists quadrants and Brains
   │  writes advice.json, reports to you, messages Brains (advise mode)
   └─ restarts the watcher

any Brain about to fan out
   └─ codus-capacity-check: reads snapshot.json + advice.json
```

- **Capacity state** comes from the macOS kernel's own memory pressure level
  (normal, warning, critical), plus a floor on available memory. High swap
  alone doesn't count, because macOS grows swap on demand. Heavy swap does make
  the room estimate more cautious.
- **Room** is a rough count of extra agents that fit: available memory minus a
  reserve, divided by the average agent's size, halved when a lot is already
  swapped out, and capped.
- **Agent roles** come from how codus launches agents: a quadrant agent carries
  its component id in its codus MCP address, and Brains run from
  `~/.codus/brains/<id>`.
- **Last activity** is the newest write to the agent's session file (Claude
  Code or Codex), so no agent is ever interrupted to ask.

Files in `~/.codus-supervisor`: `config.env`, `snapshot.json`,
`history.jsonl`, `events.log`, `advice.json`, `sent.log`, `reported.log`,
`room.state`, `decline.log`, `watch.pid`, `watch.state`.

## Cost

- Sampler and watcher: no tokens, about a second of CPU per sample.
- Supervisor Brain: one agent's memory (200 to 300 MB), plus one short turn per
  event and one per hour. Full reviews list quadrants and Brains, which costs a
  few thousand tokens each.

## Limits

- It can't see what other Brains have queued, so it can say there's room but
  can't know whether a Brain has work that splits cleanly. That judgement stays
  with each Brain.
- codus has no tool to stop one idle agent, so freeing memory is left to you.
- The supervisor lives in one Brain's session. If that Brain restarts, ask it to
  start supervising again.
- macOS only for now.

## What would make this unnecessary

Most of this belongs inside codus itself:

1. Memory, CPU and idle time for every agent in the UI and in the fleet status call.
2. Holding queued tasks when memory pressure is high, instead of starting another agent.
3. Pausing agents that have been idle for a while and resuming them on their
   next task, once every session can be resumed exactly.
4. Starting new agents on whichever plan account has headroom.
5. Flagging a quadrant whose agent runs in a different folder from its pin.
6. A capacity hint for every Brain, so each can size its own lanes.

## Development

```sh
sh tests/run.sh      # 65 offline checks plus one live read-only snapshot
```

- `skills/codus-supervisor/scripts/`: `lib.sh` (settings), `fleet-sample.sh`,
  `fleet-watch.sh`. POSIX sh and awk, tested under bash 3.2 and dash.
- `skills/codus-supervisor/SKILL.md`: the supervisor playbook.
- `skills/codus-capacity-check/SKILL.md`: the check every Brain can run.
- `docs/modules/`: module notes; `data/build-log/branches/`: why things are
  the way they are.

## Uninstall

```sh
./install.sh --uninstall   # remove the skills, keep ~/.codus-supervisor
./install.sh --purge       # remove the skills and ~/.codus-supervisor
```

## Licence

MIT. See [LICENSE](LICENSE).
