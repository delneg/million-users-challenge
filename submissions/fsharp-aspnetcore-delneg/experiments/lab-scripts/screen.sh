#!/usr/bin/env bash
# One screen on opt-box (4 vCPU): server on CPUs 0-1 (transient systemd unit, LimitNOFILE 8388608), Postgres
# (docker muclab-pg) on CPU 2, mload + idle holder on CPU 3. Fresh `feed` from feed_seed and cold caches first.
#   screen.sh <label> <users> <think-scale> <idle-conns> <BUILD_DIR> [ENV=VAL ...]
# BUILD_DIR has start.sh (our entry, examples/csharp or a Rust submission). HOLD (default 100s), IDLE_K (idle ping
# period, s). Window: CPU read at +40 s and +110 s after mload starts (ramp 20 s). Result: ~/muclab/runs/<label>/result.txt
# Memory guard: if MemAvailable drops under 500 MB the run is killed and marked ABORT-MEM.
set -u
L=~/muclab; Lb=$1; U=$2; TS=$3; IDLE=$4; DIR=$5; shift 5
OUT=$L/runs/$Lb; rm -rf "$OUT"; mkdir -p "$OUT"
SRV_CPUS=${SRV_CPUS:-0-1}; PG_CPU=${PG_CPU:-2}; LG_CPU=${LG_CPU:-3}
sudo systemctl stop mlab-srv 2>/dev/null; sudo systemctl reset-failed mlab-srv 2>/dev/null; pkill -x idle 2>/dev/null; pkill -x mload 2>/dev/null
docker update --cpuset-cpus $PG_CPU muclab-pg >/dev/null
export PGHOST=127.0.0.1 PGUSER=postgres PGPASSWORD=postgres
psql -qX -d postgres -c "DROP DATABASE IF EXISTS feed WITH (FORCE)" -c "CREATE DATABASE feed OWNER feed TEMPLATE feed_seed" >/dev/null
docker stop -t 30 muclab-pg >/dev/null; sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null; docker start muclab-pg >/dev/null
for i in $(seq 60); do psql -qXAtd feed -c 'select 1' >/dev/null 2>&1 && break; sleep 0.5; done
psql -qXd feed -c "CREATE EXTENSION IF NOT EXISTS pg_stat_statements" -c "SELECT pg_stat_statements_reset()" >/dev/null 2>&1   # lab-only diagnostics
envs=(--setenv=DATABASE_URL=postgres://feed:feed@127.0.0.1:5432/feed --setenv=JWT_SECRET=million-users-challenge
      --setenv=HOST=0.0.0.0 --setenv=PORT=8080 --setenv=EXTRA_PORT=8081 --setenv=DOTNET_ROOT=$L/dotnet --setenv=PATH=$L/dotnet:/usr/bin:/bin)
for kv in "$@"; do envs+=(--setenv="$kv"); done
[ -n "${PERF:-}" ] && envs+=(--setenv=DOTNET_PerfMapEnabled=1 --setenv=DOTNET_EnableWriteXorExecute=0)
echo "$Lb dir=$DIR users=$U ts=$TS idle=$IDLE env=$*" > "$OUT/args"
sudo systemd-run -q --unit=mlab-srv -p User=$(id -un) -p AllowedCPUs=$SRV_CPUS -p LimitNOFILE=8388608 -p MemoryMax=1800M \
  -p LogRateLimitIntervalSec=30s -p LogRateLimitBurst=200 -p WorkingDirectory=$DIR "${envs[@]}" /bin/bash $DIR/start.sh
t0=$(date +%s.%N)
for i in $(seq 240); do curl -sf -m 1 http://127.0.0.1:8080/health >/dev/null && break; sleep 0.25; done
python3 -c "import sys,time; print('health_after_s=%.2f' % (time.time()-float(sys.argv[1])))" $t0 > "$OUT/startup"
PID=$(systemctl show -p MainPID --value mlab-srv)
CG=/sys/fs/cgroup/system.slice/mlab-srv.service
PGCG=/sys/fs/cgroup/system.slice/docker-$(docker inspect -f '{{.Id}}' muclab-pg).scope
echo "rss_kB_start=$(awk '/VmRSS/{print $2}' /proc/$PID/status)" >> "$OUT/startup"
if [ "$IDLE" -gt 0 ]; then
  taskset -c $LG_CPU $L/bin/idle -n "$IDLE" -ips 2-9 -ports 8080,8081 -rate 5000 ${IDLE_K:+-k $IDLE_K -path /nope} > "$OUT/idle.log" 2>&1 &
  for i in $(seq 120); do sleep 1; o=$(tail -1 "$OUT/idle.log" | sed -n 's/.*resp=\([0-9]*\).*/\1/p'); [ "${o:-0}" -ge "$IDLE" ] && break; done
