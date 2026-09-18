#!/bin/sh
# fleet-watch.sh: sample every INTERVAL_SEC, keep snapshot.json and
# history.jsonl current, and print one line per event:
#
#   STATE    capacity changed (ok / tight / critical), confirmed on two samples
#            in a row (critical is reported at once)
#   RECLAIM  memory is not ok and idle agents hold at least RECLAIM_MB
#   ROOM     advise mode only: memory is ok, at least ROOM_MIN more agents fit,
#            and working Brains are due a nudge (every ROOM_EVERY_MIN minutes
#            each, skipping any that declined in the last ROOM_DECLINE_MIN)
#   DONE     quadrant agents have gone idle (finished?), listed as
#            id:MB:idle-minutes; each quadrant at most once per DONE_EVERY_MIN
#   BRAIN_CLOSED  a Brain that was running has been gone for two samples
#   TICK     TICK_MIN minutes passed (periodic review)
#   ERROR    the sampler failed three times in a row
#   ALREADY_RUNNING  another watcher owns this state folder
#
# Usage:
#   fleet-watch.sh --once            one sample, update files, print the summary
#   fleet-watch.sh --exit-on-event   exit after the first event (or TICK). Run it
#                                    as a background job in a Claude Code Brain:
#                                    each exit wakes the Brain.
#   fleet-watch.sh                   run until stopped, printing events
#   fleet-watch.sh --stop            stop the running watcher for this folder
#   fleet-watch.sh --decline ID      Brain ID has nothing to split: pause its ROOM nudges
#   Options: --interval SEC, --max-minutes N
set -u

CS_DIR=$(cd "$(dirname "$0")" && pwd)
. "$CS_DIR/lib.sh"

once=0
exit_on_event=0
stop=0
max_sec=0
decline_id=
while [ $# -gt 0 ]; do
  case $1 in
    --once) once=1 ;;
    --stop) stop=1 ;;
    --decline) shift; decline_id=${1:?--decline needs a Brain id} ;;
    --exit-on-event) exit_on_event=1 ;;
    --interval) shift; INTERVAL_SEC=${1:?--interval needs seconds} ;;
    --max-minutes) shift; max_sec=$((${1:?--max-minutes needs a number} * 60)) ;;
    --max-seconds) shift; max_sec=${1:?--max-seconds needs a number} ;;
    -h | --help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
    *) echo "fleet-watch.sh: unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done
[ "$exit_on_event" = 1 ] && [ "$max_sec" = 0 ] && max_sec=$((TICK_MIN * 60))

mkdir -p "$CS_HOME" || exit 1
snap=$CS_HOME/snapshot.json
hist=$CS_HOME/history.jsonl
evlog=$CS_HOME/events.log
errlog=$CS_HOME/errors.log
pidf=$CS_HOME/watch.pid
statef=$CS_HOME/watch.state
roomf=$CS_HOME/room.state
declf=$CS_HOME/decline.log
donef=$CS_HOME/done.state

if [ -n "$decline_id" ]; then
  case $decline_id in *[!A-Za-z0-9_-]*) echo "fleet-watch.sh: not a Brain id: $decline_id" >&2; exit 2 ;; esac
  printf '%s %s\n' "$(date +%s)" "$decline_id" >>"$declf"
  echo "ok: no ROOM nudges for $decline_id for $ROOM_DECLINE_MIN minutes"
  exit 0
fi

emit() {
  ev_line="[codus-supervisor] $(date -u +%Y-%m-%dT%H:%M:%SZ) $*"
  printf '%s\n' "$ev_line"
  printf '%s\n' "$ev_line" >>"$evlog"
}

# ---- one watcher per state folder --------------------------------------------
# watcher_pid: the pid in watch.pid if that process is still a fleet-watch.
watcher_pid() {
  [ -f "$pidf" ] || return 1
  wp=$(cat "$pidf" 2>/dev/null)
  [ -n "$wp" ] && [ "$wp" != $$ ] && kill -0 "$wp" 2>/dev/null &&
    ps -o command= -p "$wp" 2>/dev/null | grep -q fleet-watch && echo "$wp"
}

if [ "$stop" = 1 ]; then
  if wp=$(watcher_pid); then
    kill "$wp" 2>/dev/null
    # Wait until it is really gone, so a restart right after this cannot race it.
    i=0
    while kill -0 "$wp" 2>/dev/null && [ "$i" -lt 50 ]; do sleep 0.2; i=$((i + 1)); done
    if kill -0 "$wp" 2>/dev/null; then
      echo "watcher pid=$wp did not stop within 10 seconds" >&2
      exit 1
    fi
    echo "stopped watcher pid=$wp"
  else
    echo "no watcher running for $CS_HOME"
  fi
  exit 0
fi

