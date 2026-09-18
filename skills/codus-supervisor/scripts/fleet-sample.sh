#!/bin/sh
# fleet-sample.sh: one snapshot of this Mac's memory and every codus agent.
# Plain shell + awk, so it costs no tokens. macOS only (sysctl, vm_stat, lsof).
#
# Usage:
#   fleet-sample.sh              JSON snapshot on stdout
#   fleet-sample.sh --summary    one human-readable line
#   fleet-sample.sh --kv         KEY=VALUE lines
#   fleet-sample.sh --out FILE   write the JSON to FILE, print KEY=VALUE lines
#
# Settings: lib.sh and config.example.env. CS_TEST_* variables replace live
# readings in tests; they are not meant for normal use.
set -u

CS_DIR=$(cd "$(dirname "$0")" && pwd)
. "$CS_DIR/lib.sh"

mode=json
out_file=
while [ $# -gt 0 ]; do
  case $1 in
    --summary) mode=summary ;;
    --kv) mode=kv ;;
    --out)
      [ $# -ge 2 ] || { echo "fleet-sample.sh: --out needs a file" >&2; exit 2; }
      shift
      out_file=$1
      mode=file
      ;;
    -h | --help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
    *) echo "fleet-sample.sh: unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

if [ "$(uname -s)" != Darwin ] && [ -z "${CS_TEST_PS_FILE-}" ]; then
  echo "fleet-sample.sh: only macOS is supported so far" >&2
  exit 3
fi

