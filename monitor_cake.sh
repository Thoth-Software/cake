#!/usr/bin/env bash
#
# monitor_cake.sh - Monitor all three Docker containers during pipeline runs.
# Usage: ./monitor_cake.sh
# Stop:  Ctrl+C
# After a crash: grep '\[CRASH\]' cake_monitor_*.log
#                grep '\[ALERT\]' cake_monitor_*.log

set -euo pipefail

LOGFILE="cake_monitor_$(date +%Y%m%d_%H%M%S).log"
INTERVAL=2

# Container names (from docker-compose.yml)
CONTAINERS=(cake_app cake_db cake_opensearch)
OS_URL="http://localhost:9200"
PG_CONTAINER="cake_db"
PG_USER="postgres"
PG_DB="cake_dev"

# Track which containers were running last tick
declare -A PREV_RUNNING
for c in "${CONTAINERS[@]}"; do PREV_RUNNING[$c]=0; done

LAST_LOG_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

log() {
  local tag="$1"; shift
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [$tag] $*" >> "$LOGFILE"
}

logblock() {
  local tag="$1"
  while IFS= read -r line; do
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [$tag] $line" >> "$LOGFILE"
  done
}

echo "Logging to $LOGFILE (Ctrl+C to stop)"
log START "monitor_cake.sh started, interval=${INTERVAL}s"

while true; do
  log TICK "---"

  # ── 1. Docker stats (CPU, memory, network, PIDs) ──────────────────────
  docker stats --no-stream --format '{{.Name}}\tCPU={{.CPUPerc}}\tMEM={{.MemUsage}}\tMEM%={{.MemPerc}}\tNET={{.NetIO}}\tPIDs={{.PIDs}}' 2>&1 \
    | logblock DOCKER_STATS

  # ── 2. Container status (running, health, OOM, exit code, restarts) ──
  for c in "${CONTAINERS[@]}"; do
    info=$(docker inspect --format \
      'state={{.State.Status}} health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} oom={{.State.OOMKilled}} exit={{.State.ExitCode}} restarts={{.RestartCount}}' \
      "$c" 2>&1) || info="UNREACHABLE"
    log CONTAINER "$c $info"

    # ── Crash detection ──
    running=0
    if echo "$info" | grep -q 'state=running'; then running=1; fi

    if [[ "${PREV_RUNNING[$c]}" == "1" && "$running" == "0" ]]; then
      log CRASH "!! $c STOPPED -- was running last tick !!"
      log CRASH "inspect:"
      docker inspect "$c" 2>&1 | logblock CRASH_INSPECT
      log CRASH "last 200 log lines:"
      docker logs --tail 200 "$c" 2>&1 | logblock CRASH_LOGS

      # VM kernel messages (OOM killer evidence)
      colima ssh -- sudo dmesg 2>&1 | grep -iE 'oom|kill|memory|out of' | tail -20 \
        | logblock CRASH_DMESG
    fi

    # Check OOM flag
    if echo "$info" | grep -q 'oom=true'; then
      log ALERT "$c was OOM-killed!"
    fi

    PREV_RUNNING[$c]=$running
  done

  # ── 3. OpenSearch JVM heap + GC ───────────────────────────────────────
  jvm=$(curl -s --max-time 2 "$OS_URL/_nodes/stats/jvm" 2>/dev/null) || jvm=""
  if [[ -n "$jvm" ]]; then
    echo "$jvm" | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    for nid,n in d.get('nodes',{}).items():
        h=n['jvm']['mem']
        pct=h['heap_used_percent']
        print(f'heap_used={h[\"heap_used_in_bytes\"]} heap_max={h[\"heap_max_in_bytes\"]} heap_pct={pct}%')
        gc=n['jvm']['gc']['collectors']
        for name,stats in gc.items():
            print(f'gc_{name}: count={stats[\"collection_count\"]} time_ms={stats[\"collection_time_in_millis\"]}')
        if pct > 85:
            print(f'HEAP_HIGH={pct}%')
except: pass
" 2>&1 | while IFS= read -r line; do
      if echo "$line" | grep -q 'HEAP_HIGH'; then
        log ALERT "OpenSearch $line"
      else
        log OS_JVM "$line"
      fi
    done
  else
    log OS_JVM "UNREACHABLE"
  fi

  # ── 4. OpenSearch file descriptors ────────────────────────────────────
  proc=$(curl -s --max-time 2 "$OS_URL/_nodes/stats/process" 2>/dev/null) || proc=""
  if [[ -n "$proc" ]]; then
    echo "$proc" | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    for nid,n in d.get('nodes',{}).items():
        p=n['process']
        o=p['open_file_descriptors']; m=p['max_file_descriptors']
        print(f'open_fd={o} max_fd={m}')
        if o > 50000: print(f'FD_HIGH={o}/{m}')