fi
echo "rss_kB_idle=$(awk '/VmRSS/{print $2}' /proc/$PID/status)" >> "$OUT/startup"
( while sleep 2; do a=$(awk '/MemAvailable/{print $2}' /proc/meminfo); if [ "$a" -lt 512000 ]; then echo "ABORT-MEM avail_kB=$a" > "$OUT/abort"; pkill -x mload; sudo systemctl stop mlab-srv; break; fi; done ) &
GUARD=$!
snap() { # server cpus busy/softirq/steal/idle ticks, server cgroup usec (usage user system), pg cgroup usec, rss kB, sockstat, MemAvailable
  awk -v c="$SRV_CPUS" 'BEGIN{split(c,r,"-")} $1 ~ /^cpu[0-9]+$/ {n=substr($1,4)+0; if(n>=r[1]&&n<=r[2]){b+=$2+$3+$4+$7+$8; s+=$7+$8; st+=$9; id+=$5+$6}} END{print b, s, st, id}' /proc/stat
  awk '/usage_usec|user_usec|system_usec/{printf "%s ", $2} END{print ""}' $CG/cpu.stat
  awk '/usage_usec/{print $2}' $PGCG/cpu.stat
  awk '/VmRSS/{print $2}' /proc/$PID/status
  grep TCP: /proc/net/sockstat
  awk '/MemAvailable/{print $2}' /proc/meminfo
}
# CPU of the load generator's core, to see when it (not the server) is the limit
lgsnap() { awk -v c=$LG_CPU '$1=="cpu"c {print $2+$3+$4+$7+$8, $5+$6}' /proc/stat; }
taskset -c $LG_CPU $L/bin/mload -target 127.0.0.1 -ports 8080,8081 -users "$U" -ramp 20s -hold ${HOLD:-100s} -gzip -think-scale "$TS" \
  -tokens $L/tokens.json -out "$OUT/mload.json" > "$OUT/mload.log" 2>&1 &
MP=$!
snap > "$OUT/snapE0"; sleep 20; snap > "$OUT/snapE1"   # early window (ramp, 0-20 s): JIT warm-up, R2R/AOT/PGO show here
sleep 20; snap > "$OUT/snap0"; lgsnap > "$OUT/lg0"
if [ -n "${PERF:-}" ]; then
  sudo perf record -q -C $SRV_CPUS -g -o "$OUT/perf.data" -- sleep 20 2>/dev/null
  sudo perf report -q -i "$OUT/perf.data" --no-children --sort comm,dso,sym --percent-limit 0.4 2>/dev/null | grep "%" | head -80 > "$OUT/perf.txt"
  sudo rm -f "$OUT/perf.data"; sleep 50
else
  # COUNTERS=1: also the runtime's counters (allocated bytes, GC counts) over the window, for allocations per request
  [ -n "${COUNTERS:-}" ] && DOTNET_ROOT=$L/dotnet DOTNET_ROLL_FORWARD=Major $L/tools/dotnet-counters collect -p $PID --counters System.Runtime \
    --format csv -o "$OUT/counters.csv" --duration 00:00:01:10 > /dev/null 2>&1 &
  sudo perf stat -x, -e instructions:u,instructions:k,cycles:u,cycles:k -C $SRV_CPUS -o "$OUT/pstat.csv" -- sleep 70
