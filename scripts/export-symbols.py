#!/usr/bin/env python3
"""Make hidden ("private external") symbols with a given prefix exported in a static archive.

The prebuilt shaderc_combined archive is compiled with -fvisibility=hidden, so a dylib built
from it can't export the shaderc C API. This clears the N_PEXT bit on matching symbols in every
Mach-O member, in a copy of the archive. Nothing else in the archive changes.

usage: export-symbols.py <in.a> <out.a> <symbol prefix>...
"""
import struct
import sys

N_EXT, N_PEXT = 0x01, 0x10
MH_MAGIC_64, LC_SYMTAB = 0xFEEDFACF, 0x2


def patch_object(data: bytearray, start: int, prefixes: list[bytes]) -> int:
    if struct.unpack_from("<I", data, start)[0] != MH_MAGIC_64:
        return 0
    ncmds = struct.unpack_from("<I", data, start + 16)[0]
    offset, changed = start + 32, 0
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", data, offset)
        if cmd == LC_SYMTAB:
            symoff, nsyms, stroff, _ = struct.unpack_from("<IIII", data, offset + 8)
            for i in range(nsyms):
                entry = start + symoff + i * 16
                strx = struct.unpack_from("<I", data, entry)[0]
                ntype = data[entry + 4]
                if not (ntype & N_EXT and ntype & N_PEXT):
                    continue
                name_start = start + stroff + strx
                name = bytes(data[name_start:data.index(0, name_start)])
                if any(name.startswith(p) for p in prefixes):
                    data[entry + 4] = ntype & ~N_PEXT
                    changed += 1
        offset += size
    return changed


def main() -> None:
    source, dest, *prefixes = sys.argv[1:]
    prefixes = [p.encode() for p in prefixes]
    data = bytearray(open(source, "rb").read())
    assert data[:8] == b"!<arch>\n", "not an ar archive"
    offset, changed = 8, 0
    while offset + 60 <= len(data):
        name = data[offset:offset + 16].decode().strip()
        size = int(data[offset + 48:offset + 58].decode().strip())
        body = offset + 60
        name_len = int(name[3:]) if name.startswith("#1/") else 0
        changed += patch_object(data, body + name_len, prefixes)
        offset = body + size + (size % 2)
    open(dest, "wb").write(data)
    print(f"exported {changed} symbols")


if __name__ == "__main__":
    main()