if [ "$once" = 0 ]; then
  if old=$(watcher_pid); then
    emit "ALREADY_RUNNING pid=$old home=$CS_HOME"
    exit 0
  fi
  echo $$ >"$pidf"
  sleep_pid=
  trap 'rm -f "$pidf"' EXIT
  # A trapped signal waits for a foreground command to finish, so the loop
  # sleeps in the background and waits on it; this kills that sleep too.
  trap '[ -n "$sleep_pid" ] && kill "$sleep_pid" 2>/dev/null; exit 0' INT TERM HUP
fi

# ---- remembered state (survives restarts, so hysteresis and cooldowns hold) --
last_state=
pending_state=
pending_count=0
last_reclaim=0
brains_seen=
brains_missing=
brains_known=0
if [ -f "$statef" ]; then
  while IFS='=' read -r k v; do
    case $k in
      last_state) last_state=$v ;;
      pending_state) pending_state=$v ;;
      pending_count) pending_count=$v ;;
      last_reclaim) last_reclaim=$v ;;
      brains_seen) brains_seen=$v; brains_known=1 ;;
      brains_missing) brains_missing=$v ;;
    esac
  done <"$statef"
fi
case $pending_count in '' | *[!0-9]*) pending_count=0 ;; esac
case $last_reclaim in '' | *[!0-9]*) last_reclaim=0 ;; esac

save_state() {
  printf 'last_state=%s\npending_state=%s\npending_count=%s\nlast_reclaim=%s\nbrains_seen=%s\nbrains_missing=%s\n' \
    "$last_state" "$pending_state" "$pending_count" "$last_reclaim" "$brains_seen" "$brains_missing" \
    >"$statef.tmp" && mv "$statef.tmp" "$statef"
}

# stamp_ids FILE "id,id,..." NOW: record NOW as the last time for each id.
stamp_ids() {
  {
    [ -f "$1" ] && awk -v t=",$2," 'index(t, "," $1 ",") == 0' "$1"
    for sid in $(printf '%s' "$2" | tr ',' ' '); do printf '%s %s\n' "$sid" "$3"; done
  } >"$1.tmp" && mv "$1.tmp" "$1"
}

started=$(date +%s)
fails=0
while :; do
  fired=0
  snap_tmp=$snap.$$.tmp
  kv=$("$CS_DIR/fleet-sample.sh" --out "$snap_tmp" 2>>"$errlog")
  rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$kv" ] || [ ! -s "$snap_tmp" ]; then
    fails=$((fails + 1))
    rm -f "$snap_tmp"
    if [ "$fails" -ge 3 ]; then
      emit "ERROR sampler failed $fails times in a row (exit $rc); see $errlog"
      fails=0
      [ "$exit_on_event" = 1 ] && exit 1
    fi
    [ "$once" = 1 ] && { echo "fleet-watch.sh: sampler failed (exit $rc); see $errlog" >&2; exit 1; }
  else
    fails=0
    mv "$snap_tmp" "$snap"
    state= pressure= free_pct= swap_used_mb= swap_total_mb= agents= busy= idle= idle_mb= est_extra= reason= idle_list= summary= active_brains= brains_live= idle_quadrants=
    while IFS= read -r line; do
      v=${line#*=}
      case $line in
        state=*) state=$v ;;
        pressure=*) pressure=$v ;;
        free_pct=*) free_pct=$v ;;
        swap_used_mb=*) swap_used_mb=$v ;;
        swap_total_mb=*) swap_total_mb=$v ;;
        agents=*) agents=$v ;;
        busy=*) busy=$v ;;
        idle=*) idle=$v ;;
        idle_mb=*) idle_mb=$v ;;
        est_extra=*) est_extra=$v ;;
        reason=*) reason=$v ;;
        idle_list=*) idle_list=$v ;;
        active_brains=*) active_brains=$v ;;
        brains_live=*) brains_live=$v ;;
        idle_quadrants=*) idle_quadrants=$v ;;
        summary=*) summary=$v ;;
      esac
    done <<EOF
