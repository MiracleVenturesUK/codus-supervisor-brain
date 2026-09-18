#!/bin/sh
# tests/run.sh: offline tests for the sampler, watcher and installer.
# Uses fixture process tables (CS_TEST_* variables), a temporary HOME and a
# temporary state folder, so nothing touches your real setup. Needs jq.
# The final "live" check reads this Mac for real (skipped off macOS).
set -u

root=$(cd "$(dirname "$0")/.." && pwd)
S=$root/skills/codus-supervisor/scripts
command -v jq >/dev/null 2>&1 || { echo "tests need jq (preinstalled on macOS 15 and later)"; exit 2; }

pass=0
failed=0
ok() { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { failed=$((failed + 1)); printf '  FAIL %s\n' "$1"; [ $# -gt 1 ] && printf '       %s\n' "$2"; }
check() { # name expected actual
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2], got [$3]"; fi
}

# Run "$@" but kill it after $1 seconds (macOS has no timeout(1) by default).
run_to() {
  t=$1
  shift
  "$@" &
  rt_pid=$!
  # The watchdog must not hold the caller's stdout, or $(run_to ...) waits for it.
  (sleep "$t" && kill "$rt_pid") >/dev/null 2>&1 &
  rt_watch=$!
  wait "$rt_pid"
  rt_rc=$?
  kill "$rt_watch" 2>/dev/null
  wait "$rt_watch" 2>/dev/null
  return $rt_rc
}

work=$(mktemp -d "${TMPDIR:-/tmp}/codus-supervisor-tests.XXXXXX")
trap 'rm -rf "$work"' EXIT

# Isolate from the caller's environment and real files.
for k in INTERVAL_SEC TICK_MIN IDLE_MIN BUSY_MIN FREE_TIGHT_PCT FREE_CRIT_PCT RESERVE_PCT \
  SWAP_HEAVY_PCT MAX_EXTRA_AGENTS DEFAULT_AGENT_MB RECLAIM_MB RECLAIM_COOLDOWN_MIN \
  HISTORY_MAX_LINES AGENT_BINARIES MODE COOLDOWN_MIN CODUS_SUPERVISOR_CONFIG CLAUDE_CONFIG_DIR; do
  unset "$k"
done
real_home=$HOME
export HOME="$work/home"
mkdir -p "$HOME"
export CODUS_SUPERVISOR_HOME="$work/state"

echo "syntax"
syntax_ok=1
for f in "$S/lib.sh" "$S/fleet-sample.sh" "$S/fleet-watch.sh" "$root/install.sh" "$root/tests/run.sh"; do
  for sh in sh bash dash; do
    command -v "$sh" >/dev/null 2>&1 || continue
    "$sh" -n "$f" 2>/dev/null || { bad "$sh -n ${f#"$root"/}"; syntax_ok=0; }
  done
done
[ "$syntax_ok" = 1 ] && ok "all scripts parse under sh, bash and dash (where installed)"

# ---- fixtures ------------------------------------------------------------------
NOW=1790000000
cat >"$work/ps" <<'EOF'
  100     1  204800   1.0     01:10:00 claude --resume 11111111-2222-3333-4444-555555555555 --dangerously-skip-permissions --strict-mcp-config --mcp-config {"mcpServers":{"codus":{"type":"http","url":"http://127.0.0.1:6789/mcp/7"}}}
  101   100  512000   0.5        10:00 node /tmp/proj/node_modules/.bin/vitest
  200     1  204800   0.5  2-03:04:05 claude --effort max --dangerously-skip-permissions
  300     1  204800   0.2     05:00:00 claude --model sonnet --dangerously-skip-permissions
  400     1  102400   0.0        30:00 claude --dangerously-skip-permissions
  500     1  204800  25.0        45:00 claude
  600     1  102400   0.3     03:00:00 codex --no-alt-screen -c mcp_servers.codus.url="http://127.0.0.1:6789/mcp/12"
  700     1  307200   2.0     09:00:00 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome
  701   700  204800   1.0     09:00:00 /Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)
  800     1  153600   0.1     09:00:00 /Applications/Claude.app/Contents/MacOS/Claude
EOF
tab=$(printf '\t')
{
  printf '100%s/tmp/proj\n' "$tab"
  printf '200%s/Users/someone/.codus/brains/brain-abc\n' "$tab"
  printf '300%s/Users/someone/.codus/codus-brain\n' "$tab"
  printf '400%s/Users/someone/.codus/analyst-worker\n' "$tab"
  printf '500%s/tmp/we"ird\\path\n' "$tab"
  printf '600%s/tmp/other proj\n' "$tab"
} >"$work/cwd"
{
  printf '100%s%s\n' "$tab" $((NOW - 60))
  printf '200%s%s\n' "$tab" $((NOW - 3600))
  printf '300%s%s\n' "$tab" $((NOW - 600))
  printf '500%s%s\n' "$tab" $((NOW - 7200))
  printf '600%s%s\n' "$tab" $((NOW - 30))
} >"$work/activity"

export CS_TEST_PS_FILE="$work/ps" CS_TEST_CWD_FILE="$work/cwd" CS_TEST_ACTIVITY_FILE="$work/activity"
export CS_TEST_NOW=$NOW CS_TEST_TOTAL_MB=16384 CS_TEST_PRESSURE_LEVEL=1 CS_TEST_FREE_PCT=60
export CS_TEST_SWAP="1000 4096" CS_TEST_COMPRESSED_MB=100

echo "sampler: agents"
j=$("$S/fleet-sample.sh")
if printf '%s' "$j" | jq -e . >/dev/null 2>&1; then ok "JSON is valid, including a path with a quote and a backslash"; else bad "JSON is valid" "$j"; fi
q() { printf '%s' "$j" | jq -r "$1"; }
check "six agents; the Claude desktop app and child processes are not agents" 6 "$(q '.agents.total')"
check "quadrant from /mcp/<n>" "quadrant 7 busy" "$(q '.agent_list[] | select(.pid==100) | "\(.role) \(.component_id) \(.status)"')"
check "quadrant tree includes its child process" 700 "$(q '.agent_list[] | select(.pid==100) | .tree_mb')"
check "session id from --resume" "11111111-2222-3333-4444-555555555555" "$(q '.agent_list[] | select(.pid==100) | .session_id')"
check "Brain from ~/.codus/brains/<id>, idle after an hour" "brain brain-abc idle" "$(q '.agent_list[] | select(.pid==200) | "\(.role) \(.brain_id) \(.status)"')"
check "main Brain from ~/.codus/codus-brain" "brain main recent" "$(q '.agent_list[] | select(.pid==300) | "\(.role) \(.brain_id) \(.status)"')"
check "codus helper agent" "codus analyst-worker unknown" "$(q '.agent_list[] | select(.pid==400) | "\(.role) \(.name) \(.status)"')"
check "CPU makes an old session busy" "other busy" "$(q '.agent_list[] | select(.pid==500) | "\(.role) \(.status)"')"
check "odd path survives escaping" '/tmp/we"ird\path' "$(q '.agent_list[] | select(.pid==500) | .cwd')"
check "codex quadrant" "codex quadrant 12 busy" "$(q '.agent_list[] | select(.pid==600) | "\(.binary) \(.role) \(.component_id) \(.status)"')"
check "uptime from dd-hh:mm:ss" 3064 "$(q '.agent_list[] | select(.pid==200) | .up_min')"
check "Chrome grouped by app bundle" "Google Chrome 500" "$(q '.top_groups[] | select(.name=="Google Chrome") | "\(.name) \(.mb)"')"
check "idle memory counts idle agents only" 200 "$(q '.agents.idle_mb')"
check "room: (60% of 16 GB - 30% reserve) / 250 MB, capped at 4" "ok 4" "$(q '"\(.capacity.state) \(.capacity.est_extra_agents)"')"

echo "sampler: capacity states"
st() { CS_TEST_PRESSURE_LEVEL=$1 CS_TEST_FREE_PCT=$2 "$S/fleet-sample.sh" --kv | sed -n 's/^state=//p'; }
check "level 1, 60% available -> ok" ok "$(st 1 60)"
check "level 2 -> tight" tight "$(st 2 60)"
check "level 4 -> critical" critical "$(st 4 60)"
check "15% available -> tight" tight "$(st 1 15)"
check "5% available -> critical" critical "$(st 1 5)"
check "no readings -> unknown" unknown "$(st 0 -1)"
check "room is 0 when tight" 0 "$(CS_TEST_PRESSURE_LEVEL=2 "$S/fleet-sample.sh" --kv | sed -n 's/^est_extra=//p')"
check "no cap: 19 agents fit" 19 "$(MAX_EXTRA_AGENTS=50 "$S/fleet-sample.sh" --kv | sed -n 's/^est_extra=//p')"
check "heavy swap halves room" 9 "$(MAX_EXTRA_AGENTS=50 CS_TEST_SWAP="6000 8192" "$S/fleet-sample.sh" --kv | sed -n 's/^est_extra=//p')"
check "config.env is read and env wins" "9 3" "$(mkdir -p "$CODUS_SUPERVISOR_HOME" && printf 'MAX_EXTRA_AGENTS=9\nBUSY_MIN=7\n' >"$CODUS_SUPERVISOR_HOME/config.env" &&
  BUSY_MIN=3 "$S/fleet-sample.sh" | jq -r '"\(.config.max_extra_agents) \(.config.busy_min)"')"
