# shellcheck shell=sh
# Shared settings for fleet-sample.sh and fleet-watch.sh. Sourced, not run.
#
# Precedence: environment variable > config.env > built-in default.
# config.env holds KEY=VALUE lines; only the keys listed below are read, and
# values are never executed.

CS_HOME=${CODUS_SUPERVISOR_HOME:-$HOME/.codus-supervisor}
CS_CONFIG=${CODUS_SUPERVISOR_CONFIG:-$CS_HOME/config.env}

cs_load_config() {
  [ -f "$CS_CONFIG" ] || return 0
  while IFS= read -r cs_line || [ -n "$cs_line" ]; do
    cs_line=$(printf '%s' "$cs_line" | tr -d '\r')
    case $cs_line in '' | '#'*) continue ;; esac
    cs_key=${cs_line%%=*}
    cs_val=${cs_line#*=}
    case $cs_val in
      \"*\") cs_val=${cs_val#\"}; cs_val=${cs_val%\"} ;;
      \'*\') cs_val=${cs_val#\'}; cs_val=${cs_val%\'} ;;
    esac
    case $cs_key in
      INTERVAL_SEC | TICK_MIN | IDLE_MIN | BUSY_MIN | FREE_TIGHT_PCT | FREE_CRIT_PCT | \
      RESERVE_PCT | SWAP_HEAVY_PCT | MAX_EXTRA_AGENTS | DEFAULT_AGENT_MB | RECLAIM_MB | \
      RECLAIM_COOLDOWN_MIN | HISTORY_MAX_LINES | AGENT_BINARIES | MODE | COOLDOWN_MIN | \
      ROOM_MIN | ROOM_EVERY_MIN | ROOM_DECLINE_MIN)
        # Only fill keys the environment has not already set.
        eval "cs_isset=\${$cs_key+x}"
        [ -z "$cs_isset" ] && eval "$cs_key=\$cs_val"
        ;;
    esac
  done <"$CS_CONFIG"
}

# cs_num NAME DEFAULT: keep NAME if it is a whole number, else use DEFAULT.
cs_num() {
  eval "cs_v=\${$1-}"
  case $cs_v in
    '' | *[!0-9]*)
      [ -n "$cs_v" ] && echo "codus-supervisor: $1=$cs_v is not a whole number, using $2" >&2
      eval "$1=\$2"
      ;;
  esac
}

cs_load_config
cs_num INTERVAL_SEC 60          # seconds between samples
cs_num TICK_MIN 60              # watcher exits with TICK after this many minutes
cs_num IDLE_MIN 30              # no session write for this long + low CPU = idle
cs_num BUSY_MIN 3               # session written within this many minutes = busy
cs_num FREE_TIGHT_PCT 20        # available memory below this % = tight
cs_num FREE_CRIT_PCT 10         # available memory below this % = critical
cs_num RESERVE_PCT 30           # % of RAM kept free for browsers, dev servers, builds
cs_num SWAP_HEAVY_PCT 25        # swap used above this % of RAM halves the room estimate
cs_num MAX_EXTRA_AGENTS 4       # never suggest more new agents than this at once
cs_num DEFAULT_AGENT_MB 300     # assumed agent size when none are running
cs_num RECLAIM_MB 1024          # idle agents holding this much while not ok = RECLAIM
cs_num RECLAIM_COOLDOWN_MIN 60  # minutes between RECLAIM events
cs_num HISTORY_MAX_LINES 2880   # history.jsonl cap (48 h at 60 s)
cs_num COOLDOWN_MIN 60          # supervisor Brain: minutes between HOLD/ALLCLEAR to one Brain
cs_num ROOM_MIN 2               # advise mode: nudge only when at least this many agents fit
cs_num ROOM_EVERY_MIN 60        # advise mode: minutes between ROOM nudges to the same Brain
cs_num ROOM_DECLINE_MIN 60      # advise mode: quiet period after a Brain says it has nothing to split
: "${AGENT_BINARIES:=claude codex}"
case ${MODE:-report} in advise) MODE=advise ;; *) MODE=report ;; esac

[ "$INTERVAL_SEC" -ge 1 ] || INTERVAL_SEC=1
