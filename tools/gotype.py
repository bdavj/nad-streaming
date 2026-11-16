#!/usr/bin/env python3
"""Dump a Go struct's fields (name, type, offset, tag) from a 32-bit ARM Go ELF via reflect metadata."""
import struct, sys
path, want = sys.argv[1], sys.argv[2:]
f = open(path, 'rb').read()
e_shoff, = struct.unpack_from('<I', f, 0x20); shentsize, shnum, shstrndx = struct.unpack_from('<HHH', f, 0x2e)
secs = []
for i in range(shnum):
    nm, typ, flags, addr, off, size = struct.unpack_from('<IIIIII', f, e_shoff + i*shentsize)
    secs.append([nm, addr, off, size])
stro = secs[shstrndx][2]
named = {}
for s in secs:
    n = f[stro + s[0]: f.index(b'\0', stro + s[0])].decode(); named[n] = s
def rd(va, n):
    for _, addr, off, size in secs:
        if addr and addr <= va < addr + size: return f[off + va - addr: off + va - addr + n]
def u32(va): return struct.unpack('<I', rd(va, 4))[0]
def varint(b, i):
    v = s = 0
    while True:
        c = b[i]; v |= (c & 0x7f) << s; i += 1; s += 7
        if not c & 0x80: return v, i
def name_at(va):
    b = rd(va, 600); flags = b[0]; n, i = varint(b, 1); nm = b[i:i+n].decode('latin1'); i += n; tag = ''
    if flags & 2:
        tn, i = varint(b, i); tag = b[i:i+tn].decode('latin1')
    return nm, tag
ro = named['.rodata']; base = (ro[1] + 31) & ~31  # runtime.types is 32-byte aligned at .rodata start
rodata = f[ro[2]: ro[2] + ro[3]]
# index all rtypes: scan .rodata + .data.rel.ro-ish sections for 4-aligned candidates whose str nameOff decodes
type_secs = [named[n] for n in ('.rodata', '.typelink', '.noptrdata', '.data') if n in named]
def rtype_name(va):
    off = struct.unpack('<i', rd(va + 24, 4))[0]
    if not (0 < off < ro[3]): return None
    try:
        nm, _ = name_at(base + off)
    except Exception: return None
    tflag = rd(va + 12, 1)[0]
    return nm[1:] if tflag & 2 else nm   # tflagExtraStar
def find_types(target):
    out = []
    for _, addr, off, size in [named['.rodata']]:
        for o in range(0, size - 48, 4):
            va = addr + o
            kind = f[off + o + 15] & 0x1f
            if kind != 25: continue
            try: nm = rtype_name(va)
            except Exception: continue
            if nm == target: out.append(va)
    return out
KINDS = {1:'bool',2:'int',3:'int8',4:'int16',5:'int32',6:'int64',7:'uint',8:'uint8',10:'uint32',13:'float32',14:'float64',17:'array',20:'interface',21:'map',22:'ptr',23:'slice',24:'string',25:'struct'}
for target in ([] if want and want[0] == "--search" else want):
    for va in find_types(target):
        size = u32(va)
        fptr, flen = u32(va + 32 + 4), u32(va + 32 + 8)
        print(f'type {target} @ {va:#x} size={size:#x} fields={flen}')
        for k in range(flen):
            fa = fptr + 12 * k
            npt, tpt, offs = u32(fa), u32(fa + 4), u32(fa + 8)
            nm, tag = name_at(npt)
            tk = rd(tpt + 15, 1)[0] & 0x1f
            tn = rtype_name(tpt) or '?'
            print(f'   +{offs:#05x}  {nm:<22} {KINDS.get(tk, tk):<9} {tn:<28} `{tag}`')

# --- mode: search all typelink types for struct fields whose tag/name matches a regex ---
if want and want[0] == '--search':
    import re as _re
    pat = _re.compile(want[1], _re.I)
    tl = named['.typelink']
    offs = struct.unpack_from(f'<{tl[3]//4}i', f, tl[2])
    def dump(va, label):
        size = u32(va); fptr, flen = u32(va + 36), u32(va + 40)
        print(f'type {label} @ {va:#x} size={size:#x} fields={flen}')
        for k in range(flen):
            fa = fptr + 12 * k
            nm, tag = name_at(u32(fa)); tpt = u32(fa + 4); offs_ = u32(fa + 8)
            tk = rd(tpt + 15, 1)[0] & 0x1f
            print(f'   +{offs_:#05x}  {nm:<24} {KINDS.get(tk, tk):<9} {(rtype_name(tpt) or "?"):<34} `{tag}`')
    seen = set()
    todo = [base + o for o in offs]
    # typelinks only lists some types; also follow ptr elem + struct field types one level
    i = 0
    while i < len(todo) and i < 200000:
        va = todo[i]; i += 1
        if va in seen: continue
        seen.add(va)
        try:
            kind = rd(va + 15, 1)[0] & 0x1f
        except Exception: continue
        if kind == 22: todo.append(u32(va + 32)); continue
        if kind == 23: todo.append(u32(va + 32)); continue
        if kind != 25: continue
        try:
            fptr, flen = u32(va + 36), u32(va + 40)
            if flen > 400: continue
            hit = False
            for k in range(flen):
                fa = fptr + 12 * k
                nm, tag = name_at(u32(fa)); todo.append(u32(fa + 4))
                if pat.search(nm) or pat.search(tag): hit = True
            if hit: dump(va, rtype_name(va) or '?')
        except Exception: continue
