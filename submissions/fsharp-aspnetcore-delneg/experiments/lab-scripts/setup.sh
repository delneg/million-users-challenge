#!/usr/bin/env bash
# One-time setup of the opt-box lab (4 vCPU i5-11400F, 3.9 GB, Ubuntu 26.04). Everything lives in ~/muclab.
#   ~/muclab/dotnet   .NET SDK 11.0.100-rc.3.26522.148 (official tarball, SHA-512 checked, as install.sh)
#   muclab-pg         Postgres 18 in docker (host network, port 5432, CPU 2, 1 GB), the challenge's
#                     postgresql.conf scaled from 32 GB to this box; feed_seed = the full seed (50k/500k/2M)
#   ~/muclab/bin      mload (built in golang:1.27) and the idle-connection holder (idle.c)
set -euo pipefail
L=~/muclab; R=$L/repo
# the grader's sysctls (box/setup-app-box.sh), runtime only
sudo sysctl -q -w fs.nr_open=16777216 fs.file-max=33554432 net.ipv4.ip_local_port_range="1024 65535" \
  net.core.somaxconn=65535 net.ipv4.tcp_max_syn_backlog=65535 net.core.netdev_max_backlog=250000 net.ipv4.tcp_tw_reuse=1 \
  net.ipv4.tcp_rmem="4096 16384 4194304" net.ipv4.tcp_wmem="4096 16384 4194304" net.ipv4.tcp_max_orphans=1048576
command -v psql >/dev/null || sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -q postgresql-client >/dev/null
mkdir -p $L/bin
if ! docker ps --format '{{.Names}}' | grep -qx muclab-pg; then
  docker rm -f muclab-pg >/dev/null 2>&1 || true
  docker run -d --name muclab-pg --network host --cpuset-cpus 2 -m 1g --shm-size 256m \
    -e POSTGRES_PASSWORD=postgres -v muclab-pgdata:/var/lib/postgresql -v $L/seed-tsv:/seed:ro postgres:18 \
    -c max_connections=600 -c shared_buffers=256MB -c effective_cache_size=768MB -c maintenance_work_mem=128MB \
    -c random_page_cost=1.1 -c effective_io_concurrency=200 -c wal_buffers=16MB -c wal_compression=lz4 \
    -c checkpoint_timeout=15min -c checkpoint_completion_target=0.9 -c max_wal_size=2GB -c min_wal_size=512MB \
    -c max_worker_processes=4 -c max_parallel_workers=2 -c max_parallel_workers_per_gather=1 -c jit=off \
    -c enable_memoize=off -c ssl=off -c huge_pages=off -c shared_preload_libraries=pg_stat_statements
  for i in $(seq 60); do PGPASSWORD=postgres psql -h 127.0.0.1 -U postgres -qXAtc 'select 1' >/dev/null 2>&1 && break; sleep 1; done
fi
export PGHOST=127.0.0.1 PGUSER=postgres PGPASSWORD=postgres
q() { psql -qX -v ON_ERROR_STOP=1 "$@"; }
q -d postgres -c "DO \$\$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='feed') THEN CREATE ROLE feed LOGIN PASSWORD 'feed' CREATEDB; END IF; END \$\$"
if ! psql -qXAtd postgres -c "SELECT 1 FROM pg_database WHERE datname='feed_seed'" | grep -q 1; then
  q -d postgres -c "CREATE DATABASE feed_seed OWNER feed"
  sed '/^-- after the bulk load --$/,$d' $R/schema.sql | PGUSER=feed PGPASSWORD=feed q -d feed_seed
  docker exec -u postgres muclab-pg psql -qX -v ON_ERROR_STOP=1 -d feed_seed \
    -c "\\copy users (id, username, created_at) FROM '/seed/users.tsv'" \
    -c "\\copy posts (id, user_id, body, created_at) FROM '/seed/posts.tsv'" \
    -c "\\copy likes (user_id, post_id, created_at) FROM '/seed/likes.tsv'"
  sed -n '/^-- after the bulk load --$/,$p' $R/schema.sql | PGUSER=feed PGPASSWORD=feed q -d feed_seed -c "SET maintenance_work_mem = '128MB'" -f - >/dev/null
  q -d feed_seed -c "VACUUM ANALYZE"
  ts="to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.MS\"Z\"')"
  sum="$(psql -qXAt -F'|' -d feed_seed -c "SELECT id, username, $ts FROM users ORDER BY id" \
    -c "SELECT id, user_id, body, $ts FROM posts ORDER BY id" -c "SELECT user_id, post_id, $ts FROM likes ORDER BY post_id, user_id" | sha256sum | cut -d' ' -f1)"
  echo "seed sha256 $sum (expected 738d11ab3164c13177e347f75038d1e80b43c64e754544a42d1c32bd8d7bcf1d), size $(psql -qXAtd postgres -c "SELECT pg_size_pretty(pg_database_size('feed_seed'))")"
fi
[ -x $L/bin/mload ] || docker run --rm -v $R/bench/mload:/src -v $L/bin:/out -w /src -e CGO_ENABLED=0 golang:1.27 go build -o /out/mload .
[ -x $L/bin/idle ] || gcc -O2 -o $L/bin/idle $R/submissions/fsharp-aspnetcore-delneg/experiments/scripts/idle.c
cp -n $L/seed-tsv/tokens.json $L/tokens.json 2>/dev/null || true
ls -la $L/bin; free -m | head -2
