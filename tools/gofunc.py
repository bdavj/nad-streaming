#!/usr/bin/env python3
"""List Go functions (name, entry, end) from .gopclntab of a stripped 32-bit ELF (Go 1.20+ layout).
usage: gofunc.py <elf> <regex>"""
import sys, struct, re
path, pat = sys.argv[1], re.compile(sys.argv[2])
d = open(path, 'rb').read()
# ELF32 section headers
shoff, = struct.unpack_from('<I', d, 0x20); shentsize, shnum, shstrndx = struct.unpack_from('<HHH', d, 0x2e)
secs = [struct.unpack_from('<IIIIIIIIII', d, shoff + i * shentsize) for i in range(shnum)]
strtab = secs[shstrndx]
def sname(s): o = strtab[4] + s[0]; return d[o:d.index(b'\0', o)].decode()
pcl = next(s for s in secs if sname(s) == '.gopclntab'); base = pcl[4]
magic, = struct.unpack_from('<I', d, base)
assert magic in (0xfffffff1, 0xfffffff0), hex(magic)
ptr = d[base + 7]
nfunc, nfiles, textStart, funcnameOff, cuOff, filetabOff, pctabOff, pclnOff = struct.unpack_from('<8I', d, base + 8)
ftab = base + pclnOff
for i in range(nfunc):
    entryoff, funcoff = struct.unpack_from('<II', d, ftab + i * 8)
    nextentry, = struct.unpack_from('<I', d, ftab + (i + 1) * 8)
    fo = ftab + funcoff
    nameoff, = struct.unpack_from('<i', d, fo + 4)
    no = base + funcnameOff + nameoff
    name = d[no:d.index(b'\0', no)].decode('utf-8', 'replace')
    if pat.search(name):
        print(f'{textStart + entryoff:#x} {textStart + nextentry:#x} {name}')
