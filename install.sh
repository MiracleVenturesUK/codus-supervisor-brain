#!/bin/sh
# install.sh: install the codus supervisor skills for Claude Code.
#
#   ./install.sh               install or update both skills
#   ./install.sh --uninstall   stop the watcher and remove the skills
#   ./install.sh --purge       --uninstall, and delete ~/.codus-supervisor too
#
# Options:
#   --agents     also install into ~/.agents/skills (Codex and other agents that
#                read the Agent Skills folder; only the capacity check is useful there)
#   --force      replace same-named skills that this script did not install
#   --dest DIR   install into DIR instead of ~/.claude/skills
set -eu

here=$(cd "$(dirname "$0")" && pwd)
version=$(cat "$here/VERSION" 2>/dev/null || echo unknown)
marker=.installed-by-codus-supervisor-brain
skills="codus-supervisor codus-capacity-check"

action=install
force=0
agents=0
dest=$HOME/.claude/skills
while [ $# -gt 0 ]; do
  case $1 in
    --uninstall) action=uninstall ;;
    --purge) action=purge ;;
    --force) force=1 ;;
    --agents) agents=1 ;;
    --dest)
      [ $# -ge 2 ] || { echo "install.sh: --dest needs a folder" >&2; exit 2; }
      shift
      dest=$1
      ;;
    -h | --help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
    *) echo "install.sh: unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

dests=$dest
[ "$agents" = 1 ] && dests="$dests $HOME/.agents/skills"
state_dir=${CODUS_SUPERVISOR_HOME:-$HOME/.codus-supervisor}

install_into() { # $1 = skills folder
  mkdir -p "$1"
  for s in $skills; do
    target=$1/$s
    if [ -e "$target" ] && [ ! -f "$target/$marker" ] && [ "$force" = 0 ]; then
      echo "install.sh: $target already exists and was not installed by this script." >&2
      echo "            Move it aside, or re-run with --force to replace it." >&2
      exit 1
    fi
    rm -rf "$target"
    cp -R "$here/skills/$s" "$target"
    printf '%s\n' "$version" >"$target/$marker"
    echo "installed $s $version -> $target"
  done
  chmod +x "$1/codus-supervisor/scripts/"*.sh
}

remove_from() { # $1 = skills folder
  for s in $skills; do
    target=$1/$s
    if [ -f "$target/$marker" ]; then
      rm -rf "$target"
      echo "removed $target"
    elif [ -e "$target" ]; then
      echo "install.sh: left $target alone (not installed by this script)" >&2
    fi
  done
}

stop_watcher() {
  pidf=$state_dir/watch.pid
  [ -f "$pidf" ] || return 0
  wp=$(cat "$pidf" 2>/dev/null || true)
  if [ -n "$wp" ] && kill -0 "$wp" 2>/dev/null && ps -o command= -p "$wp" 2>/dev/null | grep -q fleet-watch; then
    kill "$wp" && echo "stopped watcher pid=$wp"
  fi
  return 0
}

case $action in
  install)
    if [ "$(uname -s)" != Darwin ]; then
      echo "install.sh: note: the sampler supports macOS only for now." >&2
    fi
    for d in $dests; do install_into "$d"; done
    mkdir -p "$state_dir"
    if [ ! -f "$state_dir/config.env" ]; then
      cp "$here/skills/codus-supervisor/config.example.env" "$state_dir/config.env"
      echo "wrote default settings -> $state_dir/config.env (MODE=report)"
    fi
    echo
    echo "Done. In a codus Brain running Claude Code, say:"
    echo "  \"Load the codus-supervisor skill and start supervising.\""
    ;;
  uninstall | purge)
    stop_watcher
    for d in $dests; do remove_from "$d"; done
    if [ "$action" = purge ]; then
      case $state_dir in
        "" | / | "$HOME" | "$HOME/") echo "install.sh: refusing to delete $state_dir" >&2; exit 1 ;;
      esac
      if [ -d "$state_dir" ]; then rm -rf "$state_dir" && echo "deleted $state_dir"; fi
    fi
    ;;
esac
