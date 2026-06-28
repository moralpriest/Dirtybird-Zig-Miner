#!/usr/bin/env python3
"""Patch an ELF binary's PT_TLS segment alignment.

Android Bionic requires p_align >= 64 on the PT_TLS segment for ARM64.
musl static-pie binaries default to p_align=8, which Bionic rejects with:
  "executable's TLS segment is underaligned: alignment is 8, needs to be at least 64"

Usage:
    python3 scripts/patch-tls-align.py <binary> [min_align=64]
"""
import struct
import sys

def patch_tls_align(path: str, min_align: int = 64):
    with open(path, 'r+b') as f:
        # ELF64 header layout
        f.seek(32)
        e_phoff = struct.unpack('<Q', f.read(8))[0]
        f.seek(54)
        e_phentsize = struct.unpack('<H', f.read(2))[0]
        e_phnum = struct.unpack('<H', f.read(2))[0]

        for i in range(e_phnum):
            offset = e_phoff + i * e_phentsize
            f.seek(offset)
            p_type = struct.unpack('<I', f.read(4))[0]
            if p_type == 7:  # PT_TLS
                f.seek(offset + 48)
                old_align = struct.unpack('<Q', f.read(8))[0]
                if old_align < min_align:
                    f.seek(offset + 48)
                    f.write(struct.pack('<Q', min_align))
                    print(f"patched PT_TLS p_align: {old_align} -> {min_align}")
                else:
                    print(f"PT_TLS p_align already {old_align} (>= {min_align}), no change")
                return
        print("WARNING: no PT_TLS segment found", file=sys.stderr)
        sys.exit(1)

if __name__ == '__main__':
    if len(sys.argv) < 2:
        print(f"usage: {sys.argv[0]} <binary> [min_align=64]", file=sys.stderr)
        sys.exit(1)
    min_a = int(sys.argv[2]) if len(sys.argv) > 2 else 64
    patch_tls_align(sys.argv[1], min_a)
