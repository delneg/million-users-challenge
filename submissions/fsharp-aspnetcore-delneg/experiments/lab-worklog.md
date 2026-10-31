# Lab worklog: opt-box (fsharp-aspnetcore-delneg-lab)

A second experiment lab for this entry, on Denis's list (31 Oct): JIT/PGO, Native AOT done properly, data
structures and libraries per use case, then the second-look knobs (DB pool, Workstation GC, gen0size). Branch
`fsharp-aspnetcore-delneg-lab` from `80d24c8`; the main log (`worklog.md`, Synteq) is MucAspNet's.

**All numbers here are opt-box, local, NOT official**, and not comparable with the Synteq numbers in `worklog.md`.

## The box and the method

- opt-box: a VM, 4 vCPU (i5-11400F, 1 thread per core), 3.9 GB RAM, Ubuntu 26.04, kernel 7.0. Shared with nothing
  else during runs. Perf counters work in the VM.
- SDK `11.0.100-rc.3.26522.148` (official tarball, the SHA-512 of `install.sh`) in `~/muclab/dotnet`.
- Postgres 18 (docker `postgres:18`, host network) on CPU 2, 1 GB, the challenge `postgresql.conf` scaled to this
  box (`lab-scripts/setup.sh`). The **full seed** (50k users, 500k posts, 2,016,005 likes; content sha256 matches
  `make-seed.sh`'s, 318 MB), a fresh `feed` copy and cold caches before every run.
- Server on CPUs 0-1 (transient systemd unit, `LimitNOFILE=8388608`, `MemoryMax=1800M`), ports 8080 + 8081.
  mload (`bench/mload`, built in `golang:1.27`) and the idle holder (`scripts/idle.c`) on CPU 3.
- **screen** (`lab-scripts/screen.sh`): 20,000 idle keep-alive connections (127.0.0.2-9 x both ports), then mload
  `-gzip -think-scale 0.25`, ramp 20 s, hold 100 s. CPU read from +40 s to +110 s. One number decides: server CPU
  per request (busy ticks of CPUs 0-1, incl. softirq), plus `perf stat` user/kernel instructions and cycles per
  request, Postgres CPU per request (its cgroup), load generator core utilization, p95/p99, RSS.
- Runs go through `lab-scripts/queue.sh`, one at a time; builds are queued between runs, never during one.
- A/B: arms interleaved (A, B, C, A, B, C, ...), >= 3 reps each, means and per-pair signs. Never against an old
  number.

## Experiments

Format: id, what, numbers (interleaved, reps), LOC (`wc -l src/Program.fs`), verdict.
