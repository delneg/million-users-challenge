# Lab final report: opt-box (fsharp-aspnetcore-delneg-lab), 31 Oct - 1 Nov

All numbers are opt-box, local, NOT official: 4 CPUs, 3.9 GB; server on CPUs 0-1, Postgres 18 on CPU 2, the load
generator (mload) on CPU 3, 20k idle connections, 18k users at think-scale 0.25 (~7.6k req/s) unless stated.
Server CPU is measured in us per request, arms interleaved, 3-4 rounds. Details are in `lab-worklog.md`, one row
per experiment in `lab-autoresearch.jsonl` (45 rows), diffs in `lab-patches/`.

## Batch 1

1. **Baselines** (10k users, 3 rounds): ours `80d24c8` 124.5 us/req (364 kcycles); C# example (on net11) 172.9,
   **+39%**; Rust unorig #11 66.5, **-47%** (24 MB idle RSS vs our 375); Rust cknutson12 #1 73.0. At 18k users:
   ours ~96-99, Rust unorig 47.5. Where ours goes: 11.0 KB allocated per request; Dynamic PGO is worth ~11%.
2. **JIT/PGO knobs**: TieredPGO=0 +11%, TC=0 +57%, the rest is noise. `TC_CallCountThreshold=1000` was -3.6% in
   j1 but ~0 in two more rounds (11 pairs, -1.1%). Own-assembly R2R and composite R2R: ~0. **Nothing kept.**
3. **Native AOT, done properly**: it works (42/42) once `printfn %A` and reflection STJ are gone (Utf8JsonWriter
   bodies, +3 lines), but costs **+9 to +17% CPU** per request in every round. The framework's static PGO profile
   (`StandardOptimizationData.mibc`, 1 fsproj line) recovers ~4%; a profile traced from our own app had no
   counts. Gains: startup 0.35 vs 0.7 s, -45 MB fixed RSS, the same per-connection memory. **Discarded.**
4. **Data structures/libraries** (one per use case, plan challenged with consult): unflushed BodyWriter +1.8%,
   presized gzip buffer +2-3%, RecyclableMemoryStream -1.3% then +0.7% (allocations -17%, no CPU), F# match
   routing -0.7%, the Utf8JsonWriter family +0.7 to +4%. **Nothing kept**: STJ's pooled `SerializeToUtf8Bytes` is
   already the fast path.

## Batch 2 and my own ideas

- DB pool 8 / 32 (default 16): +0.3% / +1.6%. Workstation GC: +3.4% CPU (better p99, 24 vs 41 ms). DATAS off: ~0.
- **Finding: Server GC is bimodal here.** In 7 of 19 runs with the default budget it settled into ~4x the gen0 GC
  rate (30-36 vs 8 per 100k requests, gen1 GCs, pause 5% vs 2.3%), and those runs are +4-5% slower. This is a
  big part of the noise in every round. With a fixed gen0 budget: 0 of 15 runs.
- **Kept: `DOTNET_GCgen0size=0x2000000` in start.sh**: o2 -2.1% (-5.4, +0.4, -3.8, +0.3); end to end from the
  lab branch (k1) -1.7% (-1.0, -3.4, +2.5, -5.0), +18 MB RSS. 16 MB is equivalent.
- GCRetainVM -1.0 / -0.4%, AddServerHeader=false +0.4%: noise.
- **Best lead, not kept: `DOTNET_SYSTEM_NET_SOCKETS_THREAD_COUNT=1`** (default = 2 engines on 2 CPUs): -5.0% at
  18k users (every pair), -4.3% at 30k with the same p95/p99. Not kept because with inline completions + inline
  scheduling, every request runs on those threads: one engine is one thread, which would cap a many-core box at
  one core. This box saturates on Postgres before that can be shown.

## Wins vs 80d24c8 / C# / Rust

One kept change, commit `26019c0` (start.sh, +2 lines with comment; confirmed in `05b3ec8`'s log): -1.7 to -2.1%
vs `80d24c8`, which keeps ours ~40% under the C# example and leaves us ~2x the Rust leader's CPU per request.
LOC: Program.fs 229 (unchanged), start.sh +2.

## What to cherry-pick into PR #67

1. `git cherry-pick 26019c0` (start.sh only), **after an A/B on the scoring-class box**: whether the slow GC
   mode happens there, at N heaps, is unknown, and the budget is per heap (N x 32 MB between GCs).
2. Worth an A/B there, not a pick: `DOTNET_SYSTEM_NET_SOCKETS_THREAD_COUNT=$(( $(nproc) / 2 ))` at the grader's
   ramp to saturation (capacity, not just us/req).
3. Nothing from AOT, R2R, JIT knobs, pool, Workstation GC or the JSON/buffer variants.

## Risks

- opt-box differs from the scoring box (2 server CPUs, Postgres on one local CPU, Ubuntu 26.04, .NET 11 RC3).
  Round-to-round noise is ~+-3% per pair, partly from the GC mode above.
- gen0size: the mechanism is unchecked (it looks like DATAS shrinking the budget; whether `GCgen0size` turns DATAS
  off is not verified), and memory at many heaps is untested.

## Uncommitted, and the box

- Everything is committed and pushed on `fsharp-aspnetcore-delneg-lab`. This file is also at
  /tmp/muc-optbox/.autoresearch-off, untracked on purpose (the stop marker).
- Variant sources: /tmp/muc-optbox-lab/ on the Mac, ~/muclab/lab/ on opt-box (diffs are in `lab-patches/`).
- opt-box: queue runner stopped, no Server/mload left, `muclab-pg` container and `muclab-aot` image removed.
  Left: ~/muclab (3.6 GB: SDK, builds, runs, seed); the runtime-only sysctls from setup.sh (incl.
  `ip_local_reserved_ports=3000-3001,3100,8080-8099`, gone on reboot); images postgres:18 (older than this lab) and golang:1.27
  (setup.sh builds mload in it; left in case other work on the box uses it: `docker rmi golang:1.27` if not).
