#!/usr/bin/env python3
# Prints interleaved queue lines for a multi-arm A/B: round r runs every arm once (A, B, C, ...), for REPS rounds.
#   gen.py <tag> <users> <reps> <arm> [<arm> ...]     arm = label:builddir[:ENV=VAL,ENV=VAL]
# e.g. gen.py j1 18000 3 base:base pgo0:base:DOTNET_TieredPGO=0  >> ~/muclab/queue.txt
# Env prefix for screen.sh itself (COUNTERS=1, PERF=1, HOLD=...) via SCREEN_ENV.
import os, sys
tag, users, reps = sys.argv[1], sys.argv[2], int(sys.argv[3])
pre = os.environ.get('SCREEN_ENV', '')
S = '~/muclab/repo/submissions/fsharp-aspnetcore-delneg/experiments/lab-scripts'
for r in range(1, reps + 1):
    for arm in sys.argv[4:]:
        p = arm.split(':', 2)
        label, build = p[0], p[1]
        env = ' '.join(p[2].split(',')) if len(p) > 2 and p[2] else ''
        print(f'{pre} bash {S}/screen.sh {tag}-{label}-r{r} {users} 0.25 20000 ~/muclab/builds/{build} {env}'.strip())
