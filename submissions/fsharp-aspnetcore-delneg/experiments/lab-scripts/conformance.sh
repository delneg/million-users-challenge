#!/usr/bin/env bash
# The challenge's test/run.sh (42 checks) on opt-box from a clean copy of SRC (a submission dir with src/, start.sh,
# build.sh), on 3000/3001 then with the ports swapped; then gzip bodies == plain bodies. Prints passed=/FAIL lines.
#   [PREBUILT=1] conformance.sh <SRC_DIR> [ENV=VAL ...]   (ENV is passed to start.sh, e.g. a knob under test)
set -u
L=~/muclab; R=$L/repo; S=$R/submissions/fsharp-aspnetcore-delneg-conf; SRC=$1; shift
rm -rf "$S"; mkdir -p "$S"; rsync -a --exclude bin --exclude obj --exclude out "$SRC/" "$S/"
# PREBUILT=1: test the binaries already in SRC/out (e.g. a NativeAOT build made in docker) instead of building again
if [ -n "${PREBUILT:-}" ]; then rsync -a "$SRC/out/" "$S/out/"; printf '#!/usr/bin/env bash\ntrue\n' > "$S/build.sh"; fi
export PATH=$L/dotnet:$PATH DOTNET_ROOT=$L/dotnet NUGET_PACKAGES=$L/nuget PGHOST=127.0.0.1 PGUSER=postgres PGPASSWORD=postgres
for kv in "$@"; do export "$kv"; done
cd "$R"
for ports in "3000 3001" "3001 3000"; do
  set -- $ports
  PORT=$1 EXTRA_PORT=$2 bash test/run.sh submissions/fsharp-aspnetcore-delneg-conf 2>&1 | grep -E "FAIL|want|got|passed=|rror|healthy|xception" | head -20
done
psql -qX -d postgres -c "DROP DATABASE IF EXISTS feed_gz WITH (FORCE)" -c "CREATE DATABASE feed_gz OWNER feed TEMPLATE feed_seed" >/dev/null
DATABASE_URL=postgres://feed:feed@127.0.0.1:5432/feed_gz JWT_SECRET=million-users-challenge HOST=127.0.0.1 PORT=3100 bash "$S/start.sh" > /tmp/mlab-gz.log 2>&1 &
P=$!
for i in $(seq 60); do curl -sf http://127.0.0.1:3100/health >/dev/null && break; sleep 0.5; done
for p in /feed /posts/1 /posts/250000 /nope; do
  a=$(curl -s http://127.0.0.1:3100$p | md5sum); b=$(curl -s -H "Accept-Encoding: gzip" http://127.0.0.1:3100$p | gunzip -f | md5sum)
  [ "$a" = "$b" ] && [ "$a" != "$(printf "" | md5sum)" ] && echo "gzip $p ok" || echo "gzip $p FAIL"
done
kill $P; pkill -P $P 2>/dev/null; sleep 1; pkill -f "fsharp-aspnetcore-delneg-conf/out/Server" 2>/dev/null
psql -qX -d postgres -c "DROP DATABASE IF EXISTS feed_gz WITH (FORCE)" -c "DROP DATABASE IF EXISTS feed_test WITH (FORCE)" >/dev/null
true
