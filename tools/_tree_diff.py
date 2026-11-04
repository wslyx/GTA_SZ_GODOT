import re
groups = []
cur = None
for line in open('tools/_tdump.log', encoding='utf-8', errors='ignore'):
    if '[tree-dump] /' in line:
        if cur is None:
            cur = []
        cur.append(line.split('[tree-dump] ')[1].strip())
    m = re.search(r'tree-dump\] \(chunks_root 节点 (\d+)\)', line)
    if m and cur is not None:
        groups.append(cur)
        cur = None
print('dump 组数:', len(groups))
first, last = groups[0], groups[-1]
from collections import Counter
c1, c2 = Counter(first), Counter(last)
print('首跳 %d 节点, 末跳 %d 节点' % (len(first), len(last)))
diffs = []
for k in set(c1) | set(c2):
    d = c2.get(k, 0) - c1.get(k, 0)
    if d != 0:
        diffs.append((d, k, c1.get(k, 0), c2.get(k, 0)))
diffs.sort(reverse=True)
print('== 增量 Top:')
for d, k, a, b in diffs[:25]:
    print('%+3d  %4d->%4d  %s' % (d, a, b, k))