fi
snap > "$OUT/snap1"; lgsnap > "$OUT/lg1"
psql -qXAt -F'|' -d feed -c "SELECT calls, round(total_exec_time::numeric,1), left(regexp_replace(query, '\s+', ' ', 'g'), 60) FROM pg_stat_statements WHERE dbid=(SELECT oid FROM pg_database WHERE datname='feed') ORDER BY calls DESC LIMIT 8" > "$OUT/pgss.txt" 2>/dev/null
wait $MP
kill $GUARD 2>/dev/null
journalctl -q _SYSTEMD_INVOCATION_ID="$(systemctl show -p InvocationID --value mlab-srv)" --no-pager -o cat 2>/dev/null | tail -200 > "$OUT/server.log"
python3 - "$OUT" <<'PY' | tee "$OUT/result.txt"
import sys, re, os
d = sys.argv[1]
a = [l.split() for l in open(d + '/snap0')]; b = [l.split() for l in open(d + '/snap1')]
busy = int(b[0][0]) - int(a[0][0]); soft = int(b[0][1]) - int(a[0][1]); steal = int(b[0][2]) - int(a[0][2]); idle = int(b[0][3]) - int(a[0][3])
cg = [int(x) - int(y) for x, y in zip(b[1], a[1])]
pg = int(b[2][0]) - int(a[2][0])
l0 = open(d + '/lg0').read().split(); l1 = open(d + '/lg1').read().split()
lgb = int(l1[0]) - int(l0[0]); lgi = int(l1[1]) - int(l0[1])
reqs = 0
for l in open(d + '/mload.log'):
    m = re.match(r't=\s*(\d+)s .*req/s=(\d+)', l)
    if m and 40 < int(m.group(1)) <= 110: reqs += int(m.group(2)) * 5
res = [l.strip() for l in open(d + '/mload.log') if l.startswith('RESULT')]
e0 = [l.split() for l in open(d + '/snapE0')]; e1 = [l.split() for l in open(d + '/snapE1')]
ereq = 0; ep99 = []
for l in open(d + '/mload.log'):
    m = re.match(r't=\s*(\d+)s .*req/s=(\d+) .*p99=([0-9.]+)ms', l)
    if m and int(m.group(1)) <= 20: ereq += int(m.group(2)) * 5; ep99.append(float(m.group(3)))
r = max(reqs, 1); tot = busy + idle + steal
print(open(d + '/args').read().strip())
if os.path.exists(d + '/abort'): print(open(d + '/abort').read().strip())
print('reqs=%d req/s=%.0f  srv us/req=%.1f (softirq %.1f) cgroup us/req=%.1f (user %.1f sys %.1f)  util=%.0f%% steal=%.1f%%  pg us/req=%.1f (pg util %.0f%%)  lg util=%.0f%%'
      % (reqs, reqs / 70, busy * 1e4 / r, soft * 1e4 / r, cg[0] / r, cg[1] / r, cg[2] / r, 100 * busy / max(tot, 1), 100 * steal / max(tot, 1),
         pg / r, pg / 70e4, 100 * lgb / max(lgb + lgi, 1)))
print('rss_kB=%s -> %s  %s  memavail_kB=%s  %s' % (a[3][0], b[3][0], ' '.join(b[4]), b[5][0], open(d + '/startup').read().replace('\n', ' ')))
print(res[-1] if res else 'NO RESULT')
print('early 0-20s: reqs=%d srv us/req=%.1f p99 per 5s=%s' % (ereq, (int(e1[0][0]) - int(e0[0][0])) * 1e4 / max(ereq, 1), ep99))
if os.path.exists(d + '/pstat.csv'):
    v = {}
    for l in open(d + '/pstat.csv'):
        f = l.strip().split(',')
        if len(f) > 2 and f[0].replace('.', '').isdigit(): v[f[2]] = float(f[0])
    print('per req: kinstr user=%.1f kernel=%.1f  kcycles user=%.1f kernel=%.1f total=%.1f' % (
        v.get('instructions:u', 0) / r / 1e3, v.get('instructions:k', 0) / r / 1e3,
        v.get('cycles:u', 0) / r / 1e3, v.get('cycles:k', 0) / r / 1e3, (v.get('cycles:u', 0) + v.get('cycles:k', 0)) / r / 1e3))
PY
sudo systemctl stop mlab-srv; pkill -x idle 2>/dev/null; true
