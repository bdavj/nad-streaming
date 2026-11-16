#!/usr/bin/env python3
"""Disassemble a Go function (32-bit ARM, stripped) by name regex, annotating calls with Go function names
and movw/movt or literal-pool constants with the string/bytes they point at.
usage: goasm.py <elf> <funcs-file from gofunc.py> <name-regex>"""
import re, bisect, struct, subprocess, sys
elf, funcs, pat = sys.argv[1], sys.argv[2], re.compile(sys.argv[3])
F = sorted((int(a, 16), int(b, 16), n) for a, b, n in (l.split(' ', 2) for l in open(funcs).read().splitlines()))
starts = [f[0] for f in F]
def fn(a):
    i = bisect.bisect_right(starts, a) - 1
    return F[i][2] if i >= 0 and F[i][0] <= a < F[i][1] else '?'
d = open(elf, 'rb').read()
shoff, = struct.unpack_from('<I', d, 0x20); se, sn, _ = struct.unpack_from('<HHH', d, 0x2e)
secs = [struct.unpack_from('<IIIIIIIIII', d, shoff + i * se) for i in range(sn)]
def v2o(va):
    for s in secs:
        if s[3] and s[3] <= va < s[3] + s[5] and s[1] != 8: return va - s[3] + s[4]
def show(v):
    o = v2o(v)
    if o is None: return f'{v:#x}'
    s = d[o:o + 64]
    return f'{v:#x} ' + repr(s.split(b'\0')[0][:64] if s[:1].isascii() else s[:16])
for a, b, n in F:
    if not pat.search(n): continue
    print(f'==== {n} {a:#x}-{b:#x}')
    out = subprocess.run(['/Library/Developer/CommandLineTools/usr/bin/objdump', '-d', '--triple=armv7', f'--start-address={a:#x}', f'--stop-address={b:#x}', elf], capture_output=True, text=True).stdout
    mw = {}
    for ln in out.splitlines():
        m = re.match(r'\s*([0-9a-f]+):\s+[0-9a-f]+\s+(\w+)\s*(.*)', ln)
        if not m: continue
        pc, op, args = int(m.group(1), 16), m.group(2), m.group(3)
        note = ''
        if op in ('bl', 'b') and (t := re.search(r'0x([0-9a-f]+)', args)) and op == 'bl': note = fn(int(t.group(1), 16))
        if (mm := re.match(r'(r\d+), #(\d+)$', args.split(' @')[0].strip())):
            if op == 'movw': mw[mm.group(1)] = int(mm.group(2))
            elif op == 'movt' and mm.group(1) in mw: note = show((int(mm.group(2)) << 16) | mw[mm.group(1)])
        if op == 'ldr' and (mm := re.match(r'r\d+, \[pc, #(-?(?:0x)?[0-9a-f]+)\]', args)):
            o = v2o(pc + 8 + int(mm.group(1), 0))
            if o is not None: note = show(struct.unpack_from('<I', d, o)[0])
        print(f'{pc:x} {op:6} {args.split(" @")[0][:38]:38} {"; " + note if note else ""}')
