#!/usr/bin/env python3
"""Decode strace -xx output: summarise syscalls per fd and print decoded payloads."""
import re, sys, collections
LINE = re.compile(r'^(\d+)\s+(\S+)\s+(\w+)\((\d+),?\s*(.*)\)\s+=\s+(-?\d+)')
HEX = re.compile(r'"((?:\\x[0-9a-f]{2})*)"')
def payload(args):
    m = HEX.search(args)
    return bytes.fromhex(m.group(1).replace('\\x', '')) if m else b''
def show(b, n=300):
    s = ''.join(chr(c) if 32 <= c < 127 else ('\\n' if c == 10 else ('\\r' if c == 13 else '.')) for c in b[:n])
    return s + ('…' if len(b) > n else '')
path, mode = sys.argv[1], (sys.argv[2] if len(sys.argv) > 2 else 'summary')
fds = set(sys.argv[3].split(',')) if len(sys.argv) > 3 else None
stats = collections.Counter(); sizes = collections.defaultdict(int)
for ln in open(path, errors='replace'):
    m = LINE.match(ln)
    if not m: continue
    tid, ts, call, fd, args, ret = m.groups()
    if int(ret) < 0: continue
    stats[(fd, call)] += 1; sizes[(fd, call)] += int(ret)
    if mode == 'dump' and (fds is None or fd in fds):
        b = payload(args)
        print(f'{ts} {call:9} fd={fd:3} ret={ret:6} {show(b)}')
if mode == 'summary':
    for (fd, call), n in sorted(stats.items(), key=lambda x: (int(x[0][0]), x[0][1])):
        print(f'fd={fd:3} {call:10} calls={n:6} bytes={sizes[(fd, call)]}')
