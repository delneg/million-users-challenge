#!/usr/bin/env python3
# Aggregates an interleaved round: runs/<tag>-<arm>-r<k>/result.txt. The first arm (or --base ARM) is the control;
# for every other arm: mean, and the per-round difference vs the control (sign per pair).
#   agg.py <tag> [--base ARM]          (run on opt-box; reads ~/muclab/runs)
import glob, os, re, statistics as st, sys
tag = sys.argv[1]
base = sys.argv[sys.argv.index('--base') + 1] if '--base' in sys.argv else None
R = os.path.expanduser('~/muclab/runs')
runs = {}
order = []
for d in sorted(glob.glob(f'{R}/{tag}-*-r*'), key=os.path.getmtime):
    m = re.match(rf'{re.escape(tag)}-(.+)-r(\d+)$', os.path.basename(d))
    if not m or not os.path.exists(d + '/result.txt'): continue
    t = open(d + '/result.txt').read()
    g = lambda p, cast=float: cast(re.search(p, t).group(1)) if re.search(p, t) else None
    v = dict(us=g(r'srv us/req=([\d.]+)'), cg=g(r'cgroup us/req=([\d.]+)'), kc=g(r'kcycles user=[\d.]+ kernel=[\d.]+ total=([\d.]+)'),
             ki=g(r'kinstr user=([\d.]+)'), p95=g(r'RESULT .*p95=([\d.]+)ms'), p99=g(r'RESULT .*p99=([\d.]+)ms'), pg=g(r'pg us/req=([\d.]+)'),
             lg=g(r'lg util=(\d+)'), util=g(r'util=(\d+)%'), rss=g(r'rss_kB_idle=(\d+)'), up=g(r'health_after_s=([\d.]+)'),
             eus=g(r'early 0-20s: reqs=\d+ srv us/req=([\d.]+)'), err=g(r'err=([\d.]+)%'),
             ep99=max(map(float, re.search(r'p99 per 5s=\[([^\]]*)\]', t).group(1).split(', '))) if re.search(r'p99 per 5s=\[([\d., ]+)\]', t) else None,
             abort='ABORT' in t)
    arm, r = m.group(1), int(m.group(2))
    if arm not in order: order.append(arm)
    runs.setdefault(arm, {})[r] = v
base = base or order[0]
mean = lambda xs: st.mean(xs) if xs else float('nan')
print(f'{tag}: control {base}; per arm: n, srv us/req (mean, min-max), cgroup us/req, user kinstr, kcycles, p95/p99 ms, pg us/req, lg util, util, idle RSS MB, health s, early us/req, early p99 max')
for arm in order:
    rs = runs[arm]
    f = lambda k: [x[k] for x in rs.values() if x[k] is not None]
    us = f('us')
    line = (f'{arm:>10} n={len(rs)} us={mean(us):6.1f} ({min(us):.1f}-{max(us):.1f}) cg={mean(f("cg")):6.1f} ki={mean(f("ki")):6.1f} kc={mean(f("kc")):6.1f} '
            f'p95/p99={mean(f("p95")):.1f}/{mean(f("p99")):.1f} pg={mean(f("pg")):.1f} lg={mean(f("lg")):.0f}% util={mean(f("util")):.0f}% '
            f'rss={mean(f("rss"))/1024:.0f} up={mean(f("up")):.2f} early={mean(f("eus")):.1f} ep99={mean(f("ep99")):.0f}'
            + (' ABORTED' if any(x['abort'] for x in rs.values()) else '') + (f' err={max(f("err"))}%' if f('err') and max(f('err')) > 0 else ''))
    if arm != base:
        pairs = [(rs[r]['us'] - runs[base][r]['us']) / runs[base][r]['us'] * 100 for r in rs if r in runs[base]]
        kp = [(rs[r]['kc'] - runs[base][r]['kc']) / runs[base][r]['kc'] * 100 for r in rs if r in runs[base] and rs[r]['kc'] and runs[base][r]['kc']]
        line += f'  vs {base}: us {mean(pairs):+.1f}% [{", ".join(f"{p:+.1f}" for p in pairs)}] kc {mean(kp):+.1f}% [{", ".join(f"{p:+.1f}" for p in kp)}]'
    print(line)
