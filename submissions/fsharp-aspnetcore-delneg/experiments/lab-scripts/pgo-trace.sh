#!/usr/bin/env bash
# Static PGO for Native AOT: trace the JIT build of the same source under the screen load (JIT + instrumentation
# events, framework R2R off so framework methods are jitted and instrumented too), then dotnet-pgo create-mibc.
#   pgo-trace.sh <JIT build dir> <out.mibc>
set -u
L=~/muclab; B=$1; OUT=$2; T=$L/runs/pgo; rm -rf $T; mkdir -p $T
export DOTNET_ROOT=$L/dotnet DOTNET_ROLL_FORWARD=Major
export PGHOST=127.0.0.1 PGUSER=postgres PGPASSWORD=postgres
psql -qX -d postgres -c "DROP DATABASE IF EXISTS feed WITH (FORCE)" -c "CREATE DATABASE feed OWNER feed TEMPLATE feed_seed" >/dev/null
( cd $B && env DATABASE_URL=postgres://feed:feed@127.0.0.1:5432/feed JWT_SECRET=million-users-challenge HOST=0.0.0.0 PORT=8080 EXTRA_PORT=8081 \
    DOTNET_ReadyToRun=0 DOTNET_GCHeapHardLimitPercent=0x46 DOTNET_ThreadPool_UnfairSemaphoreSpinLimit=0 DOTNET_SYSTEM_NET_SOCKETS_INLINE_COMPLETIONS=1 \
    timeout -s INT 130 taskset -c 0-1 $L/tools/dotnet-trace collect --providers Microsoft-Windows-DotNETRuntime:0x1E000080018:5 --duration 00:00:01:40 \
    -o $T/trace.nettrace -- ./out/Server > $T/trace.log 2>&1 ) &
for i in $(seq 120); do curl -sf -m 1 http://127.0.0.1:8080/health >/dev/null && break; sleep 0.5; done
taskset -c 3 $L/bin/mload -target 127.0.0.1 -ports 8080,8081 -users 18000 -ramp 20s -hold 70s -gzip -think-scale 0.25 -tokens $L/tokens.json > $T/mload.log 2>&1
wait
pkill -f "$B/out/Server" 2>/dev/null; sleep 1
ls -la $T
$L/tools/dotnet-pgo create-mibc --trace $T/trace.nettrace --output "$OUT" --reference "$B/out/*.dll" --reference "$L/dotnet/shared/Microsoft.NETCore.App/11.0.0-rc.3.26522.148/*.dll" \
  --reference "$L/dotnet/shared/Microsoft.AspNetCore.App/11.0.0-rc.3.26522.148/*.dll" > $T/pgo.log 2>&1
tail -n 5 $T/pgo.log; ls -la "$OUT"
