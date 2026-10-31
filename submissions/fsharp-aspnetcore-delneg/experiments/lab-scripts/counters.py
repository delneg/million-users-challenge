#!/usr/bin/env python3
# Summarizes a run's counters.csv (COUNTERS=1 screen): per request allocated bytes, GCs per 100k requests, GC pause,
# lock contentions and thread-pool work items per request.   counters.py <run dir> [...]
import csv, re, sys
for d in sys.argv[1:]:
    rate = {}
    for row in csv.DictReader(open(d + '/counters.csv')):
        rate.setdefault(row['Counter Name'], []).append(float(row['Mean/Increment']))
    req = float(re.search(r'req/s=(\d+)', open(d + '/result.txt').read()).group(1))
    m = lambda k: sum(rate.get(k, [0])) / max(len(rate.get(k, [0])), 1)
    g = lambda n: m('dotnet.gc.collections ({collection} / 1 sec)[gc.heap.generation=%s]' % n) * 1e5 / req
    print('%s: req/s=%.0f alloc=%.0f B/req  GCs per 100k req: gen0 %.1f gen1 %.1f gen2 %.2f  pause %.2f%%  contentions/req %.4f  tp items/req %.3f' % (
        d.rstrip('/').split('/')[-1], req, m('dotnet.gc.heap.total_allocated (By / 1 sec)') / req, g('gen0'), g('gen1'), g('gen2'),
        100 * m('dotnet.gc.pause.time (s / 1 sec)'), m('dotnet.monitor.lock_contentions ({contention} / 1 sec)') / req,
        m('dotnet.thread_pool.work_item.count ({work_item} / 1 sec)') / req))