$kv
EOF
    now=$(date +%s)
    printf '{"t":"%s","state":"%s","pressure":"%s","free_pct":%s,"swap_used_mb":%s,"agents":%s,"busy":%s,"idle":%s,"idle_mb":%s,"est_extra":%s}\n' \
      "$(date -u -r "$now" +%Y-%m-%dT%H:%M:%SZ)" "$state" "$pressure" "${free_pct:-0}" "${swap_used_mb:-0}" \
      "${agents:-0}" "${busy:-0}" "${idle:-0}" "${idle_mb:-0}" "${est_extra:-0}" >>"$hist"
    if [ "$(wc -l <"$hist" | tr -d ' ')" -gt $((HISTORY_MAX_LINES + 100)) ]; then
      tail -n "$HISTORY_MAX_LINES" "$hist" >"$hist.tmp" && mv "$hist.tmp" "$hist"
    fi

    if [ "$once" = 1 ]; then
      printf '%s\n' "$summary"
      exit 0
    fi

    details="pressure=$pressure available=${free_pct}% swap=${swap_used_mb}/${swap_total_mb}MB agents=$agents busy=$busy idle=$idle idle_mb=$idle_mb room=$est_extra brains=${active_brains:-none} reason=\"$reason\""
    if [ -z "$last_state" ]; then
      # First run: this reading is the baseline, not a change.
      last_state=$state
    elif [ "$state" != "$last_state" ]; then
      if [ "$state" = "$pending_state" ]; then
        pending_count=$((pending_count + 1))
      else
        pending_state=$state
        pending_count=1
      fi
      if [ "$state" = critical ] || [ "$pending_count" -ge 2 ]; then
        emit "STATE $last_state->$state $details"
        last_state=$state
        pending_state=
        pending_count=0
        fired=1
      fi
    else
      pending_state=
      pending_count=0
    fi

    if [ "$state" != ok ] && [ "${idle_mb:-0}" -ge "$RECLAIM_MB" ] &&
      [ $((now - last_reclaim)) -ge $((RECLAIM_COOLDOWN_MIN * 60)) ]; then
      emit "RECLAIM idle agents hold ${idle_mb}MB while memory is $state: $idle_list"
      last_reclaim=$now
      fired=1
    fi

    # Advise mode: nudge working Brains while there is room, each at most every
    # ROOM_EVERY_MIN minutes, skipping Brains that declined recently.
    if [ "$MODE" = advise ] && [ "$state" = ok ] && [ "${est_extra:-0}" -ge "$ROOM_MIN" ] &&
      [ -n "$active_brains" ]; then
      targets=
      for b in $(printf '%s' "$active_brains" | tr ',' ' '); do
        declined=$(awk -v id="$b" '$2 == id { t = $1 } END { print t + 0 }' "$declf" 2>/dev/null || echo 0)
        [ $((now - ${declined:-0})) -lt $((ROOM_DECLINE_MIN * 60)) ] && continue
        nudged=$(awk -v id="$b" '$1 == id { t = $2 } END { print t + 0 }' "$roomf" 2>/dev/null || echo 0)
        [ $((now - ${nudged:-0})) -lt $((ROOM_EVERY_MIN * 60)) ] && continue
        targets="$targets${targets:+,}$b"
      done
      if [ -n "$targets" ]; then
        emit "ROOM room=$est_extra targets=$targets available=${free_pct}% reason=\"$reason\""
        stamp_ids "$roomf" "$targets" "$now"
        fired=1
      fi
    fi

    # Quadrant agents gone idle: probably finished. Each at most every DONE_EVERY_MIN.
    if [ -n "$idle_quadrants" ]; then
      due=
      due_ids=
      for q in $(printf '%s' "$idle_quadrants" | tr ',' ' '); do
        qid=${q%%:*}
        stamped=$(awk -v id="$qid" '$1 == id { t = $2 } END { print t + 0 }' "$donef" 2>/dev/null || echo 0)
        [ $((now - ${stamped:-0})) -lt $((DONE_EVERY_MIN * 60)) ] && continue
        due="$due${due:+,}$q"
        due_ids="$due_ids${due_ids:+,}$qid"
      done
      if [ -n "$due" ]; then
        emit "DONE quadrants=$due (id:MB:idle-minutes)"
        stamp_ids "$donef" "$due_ids" "$now"
        fired=1
      fi
    fi

    # Brains that were running and are gone for a second sample in a row.
    # (One missed sample is allowed for a restart or provider switch.)
    if [ "$brains_known" = 1 ]; then
      closed=
      missing_now=
      for b in $(printf '%s' "$brains_seen" | tr ',' ' '); do
        case ",$brains_live," in *",$b,"*) continue ;; esac
        case ",$brains_missing," in
          *",$b,"*) closed="$closed${closed:+,}$b" ;;
          *) missing_now="$missing_now${missing_now:+,}$b" ;;
        esac
      done
      brains_missing=$missing_now
      if [ -n "$closed" ]; then
        emit "BRAIN_CLOSED brains=$closed"
        fired=1
      fi
    fi
    brains_seen=$brains_live
    [ -n "$brains_missing" ] && brains_seen="$brains_seen${brains_seen:+,}$brains_missing"
    brains_known=1
    save_state
  fi

  [ "$fired" = 1 ] && [ "$exit_on_event" = 1 ] && exit 0
  if [ "$max_sec" -gt 0 ] && [ $(($(date +%s) - started)) -ge "$max_sec" ]; then
    emit "TICK ${summary:-no reading}"
    exit 0
  fi
  sleep "$INTERVAL_SEC" &
  sleep_pid=$!
  wait "$sleep_pid" 2>/dev/null
  sleep_pid=
done