tmp=$(mktemp -d "${TMPDIR:-/tmp}/codus-supervisor.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT
trap 'exit 130' INT TERM
TAB=$(printf '\t')

now=${CS_TEST_NOW:-$(date +%s)}
iso=$(date -u -r "$now" +%Y-%m-%dT%H:%M:%SZ)

# ---- machine ---------------------------------------------------------------
if [ -n "${CS_TEST_TOTAL_MB-}" ]; then
  total_mb=$CS_TEST_TOTAL_MB
else
  total_mb=$(($(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1048576))
fi
# kern.memorystatus_vm_pressure_level: 1 normal, 2 warn, 4 critical.
level=${CS_TEST_PRESSURE_LEVEL:-$(sysctl -n kern.memorystatus_vm_pressure_level 2>/dev/null || echo 0)}
# kern.memorystatus_level: % of memory available (what `memory_pressure` prints).
free_pct=${CS_TEST_FREE_PCT:-$(sysctl -n kern.memorystatus_level 2>/dev/null || echo -1)}
if [ -n "${CS_TEST_SWAP-}" ]; then
  swap=$CS_TEST_SWAP
else
  swap=$(sysctl -n vm.swapusage 2>/dev/null | awk '
    function mb(v,   n, u) {
      n = v + 0; u = substr(v, length(v))
      if (u == "G") n *= 1024; else if (u == "K") n /= 1024
      return int(n + 0.5)
    }
    { for (i = 1; i < NF; i++) { if ($i == "total") t = mb($(i + 2)); if ($i == "used") s = mb($(i + 2)) } }
    END { print (s + 0) " " (t + 0) }')
fi
swap_used_mb=${swap% *}
swap_total_mb=${swap#* }
compressed_mb=${CS_TEST_COMPRESSED_MB:-$(vm_stat 2>/dev/null | awk '
  /page size of/ { for (i = 1; i <= NF; i++) if ($i == "of") ps = $(i + 1) }
  /occupied by compressor/ { v = $NF; gsub(/\./, "", v); pages = v }
  END { if (ps == "") ps = 16384; print int(pages * ps / 1048576) }')}
ncpu=$(sysctl -n hw.ncpu 2>/dev/null || echo 0)
load1=$(sysctl -n vm.loadavg 2>/dev/null | awk '{ print $2 + 0 }')
os_ver=$(sw_vers -productVersion 2>/dev/null || echo unknown)

# ---- processes -------------------------------------------------------------
if [ -n "${CS_TEST_PS_FILE-}" ]; then
  cp "$CS_TEST_PS_FILE" "$tmp/ps"
else
  LC_ALL=C ps -axo pid=,ppid=,rss=,pcpu=,etime=,command= >"$tmp/ps" 2>/dev/null
fi

# Agent processes: the first word of the command is one of AGENT_BINARIES.
awk -v bins="$AGENT_BINARIES" '
  BEGIN { n = split(bins, b, " "); for (i = 1; i <= n; i++) want[b[i]] = 1 }
  {
    if (!match($0, /^ *[0-9]+ +[0-9]+ +[0-9]+ +[0-9.]+ +[0-9:-]+ +/)) next
    cmd = substr($0, RLENGTH + 1)
    first = cmd; sub(/ .*/, "", first); sub(/.*\//, "", first)
    if (first in want) { split($0, f, " "); print f[1] "\t" first "\t" cmd }
  }' "$tmp/ps" >"$tmp/agents"

# Working folder of each agent.
if [ -n "${CS_TEST_CWD_FILE-}" ]; then
  cp "$CS_TEST_CWD_FILE" "$tmp/cwd"
else
  : >"$tmp/cwd"
  pids=$(cut -f1 "$tmp/agents" | paste -s -d , -)
  if [ -n "$pids" ]; then
    lsof -a -d cwd -Fn -p "$pids" 2>/dev/null |
      awk '/^p/ { p = substr($0, 2) } /^n/ { print p "\t" substr($0, 2) }' >"$tmp/cwd"
  fi
fi

# ---- last activity (newest session file write) -------------------------------
cs_mtime() { stat -f %m "$1" 2>/dev/null; }
# Claude Code keeps sessions in <config>/projects/<folder with non-alphanumerics as ->/.
cs_slug() { printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g'; }

claude_roots() {
  [ -n "${CLAUDE_CONFIG_DIR-}" ] && printf '%s\n' "$CLAUDE_CONFIG_DIR/projects"
  printf '%s\n' "$HOME/.claude/projects"
  # codus can give agents a per-account Claude config folder.
  for d in "$HOME"/.codus/accounts/* "$HOME"/.codus/accounts/.[!.]*; do
    [ -d "$d/projects" ] && printf '%s\n' "$d/projects"
  done
  return 0
}

build_codex_index() {
  : >"$tmp/codex_index"
  croot=${CODEX_HOME:-$HOME/.codex}/sessions
  [ -d "$croot" ] || return 0
  find "$croot" -name 'rollout-*.jsonl' -mtime -3 2>/dev/null | while IFS= read -r f; do
    c=$(head -n 1 "$f" | sed -n 's/.*"cwd":"\([^"]*\)".*/\1/p')
    [ -n "$c" ] && printf '%s\t%s\n' "$(cs_mtime "$f")" "$c"
  done >"$tmp/codex_index"
}

if [ -n "${CS_TEST_ACTIVITY_FILE-}" ]; then
  cp "$CS_TEST_ACTIVITY_FILE" "$tmp/activity"
else
  : >"$tmp/activity"
  claude_roots >"$tmp/roots"
  codex_indexed=0
  while IFS="$TAB" read -r pid bin cmd; do
    cwd=$(awk -F '\t' -v p="$pid" '$1 == p { print $2; exit }' "$tmp/cwd")
    [ -n "$cwd" ] || continue
    last=0
    case $bin in
      claude)
        slug=$(cs_slug "$cwd")
        sid=$(printf '%s' "$cmd" | sed -n 's/.*--resume \([0-9a-fA-F-]\{36\}\).*/\1/p')
        while IFS= read -r root; do
          dir=$root/$slug
          [ -d "$dir" ] || continue
          newest=$(ls -t "$dir"/*.jsonl 2>/dev/null | head -n 1)
          for f in "$newest" ${sid:+"$dir/$sid.jsonl"}; do
            [ -n "$f" ] && [ -f "$f" ] || continue
            m=$(cs_mtime "$f")
            [ -n "$m" ] && [ "$m" -gt "$last" ] && last=$m
          done
        done <"$tmp/roots"
        ;;
      codex)
        [ "$codex_indexed" = 1 ] || { build_codex_index; codex_indexed=1; }
        m=$(awk -F '\t' -v c="$cwd" '$2 == c && $1 + 0 > best { best = $1 + 0 } END { print best + 0 }' "$tmp/codex_index")
        [ "$m" -gt 0 ] && last=$m
        ;;
    esac
    [ "$last" -gt 0 ] && printf '%s\t%s\n' "$pid" "$last" >>"$tmp/activity"
  done <"$tmp/agents"
fi

# ---- plan usage (optional: codus's local cache, needs jq) ----------------------
: >"$tmp/usage"
if command -v jq >/dev/null 2>&1; then
  for p in claude codex; do
    f=$HOME/.codus/$p-usage-cache.json
    [ -f "$f" ] || continue
    jq -c --arg p "$p" '[.accounts[]? | {provider: $p, account: (.email // .identity // null),
        ok: (.ok // null), limits: [.limits[]? | {label, percent, resets_at: .resetsAt}]}]' \
      "$f" 2>/dev/null
  done | jq -s -c 'add // empty' >"$tmp/usage" 2>/dev/null || : >"$tmp/usage"
fi

# ---- assemble ----------------------------------------------------------------
[ "$mode" = file ] || out_file=/dev/stdout

awk -F '\t' \
  -v mode="$mode" -v jout="$out_file" \
  -v f_act="$tmp/activity" -v f_cwd="$tmp/cwd" -v f_agents="$tmp/agents" \
  -v f_ps="$tmp/ps" -v f_usage="$tmp/usage" \
  -v now="$now" -v iso="$iso" -v os_ver="$os_ver" -v ncpu="$ncpu" -v load1="${load1:-0}" \
  -v total_mb="$total_mb" -v level="$level" -v free_pct="$free_pct" \
  -v swap_used_mb="$swap_used_mb" -v swap_total_mb="$swap_total_mb" \
  -v compressed_mb="${compressed_mb:-0}" \
  -v idle_min="$IDLE_MIN" -v busy_min="$BUSY_MIN" -v free_tight="$FREE_TIGHT_PCT" \
  -v free_crit="$FREE_CRIT_PCT" -v reserve_pct="$RESERVE_PCT" -v max_extra="$MAX_EXTRA_AGENTS" \
  -v swap_heavy_pct="$SWAP_HEAVY_PCT" \
  -v default_agent_mb="$DEFAULT_AGENT_MB" -v cs_mode="$MODE" '
function jstr(s,   out, i, c, n) {
  out = ""; n = length(s)
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1)
    if (c == "\\") out = out "\\\\"
    else if (c == "\"") out = out "\\\""
    else if (c == "\t") out = out "\\t"
    else if (c == "\n") out = out "\\n"
    else if (c == "\r") out = out "\\r"
    else out = out c
  }
  return "\"" out "\""
}
function jopt(s) { return (s == "") ? "null" : jstr(s) }
function etime_min(e,   d, n, t) {
  d = 0
  if (index(e, "-")) { d = substr(e, 1, index(e, "-") - 1) + 0; e = substr(e, index(e, "-") + 1) }
  n = split(e, t, ":")
  if (n == 3) return int(d * 1440 + t[1] * 60 + t[2] + t[3] / 60)
  return int(d * 1440 + t[1] + t[2] / 60)
}
function appname(cmd,   a) {
  if (match(cmd, /[^\/]+\.app\//)) return substr(cmd, RSTART, RLENGTH - 5)
  a = cmd; sub(/ .*/, "", a); sub(/.*\//, "", a)
  return a
}
function gb(mb) { return sprintf("%.1f", mb / 1024) }

FILENAME == f_act    { last[$1] = $2; next }
FILENAME == f_cwd    { cwdof[$1] = $2; next }
FILENAME == f_agents { isagent[$1] = 1; abin[$1] = $2; acmd[$1] = $3; norder++; order[norder] = $1; next }
FILENAME == f_usage  { usage = usage $0; next }
FILENAME == f_ps {
  if (!match($0, /^ *[0-9]+ +[0-9]+ +[0-9]+ +[0-9.]+ +[0-9:-]+ +/)) next
  split($0, f, " ")
  p = f[1]; ppidof[p] = f[2]; rss[p] = f[3] / 1024; cpu[p] = f[4] + 0; etm[p] = f[5]
  cmdof[p] = substr($0, RLENGTH + 1)
  next
}

END {
  # Charge every process to its nearest agent ancestor (the agent counts itself).
  for (p in ppidof) {
    a = ""; q = p; depth = 0
    while (q != "" && q != "0" && q != "1" && depth < 64) {
      if (q in isagent) { a = q; break }
      q = ppidof[q]; depth++
    }
    if (a != "") { tree_mb[a] += rss[p]; tree_cpu[a] += cpu[p]; tree_n[a]++ }
    else { g = appname(cmdof[p]); grp_mb[g] += rss[p]; grp_n[g]++ }
  }

  n = 0; nbusy = 0; nidle = 0; nrecent = 0; nunknown = 0; agents_mb = 0; idle_mb = 0
  idle_list = ""
  for (i = 1; i <= norder; i++) {
    a = order[i]
    if (!(a in ppidof)) continue
    n++
    cmd = acmd[a]; cwd = (a in cwdof) ? cwdof[a] : ""
    role = "other"; comp = ""; brain = ""; name = ""
    if (match(cmd, /\/mcp\/[0-9]+/)) { role = "quadrant"; comp = substr(cmd, RSTART + 5, RLENGTH - 5) }
    else if (match(cwd, /\/\.codus\/brains\/[^\/]+$/)) { role = "brain"; brain = substr(cwd, RSTART + 15) }
    else if (cwd ~ /\/\.codus\/codus-brain$/) { role = "brain"; brain = "main" }
    else if (cwd ~ /\/\.codus\//) { role = "codus"; name = cwd; sub(/.*\//, "", name) }
    sid = ""
    if (match(cmd, /--resume [0-9a-fA-F-]+/)) sid = substr(cmd, RSTART + 9, RLENGTH - 9)
    la = -1
    if (a in last) { la = int((now - last[a]) / 60); if (la < 0) la = 0 }
    tm = int(tree_mb[a] + 0.5); tc = tree_cpu[a] + 0
    if ((la >= 0 && la < busy_min) || tc >= 10) st = "busy"
    else if (la < 0) st = "unknown"
    else if (la >= idle_min && tc < 3) st = "idle"
    else st = "recent"
    if (st == "busy") nbusy++; else if (st == "idle") nidle++; else if (st == "recent") nrecent++; else nunknown++
    agents_mb += tm
    label = (role == "quadrant") ? "Q" comp : (role == "brain") ? brain : (role == "codus") ? name : abin[a] ":" a
    if (st == "idle") {
      idle_mb += tm
      idle_list = idle_list (idle_list == "" ? "" : ",") label " " tm "MB " la "m"
    }
    grp_mb["agents (" abin[a] ")"] += tree_mb[a]; grp_n["agents (" abin[a] ")"] += tree_n[a]
    rec[n] = sprintf("{\"pid\":%d,\"binary\":%s,\"role\":%s,\"component_id\":%s,\"brain_id\":%s,\"name\":%s,\"label\":%s,\"cwd\":%s,\"session_id\":%s,\"rss_mb\":%d,\"tree_mb\":%d,\"tree_cpu\":%.1f,\"procs\":%d,\"up_min\":%d,\"last_active_min\":%s,\"status\":%s}",
      a, jstr(abin[a]), jstr(role), (comp == "" ? "null" : comp + 0), jopt(brain), jopt(name), jstr(label), jstr(cwd), jopt(sid),
      int(rss[a] + 0.5), tm, tc, tree_n[a], etime_min(etm[a]), (la < 0 ? "null" : la), jstr(st))
  }

  level_name = (level == 1) ? "normal" : (level == 2) ? "warn" : (level == 4) ? "critical" : "unknown"
  avail = free_pct "% available"
  state = "ok"; reason = "memory pressure normal, " avail
  if (level == 4) { state = "critical"; reason = "macOS memory pressure is critical, " avail }
  else if (free_pct >= 0 && free_pct < free_crit) { state = "critical"; reason = "only " avail }
  else if (level == 2) { state = "tight"; reason = "macOS memory pressure is at warning, " avail }
  else if (free_pct >= 0 && free_pct < free_tight) { state = "tight"; reason = "only " avail }
  else if (level != 1 && free_pct < 0) { state = "unknown"; reason = "could not read memory pressure" }

  # Heavy swap means this Mac ran out recently, even if pressure is normal now.
  swap_heavy = (swap_used_mb >= total_mb * swap_heavy_pct / 100) ? 1 : 0

  avg = (n > 0) ? agents_mb / n : default_agent_mb
  if (avg < 50) avg = default_agent_mb
  reserve_mb = int(total_mb * reserve_pct / 100)
  extra = 0
  if (state == "ok") {
    extra = int((total_mb * free_pct / 100 - reserve_mb) / avg)
    if (swap_heavy) {
      extra = int(extra / 2)
      reason = reason ", but " gb(swap_used_mb) " GB is already swapped out"
    }
    if (extra < 0) extra = 0
    if (extra > max_extra) extra = max_extra
  }

  summary = sprintf("%s: %s; swap %s of %s GB; %d agents (%d busy, %d idle holding %s GB); room for %d more",
    state, reason, gb(swap_used_mb), gb(swap_total_mb), n, nbusy, nidle, gb(idle_mb), extra)

  if (mode == "summary") { print summary; exit }

  if (mode == "json" || mode == "file") {
    # Top memory users outside the agents, plus the agents as groups.
    ng = 0
    for (g in grp_mb) { ng++; gname[ng] = g }
    for (i = 1; i <= ng; i++) for (j = i + 1; j <= ng; j++)
      if (grp_mb[gname[j]] > grp_mb[gname[i]]) { t = gname[i]; gname[i] = gname[j]; gname[j] = t }
    groups = ""
    for (i = 1; i <= ng && i <= 8; i++)
      groups = groups (i > 1 ? "," : "") sprintf("{\"name\":%s,\"mb\":%d,\"procs\":%d}", jstr(gname[i]), int(grp_mb[gname[i]] + 0.5), grp_n[gname[i]])
    agents_json = ""
    for (i = 1; i <= n; i++) agents_json = agents_json (i > 1 ? "," : "") rec[i]

    printf "{\"schema\":1,\"generated_at\":%s,\"epoch\":%d,", jstr(iso), now > jout
    printf "\"host\":{\"os\":%s,\"ncpu\":%d,\"load1\":%.2f},", jstr("macOS " os_ver), ncpu, load1 > jout
    printf "\"memory\":{\"total_mb\":%d,\"pressure\":%s,\"pressure_level\":%d,\"free_pct\":%d,\"swap_used_mb\":%d,\"swap_total_mb\":%d,\"compressed_mb\":%d},", total_mb, jstr(level_name), level, free_pct, swap_used_mb, swap_total_mb, compressed_mb > jout
    printf "\"capacity\":{\"state\":%s,\"reason\":%s,\"est_extra_agents\":%d,\"avg_agent_mb\":%d,\"reserve_mb\":%d,\"swap_heavy\":%s},", jstr(state), jstr(reason), extra, int(avg + 0.5), reserve_mb, (swap_heavy ? "true" : "false") > jout
    printf "\"agents\":{\"total\":%d,\"busy\":%d,\"idle\":%d,\"recent\":%d,\"unknown\":%d,\"agents_mb\":%d,\"idle_mb\":%d},", n, nbusy, nidle, nrecent, nunknown, agents_mb, idle_mb > jout
    printf "\"agent_list\":[%s],\"top_groups\":[%s],\"usage\":%s,", agents_json, groups, (usage == "" ? "null" : usage) > jout
    printf "\"config\":{\"mode\":%s,\"idle_min\":%d,\"busy_min\":%d,\"free_tight_pct\":%d,\"free_crit_pct\":%d,\"reserve_pct\":%d,\"swap_heavy_pct\":%d,\"max_extra_agents\":%d},", jstr(cs_mode), idle_min, busy_min, free_tight, free_crit, reserve_pct, swap_heavy_pct, max_extra > jout
    printf "\"summary\":%s}\n", jstr(summary) > jout
    if (mode == "json") exit
  }

  print "state=" state
  print "pressure=" level_name
  print "free_pct=" free_pct
  print "swap_used_mb=" swap_used_mb
  print "swap_total_mb=" swap_total_mb
  print "total_mb=" total_mb
  print "agents=" n
  print "busy=" nbusy
  print "idle=" nidle
  print "idle_mb=" idle_mb
  print "est_extra=" extra
  print "reason=" reason
  print "idle_list=" idle_list
  print "summary=" summary
}' "$tmp/activity" "$tmp/cwd" "$tmp/agents" "$tmp/usage" "$tmp/ps"