check "bad number falls back to default" 4 "$(MAX_EXTRA_AGENTS=lots "$S/fleet-sample.sh" 2>/dev/null | jq -r '.config.max_extra_agents')"
rm -f "$CODUS_SUPERVISOR_HOME/config.env"
summary=$("$S/fleet-sample.sh" --summary)
case $summary in "ok: memory pressure normal, 60% available; "*) ok "summary line" ;; *) bad "summary line" "$summary" ;; esac

echo "watcher"
W=$S/fleet-watch.sh
H=$CODUS_SUPERVISOR_HOME
reset_state() { rm -rf "$H"; mkdir -p "$H"; [ $# -gt 0 ] && printf '%s\n' "$@" >"$H/watch.state"; return 0; }

reset_state
out=$(run_to 20 "$W" --once)
case $out in ok:*) ok "--once prints the summary" ;; *) bad "--once prints the summary" "$out" ;; esac
jq -e .schema "$H/snapshot.json" >/dev/null 2>&1 && ok "--once writes snapshot.json" || bad "--once writes snapshot.json"
check "--once appends one history line" 1 "$(wc -l <"$H/history.jsonl" | tr -d ' ')"
[ ! -f "$H/watch.state" ] && ok "--once leaves watch.state alone" || bad "--once leaves watch.state alone"