except: pass
" 2>&1 | while IFS= read -r line; do
      if echo "$line" | grep -q 'FD_HIGH'; then
        log ALERT "OpenSearch $line"
      else
        log OS_FD "$line"
      fi
    done
  else
    log OS_FD "UNREACHABLE"
  fi

  # ── 5. OpenSearch circuit breakers ────────────────────────────────────
  brk=$(curl -s --max-time 2 "$OS_URL/_nodes/stats/breaker" 2>/dev/null) || brk=""
  if [[ -n "$brk" ]]; then
    echo "$brk" | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    for nid,n in d.get('nodes',{}).items():
        for bname,b in n['breakers'].items():
            t=b.get('tripped',0); e=b.get('estimated_size_in_bytes',0); l=b.get('limit_size_in_bytes',0)
            if t>0: print(f'TRIPPED {bname}: tripped={t} est={e} limit={l}')
            elif e>0: print(f'{bname}: est={e} limit={l}')
except: pass
" 2>&1 | while IFS= read -r line; do
      if echo "$line" | grep -q 'TRIPPED'; then
        log ALERT "OpenSearch breaker $line"
      else
        log OS_BREAKERS "$line"
      fi
    done
  fi

  # ── 6. OpenSearch thread pool queues/rejections ───────────────────────
  tp=$(curl -s --max-time 2 "$OS_URL/_nodes/stats/thread_pool" 2>/dev/null) || tp=""
  if [[ -n "$tp" ]]; then
    echo "$tp" | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    for nid,n in d.get('nodes',{}).items():
        for tname in ['write','search','bulk','generic','flush','force_merge']:
            t=n['thread_pool'].get(tname,{})
            q=t.get('queue',0); r=t.get('rejected',0); a=t.get('active',0)
            if r>0: print(f'REJECTED {tname}: active={a} queue={q} rejected={r}')
            elif q>0 or a>0: print(f'{tname}: active={a} queue={q} rejected={r}')
except: pass
" 2>&1 | while IFS= read -r line; do
      if echo "$line" | grep -q 'REJECTED'; then
        log ALERT "OpenSearch thread_pool $line"
      else
        log OS_THREADS "$line"
      fi
    done
  fi

  # ── 7. Postgres connections and waiting locks ─────────────────────────
  pg_conns=$(docker exec "$PG_CONTAINER" psql -U "$PG_USER" -d "$PG_DB" -t -A -c \
    "SELECT state, count(*) FROM pg_stat_activity WHERE datname='$PG_DB' GROUP BY state;" 2>&1) || pg_conns="UNREACHABLE"
  log PG_CONN "$pg_conns"

  pg_locks=$(docker exec "$PG_CONTAINER" psql -U "$PG_USER" -d "$PG_DB" -t -A -c \
    "SELECT count(*) FROM pg_locks WHERE NOT granted;" 2>&1) || pg_locks="UNREACHABLE"
  if [[ "$pg_locks" != "0" && "$pg_locks" != "UNREACHABLE" ]]; then
    log ALERT "Postgres waiting locks: $pg_locks"
  fi
  log PG_LOCKS "waiting=$pg_locks"

  # ── 8. Colima VM memory and file descriptors ──────────────────────────
  vm_mem=$(colima ssh -- cat /proc/meminfo 2>/dev/null | grep -E 'MemTotal|MemAvailable|SwapTotal|SwapFree') || vm_mem="UNREACHABLE"
  echo "$vm_mem" | logblock VM_MEM

  # Check for low memory
  avail_kb=$(echo "$vm_mem" | grep 'MemAvailable' | awk '{print $2}')
  if [[ -n "$avail_kb" && "$avail_kb" -lt 1048576 ]]; then
    log ALERT "VM MemAvailable=${avail_kb}kB (<1GB)"
  fi

  vm_fd=$(colima ssh -- cat /proc/sys/fs/file-nr 2>/dev/null) || vm_fd="UNREACHABLE"
  log VM_FD "$vm_fd"

  # ── 9. Container error logs since last tick ───────────────────────────
  for c in "${CONTAINERS[@]}"; do
    errs=$(docker logs --since "$LAST_LOG_TS" "$c" 2>&1 \
      | grep -iE 'error|exception|kill|oom|crash|unexpected|eof|timeout|refused|fatal|WARN' \
      | tail -20) || errs=""
    if [[ -n "$errs" ]]; then
      echo "$errs" | logblock "ERRORS_${c}"
    fi
  done
  LAST_LOG_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  sleep "$INTERVAL"
done
