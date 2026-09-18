# codus-supervisor-brain

Skills and zero-token scripts that turn one codus Brain into a fleet
supervisor (memory pressure, agent activity, advice to other Brains).

## Rules

- Shell is POSIX `sh` plus BWK/POSIX `awk`. It must run under macOS's bash 3.2
  (as `/bin/sh`) and dash: no arrays, no `[[ ]]`, no gawk extensions.
- The supervisor suggests; it never kills agents, stops or repins quadrants,
  switches accounts or touches git. Keep it that way in scripts and skills.
- Nothing personal in the repo: no real project names, paths, emails or account
  names in examples, fixtures or docs. Use made-up names.
- `sh tests/run.sh` must pass before every commit. Add a test with every
  behaviour change.
- User-facing text uses British English and no em dashes.
- Documentation chain: this file lists modules; each module doc keeps a dated
  `## Build log` linking the branch logs in `data/build-log/branches/`. Update
  the branch log after every edit and the module doc in the same commit.
  Module docs live in `docs/modules/` rather than next to the code, because the
  skill folders are copied into users' `~/.claude/skills`.

## Modules

- [fleet-scripts](docs/modules/fleet-scripts.md): sampler, watcher, settings, tests
- [skills](docs/modules/skills.md): `codus-supervisor` and `codus-capacity-check` playbooks
- [packaging](docs/modules/packaging.md): installer, README, licence, versioning