reset_state
out=$(run_to 20 "$W" --exit-on-event --interval 1 --max-seconds 2)
case $out in *" TICK ok: "*) ok "first run is a silent baseline, then TICK" ;; *) bad "baseline then TICK" "$out" ;; esac
check "baseline saved" "last_state=ok" "$(grep '^last_state=' "$H/watch.state")"

reset_state last_state=ok
out=$(CS_TEST_PRESSURE_LEVEL=4 run_to 20 "$W" --exit-on-event --interval 1 --max-seconds 15)
case $out in *" STATE ok->critical "*) ok "critical fires on the first sample" ;; *) bad "critical fires at once" "$out" ;; esac

reset_state last_state=ok
out=$(CS_TEST_PRESSURE_LEVEL=2 run_to 20 "$W" --exit-on-event --interval 1 --max-seconds 15)
case $out in *" STATE ok->tight "*) ok "tight fires after two samples" ;; *) bad "tight after two samples" "$out" ;; esac
check "event also logged" 1 "$(grep -c 'STATE ok->tight' "$H/events.log")"

reset_state last_state=tight
out=$(CS_TEST_PRESSURE_LEVEL=2 RECLAIM_MB=100 run_to 20 "$W" --exit-on-event --interval 1 --max-seconds 15)
case $out in *" RECLAIM idle agents hold 200MB while memory is tight: brain-abc 200MB 60m"*) ok "RECLAIM names the idle agents" ;; *) bad "RECLAIM" "$out" ;; esac
out=$(CS_TEST_PRESSURE_LEVEL=2 RECLAIM_MB=100 run_to 20 "$W" --exit-on-event --interval 1 --max-seconds 2)
case $out in *RECLAIM*) bad "RECLAIM cooldown holds across restarts" "$out" ;; *) ok "RECLAIM cooldown holds across restarts" ;; esac

