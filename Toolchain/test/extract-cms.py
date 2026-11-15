#!/usr/bin/env python3
"""Prints the code signature SuperBlob of a thin Mach-O, writes its CMS blob (slot 0x10000) to a file
and the CodeDirectory (slot 0) to cd.bin next to it."""
import struct
import sys

path, out = sys.argv[1], sys.argv[2]
data = open(path, "rb").read()
ncmds = struct.unpack_from("<I", data, 16)[0]
offset = 32
dataoff = None
for _ in range(ncmds):
    cmd, size = struct.unpack_from("<II", data, offset)
    if cmd == 0x1D:
        dataoff, datasize = struct.unpack_from("<II", data, offset + 8)
    offset += size
magic, length, count = struct.unpack_from(">III", data, dataoff)
print(f"SuperBlob magic={magic:#x} length={length} count={count}")
for index in range(count):
    slot, blob_offset = struct.unpack_from(">II", data, dataoff + 12 + 8 * index)
    blob_magic, blob_length = struct.unpack_from(">II", data, dataoff + blob_offset)
    print(f"  slot {slot:#x} at {blob_offset}: magic={blob_magic:#x} length={blob_length}")
    if slot == 0:
        import os
        cd = data[dataoff + blob_offset : dataoff + blob_offset + blob_length]
        open(os.path.join(os.path.dirname(out), "cd.bin"), "wb").write(cd)
    if slot == 0x10000:
        cms = data[dataoff + blob_offset + 8 : dataoff + blob_offset + blob_length]
        open(out, "wb").write(cms)
        print(f"  wrote {len(cms)} bytes of CMS to {out}")
