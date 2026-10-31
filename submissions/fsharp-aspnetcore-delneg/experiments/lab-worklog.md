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

Format: id, what, numbers (interleaved, reps), LOC (`wc -l src/Program.fs`), verdict. Every variant's diff vs `80d24c8`
is in `experiments/lab-patches/` (e.g. `json1.Program.fs.diff` + `aot5.Server.fsproj.diff` = the AOT build).

### Bars (batch 1, item 1), 31 Oct: ours `80d24c8`, the C# example, the two best Rust submissions

Which Rust: the leaderboard's best Rust is `rust-tokio-unorig-username` (#11: rank 4, 1,000,000 / 1,260,000 /
960,000 on 16/8/4 cores); `rust-tokio-cknutson12` (#1: rank 6, 1,000,000 / 1,210,000 / 1,130,000) has the better
4-core score, which is closer to this 2-core slice, so both were run. Both: tokio current-thread runtime per core,
pipelined tokio-postgres, libdeflate; built with rustc 1.94.0 (`tdsc-rust:2404` image), `target-cpu=native` as
their `build.sh` does. The C# example retargeted to net11.0 (same runtime as ours), its own settings (pool 16 on 2
cores, auto-prepare, no multiplexing, ResponseCompression middleware, JwtBearer; as its README). 3 interleaved rounds each, 20k idle connections.

10k users (~4.2k req/s; every server < 40% busy, Postgres 25-61% of its core, mload 10-15% of its core):

| server | us/req (3 runs) | kcycles/req | user kinstr/req | p95 / p99 ms | Postgres us/req | RSS after 20k idle | /health after start |
|---|---|---|---|---|---|---|---|
| ours `80d24c8` | **124.5** (122.3-126.3) | 364 | 191 | 5.8 / 33.7 | 76.8 | 375 MB | 0.67 s |
| C# example | 172.9 (172.4-173.3), +39% | 658 (+81%) | 261 | 6.2 / 15.8 | 144.9 | 478 MB | 0.85 s |
| Rust unorig (#11) | 66.5 (65.7-67.3), -47% | 117 (-68%) | 109 | 9.0 / 11.7 | 58.7 | 24 MB | 0.35 s |
| Rust cknutson12 (#1) | 73.0 (70.4-76.3), -41% | 185 (-49%) | 113 | 3.6 / 5.8 | 77.9 | 28 MB | 0.36 s |

18k users (~7.6k req/s), the screen load for the experiments below: ours 98.8 us/req (97.3-100.8), 341 kcycles,
p95 13.3 / p99 51.1 ms, server 36% busy, Postgres 71.5 us/req (54% of its core), mload 23%; Rust unorig 47.5 us/req
(45.5-49.5), 103 kcycles, p95 8.8 / p99 12.2.

Notes. Per-request CPU falls as load rises (98.8 at 18k vs 124.5 at 10k for ours): fixed per-second costs (Kestrel's
1 s heartbeat over every connection, timers, GC) spread over more requests, and the kernel batches more. So only
same-load numbers are compared. Rust unorig's Postgres CPU per request is ~25% lower than ours (pipelined, its
prepared statements). The C# example listens on `[::]`, so its server-side sockets count as TCP6 (all 20k idle
connections answered; same in every round). Ours vs the C# example is the same gap as on Synteq (MucAspNet's
worklog: ~245 vs ~301 us/req), so the box agrees in direction.

Allocation check of `80d24c8` (`COUNTERS=1`, 18k users): **11.0 KB allocated per request**, 27 gen0 + 9 gen1 GCs per
100k requests, no gen2, GC pauses 4.4% of wall time, 0.97 thread-pool work items per request (Npgsql's
multiplexing loop; the HTTP side runs inline). Profile (`PERF=1`, % of busy cycles on the 2 server CPUs): zlib-ng
`DeflateInit2` memset 2.2%, Kestrel heartbeat 1.6%, STJ `ListOfTConverter` (feed) 1.3%, write barriers 1.2%, Server
GC 1.1%, ValueTask/pipe flush 1.1%, `DateTime.ToString` custom format 1.0%, Npgsql multiplexing loop 0.7%; kernel
networking most of the rest.

### Native AOT, done properly (batch 1, item 3)

Why e17 aborted, and what was different this time. Built in an Ubuntu 24.04 container with clang, lld and
zlib1g-dev (`lab-scripts/aot.Dockerfile`; `build.sh <label> aot`). The unchanged `80d24c8` source **builds** under
`PublishAot` (warnings: STJ `SerializeToUtf8Bytes<T>` IL2026/IL3050, FSharp.Core IL3053), but dies at startup:

1. `printfn "... %A" ports`: F#'s `%A` formatter builds generic methods by reflection (`MakeGenericMethod`, "missing
   native code"). On this box it was this, not e17's `FileNotFoundException: Microsoft.AspNetCore`. Fix: an
   interpolated string (`Console.WriteLine $"..."`), 0 lines.