reset_state
"$W" --interval 1 >"$work/w1.out" 2>&1 &
w1=$!
i=0
while [ ! -f "$H/watch.pid" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
out=$(run_to 10 "$W" --exit-on-event --interval 1 --max-seconds 5)
case $out in *ALREADY_RUNNING*) ok "a second watcher refuses to start" ;; *) bad "second watcher refuses" "$out" ;; esac
out=$("$W" --stop)
case $out in "stopped watcher pid=$w1") ok "--stop ends the running watcher" ;; *) bad "--stop" "$out" ;; esac
wait "$w1" 2>/dev/null
[ ! -f "$H/watch.pid" ] && ok "pidfile removed on exit" || bad "pidfile removed on exit"

echo "installer"
dest=$work/skills
if "$root/install.sh" --dest "$dest" >/dev/null 2>&1; then ok "install"; else bad "install"; fi
[ -x "$dest/codus-supervisor/scripts/fleet-watch.sh" ] && [ -f "$dest/codus-capacity-check/SKILL.md" ] &&
  ok "both skills installed, scripts executable" || bad "both skills installed"
[ -f "$CODUS_SUPERVISOR_HOME/config.env" ] && ok "default config.env written" || bad "default config.env written"
"$root/install.sh" --dest "$dest" >/dev/null 2>&1 && ok "reinstall over our own copy" || bad "reinstall"
mkdir -p "$work/skills2/codus-supervisor" && echo mine >"$work/skills2/codus-supervisor/SKILL.md"
if "$root/install.sh" --dest "$work/skills2" >/dev/null 2>&1; then bad "refuses to replace a foreign skill"; else ok "refuses to replace a foreign skill"; fi
check "foreign skill untouched" mine "$(cat "$work/skills2/codus-supervisor/SKILL.md")"
"$root/install.sh" --dest "$dest" --uninstall >/dev/null 2>&1
[ ! -e "$dest/codus-supervisor" ] && [ ! -e "$dest/codus-capacity-check" ] && ok "uninstall removes both" || bad "uninstall"
[ -d "$CODUS_SUPERVISOR_HOME" ] && ok "uninstall keeps settings" || bad "uninstall keeps settings"
if CODUS_SUPERVISOR_HOME=$HOME "$root/install.sh" --dest "$dest" --purge >/dev/null 2>&1; then
  bad "purge refuses to delete HOME"
else
  [ -d "$HOME" ] && ok "purge refuses to delete HOME" || bad "purge refuses to delete HOME"
fi
"$root/install.sh" --dest "$dest" --purge >/dev/null 2>&1
[ ! -e "$CODUS_SUPERVISOR_HOME" ] && ok "purge deletes the state folder" || bad "purge deletes the state folder"

echo "live (this machine, read-only)"
unset CS_TEST_PS_FILE CS_TEST_CWD_FILE CS_TEST_ACTIVITY_FILE CS_TEST_NOW CS_TEST_TOTAL_MB \
  CS_TEST_PRESSURE_LEVEL CS_TEST_FREE_PCT CS_TEST_SWAP CS_TEST_COMPRESSED_MB
if [ "$(uname -s)" = Darwin ]; then
  export HOME=$real_home
  if "$S/fleet-sample.sh" | jq -e '.schema == 1 and (.memory.total_mb > 0) and (.capacity.state | IN("ok","tight","critical"))' >/dev/null; then
    ok "live snapshot: $("$S/fleet-sample.sh" --summary)"
  else
    bad "live snapshot"
  fi
else
  echo "  skip (not macOS)"
fi

echo
echo "$pass passed, $failed failed"
[ "$failed" -eq 0 ]
