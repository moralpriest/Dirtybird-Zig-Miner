#!/usr/bin/env python3
"""Patch an ELF binary's PT_TLS segment for Android Bionic ARM64.

Bionic requires:
  1. p_align >= 64
  2. p_vaddr % p_align == 0  (skew must be 0)

musl static-pie binaries default to p_align=8 with arbitrary p_vaddr,
which Bionic rejects. This script fixes both p_align and p_vaddr in one pass.

Usage:
    python3 scripts/patch-tls-align.py <binary> [min_align=64]
"""
import struct
import sys

def patch_tls(path: str, min_align: int = 64):
    with open(path, 'r+b') as f:
        # ELF64 header: e_phoff at byte 32, e_phentsize at 54, e_phnum at 56
        f.seek(32)
        e_phoff = struct.unpack('<Q', f.read(8))[0]
        f.seek(54)
        e_phentsize = struct.unpack('<H', f.read(2))[0]
        e_phnum = struct.unpack('<H', f.read(2))[0]

        for i in range(e_phnum):
            off = e_phoff + i * e_phentsize
            f.seek(off)
            p_type = struct.unpack('<I', f.read(4))[0]
            if p_type != 7:  # not PT_TLS
                continue

            # Read current values
            f.seek(off + 16)
            p_vaddr = struct.unpack('<Q', f.read(8))[0]
            f.seek(off + 24)
            p_paddr = struct.unpack('<Q', f.read(8))[0]
            f.seek(off + 40)
            p_memsz = struct.unpack('<Q', f.read(8))[0]
            f.seek(off + 48)
            p_align = struct.unpack('<Q', f.read(8))[0]

            print(f"PT_TLS: p_vaddr=0x{p_vaddr:x} p_memsz=0x{p_memsz:x} p_align={p_align}")

            # 1. Fix p_align if too small
            if p_align < min_align:
                f.seek(off + 48)
                f.write(struct.pack('<Q', min_align))
                p_align = min_align
                print(f"  p_align: -> {min_align}")

            # 2. Fix p_vaddr skew (p_vaddr must be aligned to p_align)
            skew = p_vaddr % p_align
            if skew != 0:
                new_vaddr = p_vaddr - skew
                new_memsz = p_memsz + skew
                f.seek(off + 16)
                f.write(struct.pack('<Q', new_vaddr))
                f.seek(off + 24)
                f.write(struct.pack('<Q', new_vaddr))  # p_paddr = p_vaddr
                f.seek(off + 40)
                f.write(struct.pack('<Q', new_memsz))
                print(f"  p_vaddr: 0x{p_vaddr:x} -> 0x{new_vaddr:x} (skew {skew} -> 0)")
                print(f"  p_memsz: 0x{p_memsz:x} -> 0x{new_memsz:x}")
            else:
                print(f"  p_vaddr already aligned (skew=0)")

            # Verify
            f.seek(off + 16)
            v = struct.unpack('<Q', f.read(8))[0]
            f.seek(off + 48)
            a = struct.unpack('<Q', f.read(8))[0]
            final_skew = v % a
            print(f"  VERIFIED: p_vaddr=0x{v:x} p_align={a} skew={final_skew}")
            return

        print("WARNING: no PT_TLS segment found", file=sys.stderr)
        sys.exit(1)

if __name__ == '__main__':
    if len(sys.argv) < 2:
        print(f"usage: {sys.argv[0]} <binary> [min_align=64]", file=sys.stderr)
        sys.exit(1)
    min_a = int(sys.argv[2]) if len(sys.argv) > 2 else 64
    patch_tls(sys.argv[1], min_a)