2. Reflection STJ: with `JsonSerializerIsReflectionEnabledByDefault=true` + `TrimmerRootAssembly` (aot1) the feed
   and posts serialize, but `/health` fails (`SmallObjectWithParameterizedConstructorConverter<Health,...>` "missing
   native code"), so `test/run.sh` never sees a healthy server. Reflection STJ is not a fix under AOT. F# can't run the
   C# STJ source generator, so the AOT-clean way is to write the bodies with `Utf8JsonWriter` (no reflection):
   `writePost` + one `send ctx status (fun w -> ...)` per response, the response records removed (json1, +3 lines).

With 1 + 2 (aot2): **42/42 on both port orders, gzip bodies equal the plain ones**, no warnings from our code
(only FSharp.Core's IL3053/IL2104 about its own reflection paths, which we don't call). Npgsql 10 needed nothing
(`NpgsqlDataSource.Create` gave no warning). 19.7 MB binary.

- **L1 `Utf8JsonWriter` bodies instead of STJ `SerializeToUtf8Bytes`** (json1, JIT, the AOT-ready source; +3 lines,
  232): 3 interleaved rounds vs base: 100.4 vs 96.6 us/req (**+4.0%**; pairs +0.0, +7.0, +5.0), kcycles +6.2%, user
  instructions +6%. Slower: STJ rents its writer and buffer from pools and writes one exact `byte[]`; json1 makes a
  new `Utf8JsonWriter` and a `MemoryStream` that grows 256 -> 8 KB for the feed, plus a closure per response.
  **Discarded for JIT** (kept only as the AOT source; buffer fixes measured in d0/d1/d2 below).
- **L2 Native AOT** (aot2 = json1 source + `PublishAot`), same round: 110.7 us/req, **+14.6% vs base** (pairs
  +11.7, +19.7, +12.3), +10% vs json1 (the same source jitted), kcycles +17%, user instructions +32%. AOT has no
  Dynamic PGO, and Dynamic PGO is worth ~7% here (e16 on Synteq; re-measured in j1). Startup: /health after 0.39 s
  vs 0.67 s. RSS: 31 MB at start vs 79 MB, 343 vs 383 MB with 20k idle connections, so the same ~15.5 KB per idle
  connection (Kestrel's objects, unchanged): AOT saves the ~48 MB fixed runtime/JIT footprint, nothing per
  connection. The ramp window (0-20 s) shows no AOT gain either (103.0 vs 103.1 us/req): tiering is cheap here.
- **L3 AOT `OptimizationPreference=Speed` + `IlcInstructionSet=native`** (aot3; `native` is safe because build.sh
  runs on the scoring box): 111.2 us/req, +15.1% vs base, same as aot2 (noise). No gain.

AOT so far: discarded on CPU (+15%). Next: static PGO for AOT (the framework's own `StandardOptimizationData.mibc`
from the runtime pack, and a `.mibc` traced from our app under load with `dotnet-pgo`), round a2.

### JIT / PGO knobs (batch 1, item 2), 31 Oct

Round j1: 8 arms x 3 interleaved rounds, all on the `80d24c8` build, env only (base 97.2 us/req, 343 kcycles):

| knob | us/req | vs base (pairs) | kcycles | reading |
|---|---|---|---|---|
| `TieredPGO=0` | 108.1 | **+11.2%** (+11.5, +8.8, +13.3) | +10.9% | Dynamic PGO is worth ~11% here (7% on Synteq, e16) |
| `TieredCompilation=0` | 152.5 | **+56.9%** (+57.4, +57.5, +55.7) | +67.7% | everything FullOpts at first call, no PGO, no R2R code use |
| `ReadyToRun=0` (jit the framework too) | 95.0 | -2.2% (-0.4, -0.7, -5.6) | -3.3% | one pair carries it: noise; startup 1.07 vs 0.76 s |
| `TC_QuickJitForLoops=0` | 97.2 | +0.0% (-1.0, +2.5, -1.4) | -0.6% | noise |
| `TC_OnStackReplacement=0` | 95.7 | -1.6% (-0.2, -0.1, -4.4) | -1.8% | noise |
| **`TC_CallCountThreshold=0x3E8`** (1000; default 30) | 93.7 | **-3.6% (-3.8, -2.1, -5.0)** | -4.8% (all 3 pairs) | same sign in every pair: confirming in c1 |
| `RuntimeAsync=0` | 95.1 | -2.2% (+1.5, -3.4, -4.7) | -2.8% | mixed signs; MucAspNet measured +2.6% on Synteq (e19): noise |

Round j2 (5 arms x 3; base 97.2): **R2R of our own assembly** (`PublishReadyToRun=true`, FSharp.Core and Npgsql
precompiled too) 93.4 us/req, -3.8% (pairs -8.1, +3.0, -6.3), kcycles -4.3%: mixed sign, confirming in c1. R2R +
`TieredPGO=0`: 107.1, +10.2% (R2R code without PGO is as slow as jitted code without PGO). Composite R2R of the
framework (self-contained): crossgen2 was killed for memory (exit 137) on this 3.9 GB box; retried with
`--parallelism:1`.

What the JIT did (`JitDisasmSummary`, base, 18k users): 8,616 compilations; of the final Tier1 versions, 461 have
"Dynamic PGO", 795 "Synthesized PGO" (no usable profile data), 300 "Static PGO" (from the framework's R2R data).
**Our own hot methods end as "Tier1 with Synthesized PGO"**: `feed`'s state machine `MoveNext`, `send<__Canon>`
(shared generic), `verifyToken`; `readPost` gets Dynamic PGO. So Dynamic PGO's 11% comes mostly from the framework
(Kestrel, Npgsql, STJ), and a higher call-count threshold plausibly gives more methods real profiles (checked in
`jitsum-cct`). Warm-up: the ramp window (0-20 s) costs ~104 us/req vs ~96 steady, and its p99 is ~95-100 ms (vs
10-40 later): tier-up is done within ~20 s, so no warm-up code is worth adding (grader runs ramp >= 60 s).

### Data structures and libraries (batch 1, item 4), 31 Oct

Candidates were listed and challenged with **consult** (DeepSeek + Gemini, session 1031-124301-138e). Changes to
the plan from it: `[<ThreadStatic>]` buffers dropped (F# `.cctor` trap, unsafe across awaits), `[<Struct>]` rows
and `ObjectPool` dropped (expected zero), `RecyclableMemoryStream` kept only as a measured check (it predicted a
loss), two new arms added: unflushed `BodyWriter` writes and writing JSON straight from the reader. Rejected from
it: dropping gzip (the brief keeps gzip), Unix sockets to Postgres (Postgres is on another box when scored),
`ZLibCompressionOptions.WindowBits` (zlib-ng's hash table is fixed at 64K entries, so the memset stays), libdeflate
(native, against the brief).

Use case -> what was tried (all 42/42 on both port orders, gzip bodies checked) -> result, interleaved x 3:

- **L14 JSON write, unflushed `BodyWriter.Write`** instead of `Body.WriteAsync` (base2, STJ kept; 232 lines, +3):
  96.8 vs 95.1 us/req, **+1.8%** (+2.2, -1.5, +4.7), user instructions +6.5%. Kestrel's end-of-request flush plus
  the `IBufferWriter` copy cost more than the flushed write. **Discarded.**
- **L15 gzip buffer sized up front** (`new MemoryStream(json.Length)` instead of growing from 256 B; base3, 0 lines):
  +2.1% in d0 (+3.1, +3.4, -0.3), +2.9% in d2 (+5.9, +0.2, +2.5). Worse twice; one 5 KB zeroed allocation per feed
  does not beat the growth steps. **Discarded.**
- **L16 pooled buffers, `Microsoft.IO.RecyclableMemoryStream` 4.0.1**, STJ serializing into it as an
  `IBufferWriter`, gzip into a second one (base4; 237 lines, +8, +1 package): 94.8 vs 96.1 us/req, **-1.3%** (+0.6,
  -3.0, -1.4), kcycles -2.9% (+1.4, -5.9, -4.1). Under the 5% bar for 8 lines. **Discarded** (re-measured with
  counters below if time allows).
- **L17 routing by F# match** on method + path segments in one `app.Run`, instead of endpoint routing (routeB; 232
  lines, +3): 95.4 vs 96.1, **-0.7%** (-1.1, +0.0, -1.0). Endpoint routing is not where the time goes.
  **Discarded** (it reads well, but it drops routing's trailing-slash/405 behaviour for nothing).
- On the `Utf8JsonWriter` source (json1, control): **L18 unflushed write** (json2) +3.6% (-0.8, +5.6, +6.0) — same
  as L14; **L19 JSON straight from the reader** (json3: no `Post` record, no list) +0.7% (-0.7, -2.3, +5.0);
  **L20 `SkipValidation` + `UnsafeRelaxedJsonEscaping`** (json4) +1.2% (+2.0, -0.6, +2.2). None helps; the
  hand-written writer path stays behind STJ (L1).
- Not measured (built, superseded by the base-derived arms): route1/pool1 on json2, fmt1 (`DateTime.TryFormat("O")`
  into UTF-8, cut to ms, +6 lines: would need >= 5% for its lines, and DateTime formatting is ~1% of busy cycles).
- Arenas: .NET has no maintained arena allocator for managed objects; gen0 is the bump allocator, so the GC knobs
  (batch 2) are the arena experiment.
