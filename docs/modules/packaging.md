# Module: packaging

## Purpose

Get the skills onto a user's machine safely, and document the project for
people who find it on GitHub.

## Access

`./install.sh` from a clone. README for humans; `CLAUDE.md` for agents working
on the repo.

## Features

- Install or update both skills into `~/.claude/skills` (or `--dest`), with a
  marker file per skill; optional `--agents` copy into `~/.agents/skills`.
- Seeds `~/.codus-supervisor/config.env` from the example once (report mode).
- Refuses to replace a same-named skill it did not install, unless `--force`.
- `--uninstall` stops the watcher and removes marked skills; `--purge` also
  removes the state folder, with a guard against `/`, `$HOME` and empty paths.

## Data

`VERSION` (written into each skill's marker file).

## Key files

- `install.sh`
- `README.md`, `LICENSE` (MIT), `VERSION`, `CLAUDE.md`

## Gotchas

- The installer copies whole skill folders, so anything placed in
  `skills/<name>/` ships to users. Keep development notes in `docs/`.
- Tests run the installer with a temporary HOME, so they never touch the real
  skills folder.

## Build log

- 2026-09-18: initial installer, README, licence. See [main](../../data/build-log/branches/main.md).
