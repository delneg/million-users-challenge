# Worklog: fsharp-uring-delneg

Rig: Synteq VPS (8 vCPU Xeon Platinum 8260, 16 GB, Ubuntu 24.04, kernel 6.8.0-117: no buffer-ring bug), Postgres 18
and the load on the same box, the grader's sysctls. Not the grader: numbers here are ours and only compare builds.

## 7 Nov: setup

- Kernel: one 6.8.0 kernel without the -147 buffer-ring bug. Newest 6.8.0 in the archive
  is -149 (affected), so the box boots 6.8.0-117 (GRUB_DEFAULT pinned); the HWE 7.0 kernel briefly installed was
  removed. The fallback (ring -> ring with `resv[0]=1` -> PROVIDE_BUFFERS) stays in the code; `LEGACY_BUFS=1` forces
  PROVIDE_BUFFERS for tests.
- Rig hygiene: nginx (ObjC rig) held :80 after the reboot: stopped. Docker stopped (its NAT table deleted).
- Copied #35's sources, removed Kestrel's host (`Microsoft.NET.Sdk`, plain `main`).

## What the grader says (scoring comments, read 7 Nov)

| entry | 4c held | 4c CPU at hold | 2-min staircase on 4c | 16c p95 / p99 at 1M |
|---|---:|---:|---|---|
| C# #1 `csharp-epoll-jh-d` #59 | 1,430,000 | 72% | passed 1,476,981 (p99 608 ms), failed 1,529,979 | 38.6 / 216 ms |
| Go #65 `go-epoll-trungdlp` | 1,400,000 | 68% | passed ~1.52M, 5-min hold at 1.47M failed | 39.8 / 218 ms |
| ours #35 | 1,340,000 | 47% | passed 1,529,979 (p99 266 ms); 5-min holds at 1.48M / 1.41M failed on timeouts (p99 8.8 s / 1.7 s) | 216 / 236 ms |

All ~20 entries checked show p95 ~210-230 ms and p99 ~220-260 ms at their 4- and 8-core scores, and 8-core scores no
higher than 4-core ones: the wall is the app box's network (loss and TCP retransmission timeouts at ~1.4-1.5M
connections, ~60k req/s), and holds vary run to run. io_uring entries average ~5% below epoll entries.

## Calibration 1: CPU per request, server on 1 vCPU (screen.sh; 100k idle connections; 2 runs each)

| entry | 20k users (8.4k req/s): server kcycles/req, PG kcycles/req, p95 | 36k users (15.2k req/s) |
|---|---|---|
| C# #1 | 102.1 / 238.7 / 6.3 ms | 93.3, 96.3 / 246.5, 270.2 / 7.2, 8.3 ms |
| Go #65 | 97.4, 97.6 / 222.8, 211.6 / 7.9, 7.0 ms | 87.2 / 215.0 / 9.9 ms |
| ours #35 | 64.9, 66.1 / 182.0, 193.7 / 16.1 ms | 62.8 / 198.4 / 19.5 ms |

Our entry costs ~30-35% fewer server cycles per request than C# #1 and Go #65 on this rig, and ~20% fewer Postgres
cycles, yet scored below both: **server CPU on this rig does not predict the board.** CPU stays a secondary metric.

C# #1 r3 (clean, after the r1 runs were spoiled by an orphaned script): 20k 102.3 kcycles/req (PG 222.9), p95 4.9 ms;
36k 98.1 (PG 251.2), p95 7.6 ms. Same picture.

## Calibration 2: segments per request (screen2.sh, loopback MTU 1500, Postgres on its own tc bands; 20k users, 1 vCPU)

Issue #62 relates grader p95/score to TCP segments per request (client + Postgres, both cross the app box's NIC on the
grader: Postgres is on its own machine).

| entry | srv->cli | cli->srv | pg->srv (bytes) | srv->pg | **total** | p95 / p99 |
|---|---:|---:|---:|---:|---:|---|
| C# #1 | 1.001 | 2.001 | 1.053 (1422) | 0.208 | **4.263** | 6.3 / 7.3 ms |
| Go #65 | 1.002 | 2.006 | 1.008 (1369) | 0.137 | **4.153** | 8.1 / 11.8 ms |
| ours #35 | 1.001 | 2.002 | 1.028 (1419) | 0.079 | **4.110** | 18.1 / 24.0 ms |
| v0 (no Kestrel, QUICKACK=0, thin LTO) | 1.003 | 2.008 | 1.027 (1419) | 0.079 | **4.118** | 16.3 / 18.1 ms |

We already send the fewest segments (deep batching: 0.08 Postgres sends per request vs C#'s 0.21). Segment count is
not where #35 loses. What differs is the **blast radius of one lost segment**: with PG_DEPTH=128 fill, a thread's
reads ride one Postgres connection, so one lost Postgres segment stalls 128+ queries for an RTO (>= 200 ms) and
everything queued behind them; C# #1 deals runs of ~16 to the least-loaded connection, so a stalled connection stops
getting work. That matches #35's grader picture (16c p95 216 ms vs C#'s 38.6 ms, at the same network) and its
multi-second timeouts in 5-min holds. Next: Postgres-path loss screens (cal4) and a `PG_RUN=r` dispatch (v3).

## Rig incident: conntrack (7 Nov ~11:50-12:10)

The first 1M-connection holds (sc1m-cs1, sc1m-f35) filled `nf_conntrack` (max 262144; conntrack stays loaded by
Docker's leftover iptables rules) and dropped packets, ssh included: both runs are invalid (fail ~2.1M). The grader's
`setup-app-box.sh` doesn't load conntrack. Fix on the rig: runtime `nf_conntrack_max=4194304`, buckets 1048576 (not
persisted). hi-cs1-r1 ran in the tail of it (only ~127k of 140k sockets up): disregard.

## Calibration 3: Postgres hiccups (CHECKPOINT + VACUUM ANALYZE every 15 s), 40k users, server 4 vCPU

| run | r1 p95 / p99 (worst 5 s p99) | r2 |
|---|---|---|
| C# #1 | (spoiled, see above) | 66.1 / 300.2 (828) |
| #35 | 149.6 / 421.0 (879) | 465.0 / 672.0 (820) |
| v1 | 274.4 / 503.6 (1052) | 285.6 / 455.9 (991) |
| v1 PG_DEPTH=16 | 844.8 / 1116 (1988), fails p95 | 578.8 / 990.6 (1505), fails |
| v1 PG_DEPTH=16 WAIT 64/2 ms | 608.4 / 952.0 (1460), fails | |

Too noisy (#35: 150 vs 465 ms p95 between reps) and confounded: Postgres shares CPUs 4-7 with the load here, so a
shallower dispatch (more Postgres sends, more backends woken) loses to Postgres CPU starvation that the grader's
16-core database box doesn't have. Family dropped; noted only that deep batching is gentler on a starved Postgres.

## Calibration 5: 1M keep-alive connections, server 4 vCPU, 5-min hold, ~16.7k req/s (conntrack fixed)

| entry | fail / timeouts | p50 / p95 / p99 / p99.9 | worst 10 s p99 | retrans |
|---|---|---|---|---|
| C# #1 | 0 / 0 | 4.0 / 6.8 / 9.6 / 54.9 ms | 46.2 ms | 409 |
| #35 | 0 / 0 | 13.7 / 16.3 / 19.3 / 27.4 ms | 27.4 ms | 84 |

Both hold 1M cleanly on loopback (no loss): the rig doesn't reproduce the grader's failure without impairment, which
again points at loss recovery rather than anything in the server at 1M connections.

| #35 MUC_STATS / v3 | | |
|---|---|---|
| v3 (no Kestrel + QUICKACK=0 + thin LTO + REARM_ALL) | 0 / 0 | 13.7 / 16.3 / 19.3 / 23.0 ms, worst 10 s 27.4 ms |
| v3 PG_RUN=16 | 0 / 0 | 9.6 / 11.5 / 11.5 / 19.3 ms, worst 10 s 23 ms |

Conformance v3: 42/42 with GZIP_IMPL=fsharp, LEGACY_BUFS=1, PG_RUN=16 (the default-env run hit errno 98 on port 3000,
a leftover-socket collision right after the 1M hold; rerun pending).

## Calibration 4 (discarded): Postgres-path loss 1% with Postgres and the load sharing CPUs 4-7

Wild results: #35 p95 65 ms, C# #1 322 ms, v3 540 ms, every v3 dispatch variant 550-960 ms (several failing). v3
showed extra client-bound packets (1.26/req, delayed-ACK timer fires 121/kreq vs 8) and ~80% more Postgres CPU per
request. Rerun with Postgres on its own CPUs (cal7, `screen3.sh`: server 0-1, Postgres 2-4, load 5-7), the same #35
vs v3 pair is equal (p95 28.4 vs 27.0 ms, p99 66.1 vs 61.1 ms): cal4 measured a starvation feedback loop on the rig
(slow answers -> delayed-ACK timer packets -> more load/softirq CPU on Postgres's cores -> slower answers), not the
servers. Stopped after r1. **Rule for the rig from here: Postgres never shares CPUs with the load.**

## Calibration 7 (runs 1-7): Postgres-path loss 1%, Postgres on its own CPUs (screen3: server 0-1, PG 2-4, load 5-7)

30k users ts 0.25, 100k idle, ~11.4k req/s, 2 reps (p99 / p95 ms; worst 5 s p99 in brackets):

| run | r1 | r2 | Postgres sends/req | verdict |
|---|---|---|---|---|
| #35 | 66.1 / 28.4 (105) | 62.9 / 27.0 (206) | 0.10 | baseline |
| v3 (default: fill to 128) | 61.1 / 27.0 (212) | 64.8 / 27.0 (83) | 0.10 | keep (= #35) |
| v3 QUICKACK_OFF=0 | 67.5 / 28.4 | 79.1 / 29.0 | 0.10 | no gain |
| v3 QUICKACK_OFF=0 THIN_LTO=0 | 57.0 / 25.7 | 64.2 / 27.3 | 0.10 | noise |
| v3 PG_RUN=16 | **211.9** / 17.6 | **211.9** / 21.3 | 0.20 | discard |
| v3 PG_DEPTH=0 | 222.7 / 62.3 | 197.6 / 82.3 | 1.0 | discard |
| C# #1 | **209.8** / 12.2 | | 0.26 | reference |

The head-of-line theory was wrong for p99: **deep pipelines recover a lost Postgres segment by fast retransmit**
(many segments in flight -> dup ACKs -> ~1 RTT), short flights (runs of 16, C# #1's scheme) wait for TLP/RTO
(~200 ms, single-packet flights get the delayed-ACK allowance). Our default already has the best Postgres-loss tail;
shallow dispatch only buys p95. PG_RUN stays out.

## The 60-second timeouts: a re-arm theory

mload's per-request timeout is 60 s (k6's default), so #35's grader "timeouts" (holds at 1.48M / 1.41M failed, p99
8.8 s / 1.7 s, CPU ~50%) are requests that hung, not TCP retransmissions. In buffer-ring mode #35 re-armed at most
32 multishot receives that ended in ENOBUFS per loop pass (`budget = min rearm.Count (max back 32)`, `back = 32`
with a ring): a burst that empties the 8,192 buffers (a GC pause, a long pass, softirq starving the thread on 4
cores) leaves thousands of connections unarmed, drained at ~32 per pass (<= 4 ms): seconds of hang, and re-armed
sockets with queued data drain the buffers again. v1+ re-arms every one after the buffers are back (REARM_ALL=1).
Test (cal6): 1M connections, 0.5% loss everywhere, MTU 1500, ~25k req/s, NBUFS=64 to force ENOBUFS, REARM_ALL=0
vs 1; v4 logs max pass time, max CQEs per pass, GC pause total and the re-arm queue.

## Calibration 6 (runs 8-11): 1M connections, 0.5% loss on all loopback traffic, MTU 1500, ~25k req/s, 5-min hold

`scale2.sh`: server 4 vCPU, Postgres 4-6, hold 7.

| run | p50 / p95 / p99 / p99.9 ms | worst 10 s p99 | notes |
|---|---|---|---|
| v4 NBUFS=64 REARM_ALL=0 (#35's re-arm budget, buffers scarce) | 27 / **2120** / 3573 / 3573 | 4252 | stall at t=370: io-0 12,977 queries in flight, 131 ms pass, +117 ms GC, ctxs 19.5k/thread (RSS 1.47 GB) |
| v4 NBUFS=64 REARM_ALL=1 | 27 / **313** / 1258 / 1782 | 2120 | same stall at t=370-390, recovers faster |
| v4 (NBUFS 8192) | 27 / 888 / 2120 / 3003 | 3003 | stall at t=490-510, nobufs=0, ~6.5k in flight on every thread |
| C# #1 | 6 / 1782 / 3573 / 4252 | 5060 | stall at t=410 too |

Every run has a global Postgres stall (all threads' in-flight queries climb together; no checkpoint in the log):
Postgres on 3 rig vCPUs at ~25k req/s runs near capacity, and any blip queues for seconds. A rig limit (the grader's
database box has 16 cores), so absolute numbers mean little; but with the same blip, the old re-arm budget turned a
scarce-buffer stall into p95 2.1 s where REARM_ALL=1 gave 0.3 s, and C# #1 rode its stall worse than v4. No request
went unanswered (timeouts 0) in any run. Next: stall bursts without Postgres saturation (cal9: K=60, SIGSTOP 1.5 s
every 60 s), and CQ overflow drops now logged (`cqdrop`, v5).

## Calibration 8 (runs 12-15): client-path loss 2% each way, Postgres clean (screen3, 30k users)

| run | p99 r1 / r2 | p95 r1 / r2 | worst 5 s p99 |
|---|---|---|---|
| v4 (QUICKACK=0, thin LTO) | 231.7 / 229.4 | 67.5 / 51.1 | 239 / 272 |
| v4 THIN_LTO=0 | 231.7 / 229.4 | 63.6 / 46.2 | 356 / 232 |
| v4 QUICKACK_OFF=0 | 229.4 / 231.7 | 53.7 / 62.3 | 236 / 239 |
| #35 | 229.4 / 231.7 | 41.0 / 49.6 | 232 / 239 |
| C# #1 | 214.0 | 25.2 | 218 |

Client-path loss puts everyone at p99 = one RTO + the server's own latency (C# answers in ~12 ms, we batch to ~27
ms at this per-thread rate; at the grader's ~15k req/s per thread the 128-completion wait fills in ~3 ms). Listener
options are neutral here (2% loss rarely loses the same request twice); kept, as in Go #65, for the multi-loss tail.

## Calibration 9 (runs 16-19): stall bursts, 1M connections, ~16.7k req/s, server SIGSTOPped 1.5 s every 60 s

`scale3.sh` (no loss). Each stall shows as one 10 s window with p99 ~1.5-1.8 s (the stall itself) and recovers in
the next window, for everyone: v5 REARM_ALL=0 p99 1057 ms, v5 1057, #35 1258, C# #1 1057 (worst window 1497 vs our
1782). 0 timeouts, 0 failures. Bursts reached 23k CQEs in one pass (CQ is 32k) but no ENOBUFS: 1.5 s at ~4.2k req/s
per thread queues ~6.3k requests, under the 8,192 buffers. cal10 repeats with 3 s stalls (~12.5k per thread).

## 7 Nov ~16:00 UTC: the shipped defaults (v6)

The stall/loss calibration stopped here (cal10 killed mid-run: with 3 s stalls both re-arm modes saw ~4k ENOBUFS per
thread and p95 ~1.1-1.3 s, p99 3.0 s; cal11 never ran): the rig isn't the grader. Next step: spread queries over more
Postgres connections with a shallower pipeline per connection (C# #1's idea), conformance + a quick sanity check.

Chosen from what was measured: 192 read + 64 write connections (256 <= 512; 4 cores: 48 + 16 per thread) and
`PG_DEPTH=32` fill, not runs of 16 (`PG_RUN=16`, the literal C# scheme, gave p99 ~210 ms vs ~63 ms under 1% Postgres
loss in cal7). Depth 32 caps one loss's blast radius at a quarter of #35's and keeps busy connections' flights
long (~30 segments per 32 feeds); untested under loss. `PG_SPREAD` removed.

Checks on v6: `test/run.sh` 42/42 with THREADS=4, THREADS=8, THREADS=4 LEGACY_BUFS=1, THREADS=8 GZIP_IMPL=fsharp.
Sanity: 1 vCPU 20k users: 68.9 kcycles/req (#35 64.9-71.1 on the same screen), Postgres 222 kcycles/req (#35
182-194: more round trips), p95 15.5 / p99 16.8 ms. 2 vCPU 30k users (screen3): p95 17.1 / p99 42.3 ms, 0 errors,
4.197 segments/req, 128 Postgres connections per thread up, nobufs 0, cqdrop 0.

## v7: Postgres watchdog + thin timeouts on Postgres sockets (pushed to PR #103)

A Postgres connection that owes answers and has received nothing for `PG_TIMEOUT_MS` is dropped (queries fail with
08006 -> 500, connection reopened in the background); idle threads wake once a second so the check still runs.
`TCP_THIN_LINEAR_TIMEOUTS` on Postgres sockets by default (`PG_THIN=0` off). Functional check (wd-v7, 2 vCPU, 30k
users, all Postgres traffic cut for 7 s at ~t=75 s, watchdog at 5 s): connections dropped at 5.2 s ("150 queries
owed"), reconnected with no failure, next window normal; but the cut's requests became 500s (2.6% of the run). So
the default is C# #1's 10 s: frees a stuck connection, while a few-second Postgres hiccup only slows requests.
Checks: 42/42 THREADS=4, THREADS=8, THREADS=4 LEGACY_BUFS=1 (5 s build) and THREADS=4/8 (10 s build). Sanity
(san-v7-2c): p95 17.8 / p99 53.7 ms, 0 errors, 4.195 segments/req, 82.8 kcycles/req (v6 80.8), no watchdog trips.

## v8: 16,384 receive buffers per thread (pushed to PR #103)

`NBUFS` default 8192 -> 16384 (32 MB per thread): in cal10's 3 s stalls (~12.5k requests queued per thread) the 8,192
ran out (~4k ENOBUFS per thread); on the grader's 4 cores the threads share their cores with the kernel's network
work, so late passes are likely. Checks: 42/42 THREADS=4, THREADS=16 (16-core layout: 12 + 4 Postgres connections
per thread), THREADS=4 LEGACY_BUFS=1. Sanity (san-v8-2c): p95 16.3 / p99 42.3 ms, 0 errors, 81.7 kcycles/req, RSS
159 MB (v7 ~120 MB).

## v9: reads of a lost Postgres connection go to another connection (pushed to PR #103)

From C# #1's README: on a lost connection, reads (and unsent writes) go to another connection, writes whose fate is
unknown get a 500. Here: reads re-routed after `Retry()` (at most 3 bounces per request), all writes of the lost
connection fail as before. Test (kill-test.sh: 2 vCPU, 30k users, the 20 most recently active backends terminated
twice, 20 s apart): v8 572 x 500 (0.033%), v9 33 x 500 (0.002%), p95 18.5 vs 17.3 ms, worst 5 s p99 88 vs 66 ms.
(Killing 20 random backends first hit idle ones: 0 errors for both.) 42/42 THREADS=4, THREADS=8, LEGACY_BUFS=1.

v10 (discarded): also resend writes still in the unsent buffer when their connection dies (C# #1 does). Same
kill test: 38 x 500 vs v9's 33 (noise): writes leave in the send at the end of every pass, so almost none are unsent
when a connection dies. 42/42 incl. PG_GROUP_WRITES=0, but not worth the code. Reverted.

## Clean install (PR head 7fa3d07), 7 Nov 19:15 UTC

`docker run ubuntu:24.04` (seccomp unconfined for io_uring, host network): install.sh as root (SDK tarball SHA-512
OK, 11.0.100-rc.3.26522.148), build.sh as a fresh user `challenge` (libdeflate + ISA-L from pinned tarballs,
locked restore, publish), start.sh with THREADS=4: `/health` 200 with db ok on both ports after 1 s, "buffer ring",
48 + 16 Postgres connections per thread. Docker stopped again afterwards.

## Profile of the PR head (prof-v9: 1 vCPU, 36k users, perf record 20 s)

Kernel 75% of the server's CPU (TCP for both loopback ends: transmit, ACK handling, lookups; conntrack 2.6% is the
rig's leftover Docker rules; AppArmor socket hooks 1.5%). Our code's biggest items: igzip 3.7%, the feed JSON
(`putPost`) 1.4%. Nothing cheap left on the user side; CPU work stops here.

## Bundle 1 (v11): small byte savings measured together

Went back over the items left below noise or deferred (here and in #35's worklog):

| item | alone | in bundle 1? |
|---|---|---|
| `GZIP_TRAIN=1` default (#35 e3): igzip table rebuilt once a second from a live body; merged c-iouring-einhornimmond does it | CPU neutral, feed 1,961 vs 2,243 B; "discarded as a default" for no CPU gain | **yes**: fewer bytes on the client path |
| ids and like counts as text result columns (Go #65): digits copied into the JSON | not measured before | **yes**: fewer Postgres bytes, no int formatting |
| v10 resend of unsent writes | 38 vs 33 x 500, noise | no: a failure-path change, nothing to measure in a load screen |
| #35 e15/e27 longer waits (256/8 ms, 192/6 ms) | -7% / -1% cycles, p95 up | no: points the wrong way on latency |
| #35 e28 16-byte key stores, e29 `Out.Reserve` fast path | noise | no: Kestrel-era code paths, gone here |
| #35 e30 smaller igzip hash table | needs a patched tarball | no |
| Ctx pool preallocated at startup | fewer POH allocations in a stall only | no: idle in a normal screen, and no more stall tests |

Checks: 42/42 THREADS=4, 8, 16, THREADS=4 LEGACY_BUFS=1, THREADS=4 GZIP_IMPL=fsharp, THREADS=4 PG_TEXT_IDS=0
GZIP_TRAIN=0. jsondiff v9 vs v11: feed, gzipped feed (gunzipped), /posts/1..300 and the odd rows byte-identical.
gzcheck: every arm gunzips to the plain feed (igzip trained 1,961 B, untrained 2,243, libdeflate 1,901, F# 1,926).

Interleaved v9 (PR head) / v11, screen3, 100k idle connections:

| run | p95 / p99 (worst 5 s p99) ms | srv->cli B/req | pg->srv B/req | segments/req | server kcycles/req (user) | PG kcycles/req |
|---|---|---|---|---|---|---|
| 2 vCPU 30k r1 v9 / v11 | 20.0 / 61.1 (104.5) vs 15.6 / 41.9 (113.2) | 717.2 / 613.7 | 1417.9 / 1367.0 | 4.235 / 4.165 | 88.5 (22.4) / 83.4 (20.9) | 242 / 225 |
| r2 | 21.5 / 64.2 (115.5) vs 15.5 / 32.0 (72.3) | 716.0 / 613.5 | 1416.7 / 1367.5 | 4.200 / 4.165 | 87.6 (22.3) / 83.6 (20.9) | 245 / 228 |
| r3 | 19.8 / 53.1 (119.0) vs 19.5 / 53.7 (107.7) | 716.7 / 614.5 | 1418.2 / 1366.8 | 4.200 / 4.177 | 87.1 (21.8) / 90.4 (23.8) | 236 / 262 |
| 1 vCPU 20k r1 | 15.6 / 16.9 vs 15.5 / 16.6 | 717.4 / 614.1 | 1418.9 / 1368.9 | 4.172 / 4.142 | 72.4 (19.3) / 71.5 (18.0) | 227 / 229 |
| r2 | 15.6 / 16.8 vs 15.5 / 16.8 | 716.6 / 613.7 | 1418.8 / 1368.6 | 4.178 / 4.143 | 71.4 (19.0) / 69.9 (18.8) | 225 / 219 |

Bytes to clients -14.4% and from Postgres -3.5% in every run (deterministic), segments lower in all 5 pairs
(-0.03 to -0.07), user cycles -4% on 1 vCPU, 2-vCPU p99 42.5 vs 59.5 ms mean (one pair even). Writes to Postgres
+7 B/req (per-column format codes in each Bind). **Kept**, pushed to PR #103.

## 7 Nov evening: hedged reads, night queue

v12/v13: **hedged reads** (#100's idea, written here for our PgConn): a read connection that owes answers and has
received nothing for `PG_HEDGE_MS` (20), while another read connection of the thread received within that time, has
its owed reads sent again on another read connection (`Fill`, at most 3 sends per request, shared with the lost-
connection re-route); their places in the stalled connection's queue go to a shared `sink` query that drops the late
answers; the stalled connection gets no new queries until it receives again. Writes are never hedged. A thread that
owes reads waits at most PG_HEDGE_MS/2 in `io_uring_enter`. Stress check v12 with `PG_HEDGE_MS=1` (hedge on nearly
every pass): 42/42 on 4/8 threads and LEGACY_BUFS=1, JSON identical to v11, 0 errors under load, but a storm
(Postgres cycles/req 644 vs 225, p99 5.4 s): so v13 adds a storm guard, each read earns 2% of a hedge
(`PG_HEDGE_PCT`), at most 256 saved. Also `PG_RCVBUF` (fixed receive buffer on Postgres sockets) for the queue.

Night queue on the box: `/opt/muc/q/runner.sh` pops `/opt/muc/q/queue.txt` (helpers `/opt/muc/q/lib.sh`), results in
`/opt/muc/q/results.log`, state in `/opt/muc/q/state`. Blocks: A hedging vs v11 (PG 1% loss, no loss, 1 vCPU CPU,
storm guard, 0.5% loss everywhere), B connections x depth with hedging (384x8, 192x16, 96x64, 192x128, base 192x32),
C `PG_RCVBUF` 32/64 KB, D 1M-connection holds (small client buffers; v11 vs v13 at 0.5% loss), E third reps, F CPU of
the depth variants, G small client buffers under loss, H 1M holds of the depth variants.

## Code review notes (7 Nov ~21:15): checked point by point

- Hedging default on before measured: it is uncommitted (v12-v15 builds only); the PR head has none. It ships only if
  blocks A/B keep it, with a rules-check row (rule 3: same statement, re-run only when its connection has gone silent
  while others answer; C# #1 #59 re-sends reads of a lost connection, #100 (open) hedges like this).
- "Spread over 192 connections is mostly nominal": true, `Fill` keeps one or two connections per thread busy; block B
  (connections x depth) decides; README wording to fix.
- Reconnect `Thread.Sleep` in the connector: true (4 workers, up to 1 s per retry each). v15: retries wait on a timer
  (`Task.Delay`), workers only connect. Check queued: `pgre` (Postgres stopped 20 s, time until all 256 are back).
- Per-query `eprintfn` on failure: true (a lost connection or a Postgres restart printed one line per failed query on
  the I/O thread). v15: one line per second with a count.
- Header tab: `Trim(' ').Trim('\t')` left a space after a leading tab; v15 trims both at once.
- QUICKACK inheritance unrecorded: checked now on 6.8.0-117 with rig/inherit.c: `listener: quickack=0 thin=1`,
  `accepted: quickack=0 thin=1`. Both inherit.
- Segment counts on lo count GSO skbs: right, a 2-segment feed counts once. Screen option `LO_GSO=off` added (harness
  only, restored after the run); runs N-v13 and N-cs1 queued for wire-size counts.
- GC: steady state is ~7 gen0 / 6 gen2 per run, 16-31 ms total pause; gen0size not worth a run now. Ctx pool trim and
  1 KB buffers: stall-only, not tested here; noted. SQ 4096 / 18-bit ctx id: cliffs only in long stalls; noted.
- Dead code / knob pruning and docs drift (rules-check row 5, README knobs): after the night queue.

Second set of review notes (kernel cost): packets are the lever. Checked: our headers are 120 bytes on a
gzipped feed (status, Content-Type, Content-Encoding + Vary, Content-Length; no Date, Server or Connection), feed
1,961 + 120 = 2,081 B against a 1,448 MSS: no header trim gets it to one segment. SQ 4096 -> 16384, CQ 32768 ->
65536 (2 MB per ring) taken into the next build: no mid-pass submit in a burst. THREADS = cores - 1 (a free CPU for
the single-queue NIC's softirq on the grader): untestable on loopback; C# #1 also runs one loop per core; kept here
as the one untested bet, not shipped. io_uring bundles / incremental buffers need 6.10+: the grader runs 6.8 (Ubuntu
24.04 family), skipped.

## Night queue results (7 Nov 20:46 - 8 Nov 02:07 UTC), 2 vCPU 30k users unless noted

Tail metric from mload's histogram (`/opt/muc/q/tail.py`: 2400 log bins, bin = floor(100 ln us)): p99.9 and the
share of requests over 200 ms (the retransmission-timeout tail).

**A. Hedged reads (v13) vs PR head (v11).**

| | v11 PR head | v13 hedging (20 ms, guard 2%) |
|---|---|---|
| 1% loss on the Postgres link, 5 reps each: >200 ms | 0.095, 0.084, 0.116, 0.105, 0.128% (mean 0.105) | 0.016, 0.007, 0.012, 0.016, 0.022% (mean 0.015) |
| same, p99.9 ms | 196, 121, 223, 210, 225 (mean 195) | 96, 125, 92, 91, 102 (mean 101) |
| no loss, 3 reps: p99.9 / >200 ms | 91 / 0, 134 / 0, 121 / 0 | 121 / 0, 174 / 0.061%, 177 / 0.068% |
| 1 vCPU, no loss: kcycles/req | 69.1 | 71.6 (64 hedges) |
| 0.5% loss on every link, 3 reps: p99 | 223, 225, 223 | 165, 225, 181 (>200 ms ~1% both: client-path timeouts) |
| 1M connections, 4 vCPU, 0.5% loss everywhere, 3 holds: p99 (worst 10 s) | 110 (313), 23 (27), 27 (186) | 46 (156), 27 (156), 23 (78) |

Under Postgres-link loss hedging cuts the >200 ms tail ~7x and p99.9 ~2x. T=40 ms: tail back to 0.075/0.015%;
T=10 ms: 3.5x the hedges, no better. Storm guard check (`PG_HEDGE_MS=1` with the guard): 8,712 hedges, p99.9 124 ms,
>200 ms 0.0001%: bounded. No-loss: two of three v13 reps had a small >200 ms tail (0.06%) the v11 reps didn't; the
B0 runs later in the night were noisy for every config (B0-base-r2 p99 73 ms), so re-measured in V2 (8 Nov).

**S. Two segments per small response (`SPLIT_SEND=1`).** 0.5% loss everywhere: p99 105/135 vs 200/221 ms, but
>200 ms unchanged (~1%: request losses), segments 6.14 vs 4.20 per request (the client ACKs each pair) and kernel
cycles +45%. **Discarded** (more packets is the wrong way on the grader).

**B. Connections x depth, with hedging (v13):**

| config | PG loss 1%: p99.9 / >200 ms (2 reps) | no loss p99.9 | segments | PG kcycles/req |
|---|---|---|---|---|
| 192+64, depth 32 (base) | 144 / 0.012%, 190 / 0.086% | 73, 142 | 4.19 | 252-264 |
| 192+64, depth 16 | 70 / 0.010%, 115 / 0.016% | 95, 130 | 4.31 | 245-261 |
| 384+64, depth 8 | 860 / 0.69%, 625 / 0.51% | 126, 212 | 4.55 | 282-332 |
| 96+32, depth 64 | 95 / 0.019%, 120 / 0.007% | 87, 126 | 4.13 | 201-226 |
| 192+64, depth 128 | 127 / 0.030%, 121 / 0.014% | 89, 154 | 4.10 | 204-209 |

With hedging, deep pipelines win: fewer segments (-1.5%), -15-20% Postgres cycles, tails as good or better.
1M hold, 0.5% loss: depth 128 p99 33 ms (worst 55), 384x8 p99 131 (worst 221). Picked 96+32 at depth 64 for v16.

**C. `PG_RCVBUF` 32/64 KB:** no gain (PG-loss p99.9 126-165 vs base 144-190, no-loss worse). Discarded.
**D/G. Small client socket buffers (`SO_RCVBUF=4096 SO_SNDBUF=8192`):** 1M hold no-loss p99 16.3 both, kernel TCP
mem 578 vs 390 pages (no saving); under 0.5% loss unchanged. Discarded.
**N. GSO/TSO off on lo:** segments 4.178 vs 4.18 with GSO on: the counts were right; on this seed a gzipped feed
fits one segment (613 B per response on average). The C# run of this block failed to start (not repeated).
**v15 reconnect:** Postgres stopped 20 s under an idle 4-thread server: all 256 connections back 4 s after it
restarted (the v13 comparison run was invalid: its server never logged a connect attempt).

## 8 Nov 07:40 UTC: PR #105 (in #35's folder)

The benchmark agent's comment on #103 (8 Nov): a second version of an entrant's own server is waiting on a decision
(#40, #53, #55 too); the same changes can go to #35's folder as a PR and be re-scored in place. Done with #103's head
(f24c826). Branch `fsharp-kestrel-uring-raw` off upstream/main: f24c826's
files copied into `submissions/fsharp-kestrel-uring-delneg/` (README reworded for the folder, one code comment;
`experiments/` left as it was). 42/42 there with THREADS=4, 8, 16 and LEGACY_BUFS=1. PR #105:
https://github.com/arjaythedev/million-users-challenge/pull/105 (head efd0f92). #103 left open (#105's body says it is the same code
as #103's head and that #103 can be closed).

V1 (1% loss on the Postgres link, 3 reps): >200 ms v11 0.145/0.115/0.101%, v16 (hedging + 96x32 at depth 64)
0.019/0.119/0.021%, v16 without hedging 0.130/0.172/0.139%; segments 4.19 / 4.13 / 4.13; PG kcycles 236-267 /
213-222 / 210-223.

## P1 (8 Nov 08:30-09:00 UTC): Flush probe without hedging, 1% loss on the Postgres link, 3 reps

`PG_PROBE_MS=20`: a connection that owes answers and has received nothing for 20 ms gets one Flush message ('H': no
reply, no query), so a lost last segment of ours is followed by an out-of-order one and repaired by SACK.

| | >200 ms | p99.9 ms | p95 ms | segments | PG kcycles/req |
|---|---|---|---|---|---|
| v11 (PR head, 192+64, depth 32) | 0.090 / 0.429 / 0.102% | 169 / 307 / 206 | 19.8 / 20.2 / - | 4.19-4.22 | 236-239 |
| probe, 192+64, depth 32 | 0.109 / 0.113 / 0.102% | 219 / 214 / 206 | 19.8 / 19.5 / - | 4.19 | 234-238 |
| probe, 96+32, depth 64 | 0.152 / 0.110 / 0.201% | 228 / 212 / 232 | 21.7 / 26.2 / 24.0 | 4.13 | 222-250 |

The probe is neutral on the PR layout and does not bring the deep pipeline's loss tail back (a lost Postgres reply
segment is the common case, and a probe from our side cannot speed its repair). Without hedging the deep pipeline
stays off. Next: v19 = PR head + the review fixes only (connector retries on a timer, Postgres errors logged once a
second, header trim, ring 16384/65536), checked for 42/42, reconnect and a no-loss / PG-loss A/B against v11.

## v20 (8 Nov 09:37-09:55 UTC): probe Sync, and where the timeouts come from

v20 = v19 + a Sync (no SQL) on a Postgres connection that owes answers and has received nothing for 20 ms. 42/42
with THREADS=4, 8, LEGACY_BUFS=1 and PG_PROBE_MS=1; reconnect 4 s.

1% loss on the Postgres link, 3 reps: >200 ms v20 0.124 / 0.112 / 0.098% (mean 0.111), v19 0.108 / 0.149 / 0.127%
(mean 0.128): within noise. TCP timeouts unchanged (0.03-0.05 per 1k requests); ~2 probes per 5 s per thread.

TCP counters over one v19 run (Z2): TCPTimeouts ~70 (TcpTimeoutRehash 72), TCPSackRecoveryFail 63,
TCPLostRetransmit 201, TCPSackRecovery 6,055, TCPFastRetrans 19,118, TCPLossProbeRecovery 678. Most timeouts are a
retransmission lost again during SACK recovery: the sender's congestion window is full, so no new data follows to
reveal the second loss, and a probe's answer can't go out either. Each such timeout stalls the ~30 queries in
flight on that connection, which is the >200 ms share. Next: shallower pipelines (PG_DEPTH 16, 8) with and without
the probe, which covers the lone-segment tail losses short flights make.

## Y4/Y5 (8 Nov 10:12-10:43 UTC): shallower pipelines, 1% PG loss, 2 reps

| config | >200 ms | p99.9 ms | segments | PG kcycles/req |
|---|---|---|---|---|
| v19, depth 32 | 0.135 / 0.114% | 228 / 219 | 4.19-4.25 | 225-242 |
| v20 (probe), depth 16 | 0.071 / 0.163% | 130 / 230 | 4.31 | 246-257 |
| v19, depth 16 | 0.126 / 0.120% | 225 / 225 | 4.31-4.32 | 266-291 |
| v20 (probe), depth 8 | 0.213 / 0.219% | 281 / 284 | 4.49-4.52 | 276-278 |

No loss (v20): depth 16 >200 ms 0%, depth 8 0.019%. Depth does not move the loss tail: fewer queries ride each
connection, but the shallower flights send more Postgres segments, so stalls get more frequent as they get
smaller. And every step down costs packets (+3% at 16, +7% at 8). Depth 32 stays.

## V5 (8 Nov 10:43-11:05 UTC): 1M connections, 4 vCPU, 0.5% loss on all links, 5-min hold

v11: p99 23.0 ms (worst 10 s window 27.4), p99.9 262.9, fail 0, timeouts 0, RSS 263 MB.
v19: p99 27.4 ms (worst 65.4), p99.9 262.9, fail 0, timeouts 0, RSS 349 MB. Same picture; v19 went to PR #105
(873e5ad) after its folder passed 42/42 with THREADS=4, 8, 16 and LEGACY_BUFS=1.

CI on #105 (873e5ad) failed: `io_uring_setup: errno 12` (ENOMEM) with SQ/CQ 16384/65536 on the GitHub runner,
probably because its kernel counts ring memory against a small RLIMIT_MEMLOCK. The ring size change had no
measured gain, so it is reverted to 4096/32768 (5a80ca3); CI green again.

## Y6 (8 Nov 15:24-16:20 UTC): probe Sync, 6 more pairs

1% PG loss, >200 ms, r4-r9: v19 0.097 / 0.119 / 0.109 / 0.126 / 0.111 / 0.088%, v20 0.129 / 0.111 / 0.087 / 0.098 /
0.108 / 0.103%. Over all 9 pairs: v20 mean 0.108%, v19 0.115% (-6%): noise. v20 1M hold (0.5% loss everywhere):
p99 23.0 ms, worst 10 s 32.6, fail 0. The probe is not shipped. Two more v19 reps under PG loss: 0.089 / 0.116%;
under 0.5% loss on all links: 1.029 / 1.025% (the client-path floor: one lost request or lone response segment
waits for a >= 200 ms timer on either side).

C# #1 on the same screens did not start: its build needs the .NET 10 runtime, which is no longer on the box (only
11). Not reinstalled; calibrations 1-2 already compare it on CPU and segments.

## 8 Nov ~19:15 UTC: leaderboard check

Upstream board (ranked by 4 cores): #1 is now `c-epoll-unorig-username` at 1,460,000 after #104 (TCP_DEFER_ACCEPT on
its listeners and the first read right after accept): 4 cores 1,360,000 -> 1,460,000, 8 cores 1,400,000 ->
1,360,000. The benchmark agent called it a per-socket option on the entry's own listeners (java-epoll-stohirov has
it too, 5 s). C# #1 is #2 at 1,430,000. #100 (the same entry's hedged reads, SCHED_IDLE, text id/like_count) is held
unscored: hedging runs a request's SPEC statement twice, sent to the maintainer for a rule-3 ruling. Hedging stays
out here.

v21 = PR #105 head + TCP_DEFER_ACCEPT (1 s, as #104; `DEFER_ACCEPT=0` turns it off). With io_uring, the receive
armed after a multishot accept completes at once, a pass earlier. Queued: 42/42, 3 no-loss pairs against the #105
head, 1M holds (ramp at 3,300 connections a second, like the grader's) with and without loss.

## v21 results (8 Nov 19:36-20:29 UTC): TCP_DEFER_ACCEPT

42/42 with THREADS=4, 8, LEGACY_BUFS=1 and DEFER_ACCEPT=0. No-loss screens, 3 pairs against the #105 head: segments
4.164-4.176 vs 4.165-4.181 (delayed ACKs still inherited), p99.9 94-119 vs 94-169 ms, CPU within noise.

| 1M hold, 4 vCPU, ramp 3,300 conn/s | p99 | worst 10 s | p99.9 | fail | server CPU (s) |
|---|---|---|---|---|---|
| #105 head, no loss | 16.3 | 16.3 | 19.3 | 0 | 328.7 |
| v21, no loss | 16.3 | 16.3 | 19.3 | 0 | 323.9 |
| #105 head, 0.5% loss | 46.2 | 220.9 | 262.9 | 0 | 353.6 |
| v21, 0.5% loss | 23.0 | 27.4 | 262.9 | 0 | 323.6 |

The holds' first 10 s windows show non-200 answers in most versions (v11 372, v13 230, #105 head 276, v21 214 and
1,049): warm-up, excluded from the totals by the hold tool. Pushed to PR #105 (c1b6167, README row
`DEFER_ACCEPT`); CI green. Next: what those warm-up answers are.

## v22 (8 Nov 20:33- UTC): /health waits for every thread's Postgres connections

The hold harness (like the grader) starts its load at the first `/health` 200. `/health` ran on whichever thread
took the probe, so it could pass while other threads were still connecting; their first requests got 500 ("no
database connection"). v22 = v21 + a process-wide count of threads that have had a read and a write connection;
`/health` answers 503 until it reaches the thread count. 42/42 with THREADS=4, 8, 16 and LEGACY_BUFS=1 (first build
failed on a name clash with an existing `ready` field; renamed), reconnect 4 s.

Non-200 answers in the first 10 s of 1M holds: v21 214 / 1,049 / 415, #105 head 0 / 276; v22 (first hold) 0.
v22 1M holds: no loss p99 16.3 (worst 19.3), first-10 s non-200 0; 0.5% loss p99 27.4 (worst 220.9), first-10 s
non-200 0, fail 0. Pushed to PR #105 (6e980c8, README note); CI green.

## 8 Nov ~21:20 UTC: PR #105 scored at 5a80ca3

| cores | held 5 min | req/s | p95 | p99 | app CPU | Postgres box |
|---|---:|---:|---:|---:|---:|---:|
| 16 | 1,000,000 (max) | 32,527 | 40.2 ms | 229 ms | 13% | 24% / 31% max |
| 8 | 1,290,000 | 40,104 | 221 ms | 236 ms | 25% | 27% / 36% |
| 4 | 1,240,000 | 38,829 | 58.7 ms | 232 ms | 38% | 24% / 32% |

8 cores: the 2-min step at 1,391,997 failed (p95 853 ms, p99 1.43 s, CPU 25%); 4 cores: the step at 1,333,992 failed
(p95 2.5 s, p99 3.4 s, CPU 48%). Below #35's acce162 run (1,330,000 / 1,340,000; its 4-core staircase passed
1,529,979), and a re-score replaces the row: the entry is now #25. 16 cores improved (p95 216 -> 40 ms). Not
merged: the head moved during the run (c1b6167, 6e980c8); 6e980c8 is queued for its own run.

Defaults changed since #35: Postgres 64+32 at depth 128 -> 192+64 at depth 32, NBUFS 8192 -> 16384, GZIP_TRAIN 0 -> 1,
listener QUICKACK_OFF and THIN_LTO, PG_THIN, REARM_ALL, a 10 s Postgres watchdog, read re-send on a lost connection,
no Kestrel host. GC is the same in both (workstation, non-concurrent, set in the project file).

The collapse came at ~42k req/s with ~1.33M connections, CPU under 50%: a stall, not CPU. Our 1M holds ran at
16.7k req/s (K=60). New screen `h1mk`: 1M connections at K=26 s (~38k req/s, the 4-core regime), 0.5% loss on all
links; queued: #35's merged code (m35) vs the #105 head (v22) vs v22 with #35's defaults
(64+32, depth 128, NBUFS 8192, GZIP_TRAIN 0), 2 rounds.

## G / G2 (8 Nov 21:45-22:15 UTC): trying to reproduce the grader's 4-core collapse

- `h1mk`, 1M connections at K=26 (~38k req/s), 4 server vCPU, 0.5% loss: v22 collapsed during the ramp (p50 up to
  5-6 s, RSS 3.4 GB), but the rig's Postgres was saturated (2.91 of its 3 cores): a rig limit (the grader's
  Postgres box ran at 24-32%).
- `h2g`, 2 server threads, 660k connections (~330k per thread, as 1.33M on 4), K=26 (~12.7k req/s per thread),
  Postgres on 3 CPUs (2.2 cores used), connection totals halved to keep the 4-core per-thread layout: v22 steady
  (p99 27-33 ms, RSS 267 MB) until t=390, then Postgres fell behind (in flight per thread 150 -> 11.7k -> 70k in
  30 s), p99 7.2 s, RSS 2.5 GB, recovered at t=530. No Postgres log event at that time. #35's merged code (m35, its
  own defaults) stalled the same way (p50 3 s at t=330, recovered by t=350). Both stall, so this screen does not
  separate the code that held 1.34M on the grader from the code that held 1.24M.
- Next: the same at K=34 (~9.7k req/s per thread, the grader's failing step per thread): v22, m35 and v22 with all
  of #35's network defaults (64+32 at depth 128, NBUFS 8192, GZIP_TRAIN 0, QUICKACK_OFF 0, THIN_LTO 0, PG_THIN 0).

## v23 (8 Nov 22:22 UTC): pushed to PR #105 (566e3af)

The loopback screens can't separate the two layouts (both stall on the rig's Postgres), and the grader put #35's
defaults 100k users ahead on 4 cores. v23 = the #105 head with #35's network defaults back: 64 + 32 connections at
depth 128, NBUFS 8192, GZIP_TRAIN 0, QUICKACK_OFF 0, THIN_LTO 0, PG_THIN 0. Kept: TCP_DEFER_ACCEPT, the `/health`
gate, reconnect timer, rate-limited error log, header trim, self-connect guard, read re-send on a lost connection,
REARM_ALL. The other values stay as knobs (README updated). CI green (42/42). Box checks (42/42 x4, reconnect,
no-loss screen) and the K=34 grader-load holds are queued.

## G3 (8 Nov 22:15-23:17 UTC): grader-load holds at K=34

660k connections, 2 threads (~330k each), K=34 (~9.7k req/s per thread), 0.5% loss on all links, 2 reps:

| config | p95 | p99 | worst 10 s | server CPU s |
|---|---|---|---|---|
| v22, 192+64 at depth 32 (halved: 96+32) | 23.0 / 23.0 | 27.4 / 27.4 | 27.4 / 32.6 | 288 / 272 |
| #35 merged code (m35), 64+32 at 128 (halved) | 38.8 / 38.8 | 46.2 / 46.2 | 220.9 / 220.9 | 276 / 277 |
| v22 with all of #35's defaults (= v23) | 32.6 / 38.8 | 38.8 / 38.8 | 262.9 / 77.8 | 280 / 279 |

No stall at this rate. The rig again prefers the shallow layout; the grader preferred #35's by 100k users on 4
cores, so the rig does not predict the board on this question (as calibration 1 already showed for CPU).

v23 box checks: 42/42 with THREADS=4, 8, 16 and LEGACY_BUFS=1. The first reconnect check reported a failure, but it
counted on 64 connections per thread and v23 has 24: all four threads were back at 24. `pgre` now reads the expected
count from the server's startup line.
v23 (566e3af) on the box, 9 Nov 06:52-07:13 UTC: reconnect 4 s (fixed check); K=34 grader-load hold p95 32.6, p99
38.8, fail 0; 1M hold (0.5% loss) p99 38.8 ms (worst 10 s 220.9), p99.9 262.9, fail 0, no warm-up non-200s, RSS
175 MB.

## P (9 Nov 07:14-07:38 UTC): packets per request on v23, GSO off on lo (wire segments), 2 reps

| v23 + | segments/req | bytes per response | srv->cli pkts |
|---|---|---|---|
| (as pushed) | 4.100 / 4.100 | 716 | 1.001 / 1.000 |
| GZIP_TRAIN=1 | 4.103 / 4.100 | 614 | 1.004 / 1.001 |
| QUICKACK_OFF=1 | 4.103 / 4.100 | 716 | 1.003 / 1.001 |
| both | 4.101 | 613 | 1.001 |

Neither knob changes the packet count on this seed: a response is one segment with or without Huffman retraining,
and the request's ACK rides on the response either way. Restoring #35's defaults cost no packets; depth 128 gives
4.100 against ~4.19 at depth 32.

## C (9 Nov 07:45-09:20 UTC): congested link instead of random loss

`scale2.sh` takes `NETEM_EXTRA` / `NETEM_LIMIT` (harness only, removed after the run): a netem rate cap with a
2,000-packet queue on lo, no random loss, on the 2-thread grader-load screen (660k connections, K=34). Uncapped,
a run moves ~35 GB / 50M packets (v23 3.6% more bytes than v22: no Huffman retraining; packets equal).

| cap | v23 (#105 head) | v22 (192+64 at 32) |
|---|---|---|
| 500 Mbit (bytes) | collapse: 2.7M drops (5%), p50 10-14 s, timeouts | not run |
| 1000 Mbit | 0 drops, p95 38.8, p99 38.8 | 0 drops, p95 19.3, p99 23.0 |
| 850 Mbit | 0 drops, p95 32.6, p99 38.8 (worst 65.4) | 0 drops, p95 19.3, p99 27.4 (worst 220.9) |

The packets-per-second runs (`rate X packetoverhead 10000`) never installed: this tc takes the overhead
positionally (`rate X 10000`); the harness ran them uncapped (0 drops, as expected). Re-run with the fixed syntax
(Cq, 09:17-10:23 UTC; 10,000 B charged per packet, so the cap is mostly a packet rate, ~100k pps demand):

| cap | v23 | v22 |
|---|---|---|
| 10g | 0 drops, p95 38.8, p99 38.8 | not run |
| 9g | 0 drops, p99 38.8 | 2,040 drops, p99 27.4, p999 372 |
| 8.5g | 0 drops, p99 38.8 | 10,625 drops, p99 23.0, 801 timeouts |
| 8g | collapse: 190,774 drops, 944 timeouts, p95 3.6 s, p99 7.2 s | 0 drops, p99 23.0 |

Not monotonic (v22 dropped at 9g and 8.5g but not at 8g), and the 8g collapse goes against the grader's preference
for v23's layout. Run 50, discard: a link cap on lo doesn't reproduce the grader either.
v23's median is ~27 ms against ~16 ms for v22 on every screen (depth-128 batching), far under the 500 ms limit.

## Grader result for 566e3af (9 Nov, ~12:15 UTC)

#105 re-scored at 566e3af: 1,000,000 (max) / 1,320,000 / **1,420,000** (16/8/4 cores), p95 212/227/227 ms, app CPU
14/26/46 %, Postgres box 25-35 %. Up from 1,290,000 / 1,240,000 at 5a80ca3. Merged, #3 on the board (ranked by 4 cores).
Failed steps: 8 cores at 1,422,000 (p95 2.9 s, CPU 25 %), 4 cores at 1,519,980 (p95 5.7 s, CPU 51 %).

Reading: the limit is ~1.42-1.52M on both 4 and 8 cores, while app CPU is about 2 cores in every row (14 % of 16,
26 % of 8, 46-51 % of 4). The README says the kernel's network processing runs on the same cores on 4 and 8, so
the CPU the grader reports likely leaves out much of the kernel's share. The leaders sit at 1.43M (C#) and 1.46M (C), the same
ceiling. What can still move: kernel and app work per request (packets, syscalls, wake-ups).

## R (9 Nov 12:41 UTC-): server CPU and packets per request on the merged code

`scale2.sh` now also writes `pgsegs.txt` (segments in and out on the server's Postgres sockets, from `ss -ti`, before
the server stops), so packets split into client and Postgres traffic. Metric: server cgroup CPU microseconds per
request over the run (`mon.log`), h2g K=34, no loss, 32+16 connections (the 4-core per-thread layout).
(The old `G-v23-base` run folder from 8 Nov was overwritten by a mislabeled start of this series.)

`q/steady.sh` reads the cgroup CPU from `mon.log` between 250 s and 520 s after the start (after the 231 s
warm-up), so the ramp doesn't count. Same load in every run (660k connections, K=34, ~19.4k req/s, 2 threads).

| run | change | steady cores | p95 / p99 / p99.9 ms | Postgres segs out / in per request | lo packets |
|---|---|---|---|---|---|
| R-v23-base | merged code, 32+16 | 0.589 | 32.6 / 38.8 / 38.8 | 0.089 / 1.610 | 49.97M |
| R-v23-c16 | 16+8 connections | 0.584 (-0.8%) | 32.6 / 38.8 / 38.8 | 0.089 / 1.610 | 50.03M |
| R-v23-w8 | WAIT_US 8000 | 0.590 (+0.2%) | 54.9 / 54.9 / 65.4 | 0.082 / 1.608 | 52.03M |
| R-v23-base2 | merged code again | 0.611 (+3.7%) | 32.6 / 38.8 / 38.8 | 0.089 / 1.610 | 49.99M |

| R-v23-gz | GZIP_TRAIN=1 | 0.584 (-0.8%) | 32.6 / 38.8 / 65.4 | 0.089 / 1.610 | 49.97M (3.5% fewer bytes) |

Two identical runs differ by 3.7% in steady CPU, so the floor for this metric is ~4%. Run 54, discard: gzip
retraining saves bytes but no CPU and no packets.

- Runs 51-52, discard: neither fewer connections nor a longer wait changes CPU at this per-thread rate; the wait
  only adds latency. Fewer connections don't make bigger sends because each 4 ms pass already goes to the first
  connection with room (Fill), so the send count per pass is the same.
- Run 53: a 2.9 s tcpdump of steady client traffic: 91,259 requests, 91,136 responses, 91,136 client ACKs, 1 server
  pure ACK. Three packets per request is the floor for request/response (the server's ACK rides on the response).
  The ~4 per request in tc's total come from the 660k handshakes and closes. The Postgres inbound bytes are the 20
  post bodies per feed. Nothing removable left on the wire.
- Second opinions (GPT-6 Astra and Gemini 3.8 Flash, three rounds) proposed binary result columns (already done:
  created_at binary, ids as text on purpose), a per-connection memory cut (app RSS extrapolates to ~0.4 GB at 1.5M),
  WAIT_US 8000 and fewer connections (both measured above). Both ended on keeping the merged code.
| R-v23-900k | 900k connections, K=46 (same req/s) | 0.625 (+2-6%, window overlaps the 273 s ramp) | 38.8 / 38.8 / 262.9 | 0.091 / 1.610 | 56.45M |

Run 55: 36% more connections at the same request rate cost little CPU (RSS 162-220 MB); not a connection-count limit.

## PR #108 (9 Nov 13:40 UTC): GZIP_TRAIN on by default

Branch `fsharp-kestrel-uring-gztrain` from upstream main (the merged #105), one line: `GZIP_TRAIN` default 0 -> 1, README
updated. Rig: 3.5% fewer bytes, same packets and CPU (run 54). The scored 566e3af had it off, so its score isolates
this one change.

## The grader box (from `box/setup-app-box.sh`)

somaxconn and tcp_max_syn_backlog 65535, netdev_max_backlog 250000, tcp_mem 1572864/2097152/3145728 pages (6/8/12 GB),
tcp_rmem/wmem 4096 16384 4194304, fq qdisc (limit 200000, flow_limit 1000), and RPS on `rx-0` only, across all CPUs
with RFS (65536 flow entries). Unverified reading: if the NIC has one receive queue, every packet's interrupt and GRO
run on one CPU before RPS spreads the protocol work, a limit shared by every entry and unrelated to core count; that
would fit the 1.42-1.46M tie at the top. On loopback there's no NIC, GRO or RPS, which is one more reason the rig
doesn't rank layouts the way the grader does. Receive packets per request on the app box: the client's request and
its ACK of the response (2, out of our control), plus Postgres replies (1.61 segments per request before GRO).

## R, last run (9 Nov 13:43-13:53 UTC)

| R-v23-base3 | merged code, third time | 0.633 | 38.8 / 38.8 / 54.9 | 0.089 / 1.610 | 50.01M |

Three identical runs: 0.589, 0.611, 0.633 cores (~7% spread), so every candidate above sits inside the noise. With
`bytes_received` added to `pgsegs.txt`: Postgres sends 2,170 B per request to the server (1,348 B per segment, mostly
full) and receives 43 B. Outside the post bodies, only the DataRow framing (~27 B per row: type, length, column count, five
column lengths) is left; folding columns into one would cut maybe 15% of a feed reply, but it moves response building into
SQL, the same rules question as `json_agg`, so it stays out.

Second opinions, round 4 (the grader box setup, single-queue reading): GPT-6 Astra and Gemini 3.8 Flash both advised
against a THREADS = cores - 1 PR without evidence (uncertain sign; the scheduler doesn't reserve a CPU without
pinning) and saw no other in-process change aimed at that limit.

## T, gzip sizes, the NIC, PR #109 (9 Nov 13:54-14:31 UTC)

- Run 57 (crash, rig limit): 4 vs 3 threads on 4 server vCPU at 900k connections, K=34: the 4-thread run collapsed at
  0.93 server cores (p95 746.6 ms) because the load generator had one CPU; stopped and redone smaller.
- Run 58: 3 vs 2 threads on 3 server vCPU (660k, K=34, 48+24 total, hold on 2 CPUs): 0.623 vs 0.595 cores, p95 32.6
  both, p99 32.6 / 38.8. One thread fewer than cores costs nothing measurable at this load.
- Run 59: feed gzip sizes (raw 5,102 B, headers 120 B): igzip L0 2,243 / L0+train 1,961 / L1-L3 1,934-1,918; libdeflate
  L1 1,901, L6 1,866, L9 1,863, L12 1,838. No level fits a feed in one segment; the post reply is 307 B.
- `LEADERBOARD.md`: the grader's app box is a Synteq VPS, 16 dedicated vCPU, Xeon Platinum 8260. Our box (Synteq, same
  CPU model, 8 vCPU): `virtio_net`, `ethtool -l` combined 1 (max 1), RX ring 1024, TX ring 256. With the setup script
  configuring RPS on `rx-0` only, the grader box very likely has one receive queue too: one core takes every packet's
  interrupt and GRO. The ~212 ms p95 at 1M on 16 cores (14% app CPU, load generators in the same datacenter) fits >5%
  of requests waiting out the 200 ms minimum RTO, i.e. drops even below the limit (unverified).
- Run 60: PR #109, `THREADS` default cores - 1 (3 on 4), Postgres totals 64+32 (22+11 per thread on 4 cores),
  branch `fsharp-kestrel-uring-threads` from upstream main, independent of #108. Second opinions (round 5, with
  the NIC evidence): both for a PR now as a separate experiment; strongest risk named: three threads may not free the
  interrupt core and leave less concurrency near the limit.
- Run 61: branch `fsharp-kestrel-uring-combo` (c200975, #109 + #108, pushed without a PR) built on the box as v24:
  42/42, and a hold on 3 server vCPU with its own defaults (2 threads, 64+32): 0.580 cores, p95 32.6, p99 38.8.
  Ready to open if both PRs score above 1.42M.
