//! Multi-buffer SHA-256 using x86 SHA-NI (sha256rnds2 / sha256msg1 / sha256msg2).
//!
//! WHY: A single SHA-256 stream on SHA-NI is *latency*-bound: each `sha256rnds2`
//! depends on the previous one, so one block can't start its next round until the
//! prior round retires. `sha256rnds2` throughput exceeds its latency, so hashing
//! 2 INDEPENDENT messages with their instruction streams interleaved lets the
//! out-of-order engine overlap the dependent chains. The win is capped by the
//! single shared SHA execution port (rnds2/msg1/msg2 all issue there): on
//! Raptor Cove that ceiling is ~1.3x throughput, NOT 2x. (AMD Zen's fatter SHA
//! units reach the textbook ~1.5-1.7x; this CPU cannot.)
//!
//! DESIGN -- the round body is ONE self-contained PURE LEGACY-SSE inline-asm
//! block per function, with the block loop INSIDE the asm. NO Zig `@Vector` value
//! and NO `v`-prefixed (VEX/AVX) or 256-bit instruction appears in the hot loop:
//! state/data/K/mask all enter as pointers in GP registers, every xmm load/store
//! is internal, and only `movdqu/movdqa/pshufd/pshufb/palignr/pblendw/paddd/
//! sha256{rnds2,msg1,msg2}` are used. This is mandatory: the earlier @Vector
//! version let LLVM lower the round through 256-bit/FP-domain ops (vinsertf128 /
//! vshufps), which dirtied the YMM upper EVERY block and made each legacy-SSE
//! `sha256rnds2` pay a ~70-cycle AVX->SSE transition -- a ~47-100x slowdown vs
//! std. The asm is the canonical Intel `sha256_process_x86` sequence; its ABEF/
//! CDGH arrangement equals std's `x={s5,s4,s1,s0}, y={s7,s6,s3,s2}`.
//!
//!   - compress1: single message, one lane.
//!   - compress2: two messages, the same body emitted per lane and interleaved at
//!     round-GROUP granularity (group = 4 rounds). Group (not instruction)
//!     granularity is forced by the shared xmm0 MSG register that `sha256rnds2`
//!     reads implicitly.
//!
//! Output is byte-identical to std.crypto.hash.sha2.Sha256 for each message.
//!
//! Measured (ReleaseFast, -mcpu=native, i7-13700HX, 275354-byte buffer, 1 thread):
//!   std    ~134 us/msg
//!   hash1  ~115 us/msg  (~0.86x of std -- slightly faster than std)
//!   hash2  ~90  us/msg per message  (~0.78x of hash1, ~1.3x throughput)
//!
//! Requires a SHA-NI + AVX2 capable x86_64 host (i7-13700HX / Raptor Lake here).
//! A comptime guard falls back to std on non-capable targets so this file still
//! compiles and runs correctly anywhere (acceleration only on +sha,+avx2).

const std = @import("std");
const builtin = @import("builtin");

/// Initial SHA-256 state (H0..H7), big-endian word order.
const IV = [8]u32{
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
};

/// SHA-256 round constants K[0..63].
///
/// `align(16)` is REQUIRED: the SHA-NI asm adds K via `paddd %xmm, m128` with a
/// memory operand, which #GPs on an unaligned address. Default `[64]u32`
/// alignment is only 4 bytes.
const W align(16) = [64]u32{
    0x428A2F98, 0x71374491, 0xB5C0FBCF, 0xE9B5DBA5, 0x3956C25B, 0x59F111F1, 0x923F82A4, 0xAB1C5ED5,
    0xD807AA98, 0x12835B01, 0x243185BE, 0x550C7DC3, 0x72BE5D74, 0x80DEB1FE, 0x9BDC06A7, 0xC19BF174,
    0xE49B69C1, 0xEFBE4786, 0x0FC19DC6, 0x240CA1CC, 0x2DE92C6F, 0x4A7484AA, 0x5CB0A9DC, 0x76F988DA,
    0x983E5152, 0xA831C66D, 0xB00327C8, 0xBF597FC7, 0xC6E00BF3, 0xD5A79147, 0x06CA6351, 0x14292967,
    0x27B70A85, 0x2E1B2138, 0x4D2C6DFC, 0x53380D13, 0x650A7354, 0x766A0ABB, 0x81C2C92E, 0x92722C85,
    0xA2BFE8A1, 0xA81A664B, 0xC24B8B70, 0xC76C51A3, 0xD192E819, 0xD6990624, 0xF40E3585, 0x106AA070,
    0x19A4C116, 0x1E376C08, 0x2748774C, 0x34B0BCB5, 0x391C0CB3, 0x4ED8AA4A, 0x5B9CCA4F, 0x682E6FF3,
    0x748F82EE, 0x78A5636F, 0x84C87814, 0x8CC70208, 0x90BEFFFA, 0xA4506CEB, 0xBEF9A3F7, 0xC67178F2,
};

/// Byte-swap mask for the SHA-NI `pshufb` big-endian message load. Reverses the
/// 4 bytes of each dword: word i's bytes [0,1,2,3] -> [3,2,1,0]. `align(16)` for
/// the `movdqa`/`pshufb` memory operand. Bytes (low..high):
///   03 02 01 00  07 06 05 04  0b 0a 09 08  0f 0e 0d 0c
const SHUF_MASK align(16) = [16]u8{
    0x03, 0x02, 0x01, 0x00, 0x07, 0x06, 0x05, 0x04,
    0x0b, 0x0a, 0x09, 0x08, 0x0f, 0x0e, 0x0d, 0x0c,
};

/// True when the target CPU can run the SHA-NI fast path.
const have_shani = builtin.cpu.arch == .x86_64 and
    builtin.zig_backend != .stage2_c and
    std.Target.x86.featureSetHasAll(builtin.cpu.features, .{ .sha, .avx2 });

/// One lane's running state: the 8 SHA-256 words, big-endian word order.
pub const State = [8]u32;

/// Compress `nblocks` 64-byte blocks of a SINGLE message into `state`.
///
/// PURE LEGACY-SSE inline asm: the entire per-block round body (state load,
/// 64 rounds, message schedule, store) lives in ONE self-contained asm block
/// using ONLY `movdqu/movdqa/pshufd/pshufb/palignr/pblendw/paddd/sha256*` -- NO
/// `v`-prefixed (VEX/AVX) or 256-bit instructions, and NO Zig `@Vector` value
/// crosses the asm boundary (state/data/K/mask all enter as pointers in GP
/// registers; every xmm load/store is internal). This is the only reliable way
/// to stop LLVM lowering the round through 256-bit/FP-domain ops, which dirty the
/// YMM upper and cost each legacy-SSE `sha256rnds2` a ~70-cycle AVX->SSE
/// transition (the ~47-100x slowdown this file used to suffer).
///
/// This is the canonical Intel `sha256_process_x86` sequence. Its ABEF (STATE0)
/// / CDGH (STATE1) arrangement is identical to std's
/// `x={s5,s4,s1,s0}, y={s7,s6,s3,s2}`, so the digest is byte-exact with std.
///
/// xmm map: xmm0 MSG (sha256rnds2 reads it implicitly), xmm1 STATE0 (ABEF),
///   xmm2 STATE1 (CDGH), xmm3..6 schedule windows MSGTMP0..3, xmm7 byte-swap
///   mask, xmm8/9 saved ABEF/CDGH (per-block add-back), xmm10 scratch.
fn compress1(state: *State, base: [*]const u8, nblocks: usize) void {
    if (nblocks == 0) return;
    var data = base;
    var n = nblocks;
    asm volatile (
        \\ movdqu (%[st]), %%xmm1          # xmm1 = DCBA (state[0..4])
        \\ movdqu 16(%[st]), %%xmm2        # xmm2 = HGFE (state[4..8])
        \\ movdqu (%[mask]), %%xmm7        # byte-swap mask (movdqu: no align req)
        \\ pshufd $0xB1, %%xmm1, %%xmm1    # xmm1 = CDAB
        \\ pshufd $0x1B, %%xmm2, %%xmm2    # xmm2 = EFGH
        \\ movdqa %%xmm1, %%xmm10          # xmm10 = CDAB
        \\ palignr $8, %%xmm2, %%xmm1      # xmm1 = ABEF (STATE0)
        \\ pblendw $0xF0, %%xmm10, %%xmm2  # xmm2 = CDGH (STATE1)
        \\
        \\1:
        \\ # --- save current state for the post-block add-back ---
        \\ movdqa %%xmm1, %%xmm8
        \\ movdqa %%xmm2, %%xmm9
        \\
        \\ # --- rounds 0-3 ---
        \\ movdqu 0(%[data]), %%xmm3
        \\ pshufb %%xmm7, %%xmm3
        \\ movdqa %%xmm3, %%xmm0
        \\ paddd 0(%[k]), %%xmm0
        \\ sha256rnds2 %%xmm1, %%xmm2      # uses xmm0 implicitly
        \\ pshufd $0x0E, %%xmm0, %%xmm0
        \\ sha256rnds2 %%xmm2, %%xmm1
        \\
        \\ # --- rounds 4-7 ---
        \\ movdqu 16(%[data]), %%xmm4
        \\ pshufb %%xmm7, %%xmm4
        \\ movdqa %%xmm4, %%xmm0
        \\ paddd 16(%[k]), %%xmm0
        \\ sha256rnds2 %%xmm1, %%xmm2
        \\ sha256msg1 %%xmm4, %%xmm3
        \\ pshufd $0x0E, %%xmm0, %%xmm0
        \\ sha256rnds2 %%xmm2, %%xmm1
        \\
        \\ # --- rounds 8-11 ---
        \\ movdqu 32(%[data]), %%xmm5
        \\ pshufb %%xmm7, %%xmm5
        \\ movdqa %%xmm5, %%xmm0
        \\ paddd 32(%[k]), %%xmm0
        \\ sha256rnds2 %%xmm1, %%xmm2
        \\ sha256msg1 %%xmm5, %%xmm4
        \\ pshufd $0x0E, %%xmm0, %%xmm0
        \\ sha256rnds2 %%xmm2, %%xmm1
        \\
        \\ # --- rounds 12-15 ---
        \\ movdqu 48(%[data]), %%xmm6
        \\ pshufb %%xmm7, %%xmm6
        \\ movdqa %%xmm6, %%xmm0
        \\ paddd 48(%[k]), %%xmm0
        \\ sha256rnds2 %%xmm1, %%xmm2
        \\ movdqa %%xmm6, %%xmm10
        \\ palignr $4, %%xmm5, %%xmm10
        \\ paddd %%xmm10, %%xmm3
        \\ sha256msg2 %%xmm6, %%xmm3
        \\ sha256msg1 %%xmm6, %%xmm5
        \\ pshufd $0x0E, %%xmm0, %%xmm0
        \\ sha256rnds2 %%xmm2, %%xmm1
        \\
        \\ # --- rounds 16-19 ---
        \\ movdqa %%xmm3, %%xmm0
        \\ paddd 64(%[k]), %%xmm0
        \\ sha256rnds2 %%xmm1, %%xmm2
        \\ movdqa %%xmm3, %%xmm10
        \\ palignr $4, %%xmm6, %%xmm10
        \\ paddd %%xmm10, %%xmm4
        \\ sha256msg2 %%xmm3, %%xmm4
        \\ sha256msg1 %%xmm3, %%xmm6
        \\ pshufd $0x0E, %%xmm0, %%xmm0
        \\ sha256rnds2 %%xmm2, %%xmm1
        \\
        \\ # --- rounds 20-23 ---
        \\ movdqa %%xmm4, %%xmm0
        \\ paddd 80(%[k]), %%xmm0
        \\ sha256rnds2 %%xmm1, %%xmm2
        \\ movdqa %%xmm4, %%xmm10
        \\ palignr $4, %%xmm3, %%xmm10
        \\ paddd %%xmm10, %%xmm5
        \\ sha256msg2 %%xmm4, %%xmm5
        \\ sha256msg1 %%xmm4, %%xmm3
        \\ pshufd $0x0E, %%xmm0, %%xmm0
        \\ sha256rnds2 %%xmm2, %%xmm1
        \\
        \\ # --- rounds 24-27 ---
        \\ movdqa %%xmm5, %%xmm0
        \\ paddd 96(%[k]), %%xmm0
        \\ sha256rnds2 %%xmm1, %%xmm2
        \\ movdqa %%xmm5, %%xmm10
        \\ palignr $4, %%xmm4, %%xmm10
        \\ paddd %%xmm10, %%xmm6
        \\ sha256msg2 %%xmm5, %%xmm6
        \\ sha256msg1 %%xmm5, %%xmm4
        \\ pshufd $0x0E, %%xmm0, %%xmm0
        \\ sha256rnds2 %%xmm2, %%xmm1
        \\
        \\ # --- rounds 28-31 ---
        \\ movdqa %%xmm6, %%xmm0
        \\ paddd 112(%[k]), %%xmm0
        \\ sha256rnds2 %%xmm1, %%xmm2
        \\ movdqa %%xmm6, %%xmm10
        \\ palignr $4, %%xmm5, %%xmm10
        \\ paddd %%xmm10, %%xmm3
        \\ sha256msg2 %%xmm6, %%xmm3
        \\ sha256msg1 %%xmm6, %%xmm5
        \\ pshufd $0x0E, %%xmm0, %%xmm0
        \\ sha256rnds2 %%xmm2, %%xmm1
        \\
        \\ # --- rounds 32-35 ---
        \\ movdqa %%xmm3, %%xmm0
        \\ paddd 128(%[k]), %%xmm0
        \\ sha256rnds2 %%xmm1, %%xmm2
        \\ movdqa %%xmm3, %%xmm10
        \\ palignr $4, %%xmm6, %%xmm10
        \\ paddd %%xmm10, %%xmm4
        \\ sha256msg2 %%xmm3, %%xmm4
        \\ sha256msg1 %%xmm3, %%xmm6
        \\ pshufd $0x0E, %%xmm0, %%xmm0
        \\ sha256rnds2 %%xmm2, %%xmm1
        \\
        \\ # --- rounds 36-39 ---
        \\ movdqa %%xmm4, %%xmm0
        \\ paddd 144(%[k]), %%xmm0
        \\ sha256rnds2 %%xmm1, %%xmm2
        \\ movdqa %%xmm4, %%xmm10
        \\ palignr $4, %%xmm3, %%xmm10
        \\ paddd %%xmm10, %%xmm5
        \\ sha256msg2 %%xmm4, %%xmm5
        \\ sha256msg1 %%xmm4, %%xmm3
        \\ pshufd $0x0E, %%xmm0, %%xmm0
        \\ sha256rnds2 %%xmm2, %%xmm1
        \\
        \\ # --- rounds 40-43 ---
        \\ movdqa %%xmm5, %%xmm0
        \\ paddd 160(%[k]), %%xmm0
        \\ sha256rnds2 %%xmm1, %%xmm2
        \\ movdqa %%xmm5, %%xmm10
        \\ palignr $4, %%xmm4, %%xmm10
        \\ paddd %%xmm10, %%xmm6
        \\ sha256msg2 %%xmm5, %%xmm6
        \\ sha256msg1 %%xmm5, %%xmm4
        \\ pshufd $0x0E, %%xmm0, %%xmm0
        \\ sha256rnds2 %%xmm2, %%xmm1
        \\
        \\ # --- rounds 44-47 ---
        \\ movdqa %%xmm6, %%xmm0
        \\ paddd 176(%[k]), %%xmm0
        \\ sha256rnds2 %%xmm1, %%xmm2
        \\ movdqa %%xmm6, %%xmm10
        \\ palignr $4, %%xmm5, %%xmm10
        \\ paddd %%xmm10, %%xmm3
        \\ sha256msg2 %%xmm6, %%xmm3
        \\ sha256msg1 %%xmm6, %%xmm5
        \\ pshufd $0x0E, %%xmm0, %%xmm0
        \\ sha256rnds2 %%xmm2, %%xmm1
        \\
        \\ # --- rounds 48-51 ---
        \\ movdqa %%xmm3, %%xmm0
        \\ paddd 192(%[k]), %%xmm0
        \\ sha256rnds2 %%xmm1, %%xmm2
        \\ movdqa %%xmm3, %%xmm10
        \\ palignr $4, %%xmm6, %%xmm10
        \\ paddd %%xmm10, %%xmm4
        \\ sha256msg2 %%xmm3, %%xmm4
        \\ sha256msg1 %%xmm3, %%xmm6
        \\ pshufd $0x0E, %%xmm0, %%xmm0
        \\ sha256rnds2 %%xmm2, %%xmm1
        \\
        \\ # --- rounds 52-55 ---
        \\ movdqa %%xmm4, %%xmm0
        \\ paddd 208(%[k]), %%xmm0
        \\ sha256rnds2 %%xmm1, %%xmm2
        \\ movdqa %%xmm4, %%xmm10
        \\ palignr $4, %%xmm3, %%xmm10
        \\ paddd %%xmm10, %%xmm5
        \\ sha256msg2 %%xmm4, %%xmm5
        \\ pshufd $0x0E, %%xmm0, %%xmm0
        \\ sha256rnds2 %%xmm2, %%xmm1
        \\
        \\ # --- rounds 56-59 ---
        \\ movdqa %%xmm5, %%xmm0
        \\ paddd 224(%[k]), %%xmm0
        \\ sha256rnds2 %%xmm1, %%xmm2
        \\ movdqa %%xmm5, %%xmm10
        \\ palignr $4, %%xmm4, %%xmm10
        \\ paddd %%xmm10, %%xmm6
        \\ sha256msg2 %%xmm5, %%xmm6
        \\ pshufd $0x0E, %%xmm0, %%xmm0
        \\ sha256rnds2 %%xmm2, %%xmm1
        \\
        \\ # --- rounds 60-63 ---
        \\ movdqa %%xmm6, %%xmm0
        \\ paddd 240(%[k]), %%xmm0
        \\ sha256rnds2 %%xmm1, %%xmm2
        \\ pshufd $0x0E, %%xmm0, %%xmm0
        \\ sha256rnds2 %%xmm2, %%xmm1
        \\
        \\ # --- add this block's result back into the running state ---
        \\ paddd %%xmm8, %%xmm1
        \\ paddd %%xmm9, %%xmm2
        \\
        \\ addq $64, %[data]
        \\ subq $1, %[n]
        \\ jne 1b
        \\
        \\ # --- store: ABEF/CDGH -> DCBA/HGFE -> memory ---
        \\ pshufd $0x1B, %%xmm1, %%xmm1    # FEBA
        \\ pshufd $0xB1, %%xmm2, %%xmm2    # DCHG
        \\ movdqa %%xmm1, %%xmm10          # FEBA
        \\ pblendw $0xF0, %%xmm2, %%xmm1   # DCBA
        \\ palignr $8, %%xmm10, %%xmm2     # HGFE
        \\ movdqu %%xmm1, (%[st])
        \\ movdqu %%xmm2, 16(%[st])
        : [data] "+r" (data),
          [n] "+r" (n),
        : [st] "r" (state),
          [k] "r" (&W),
          [mask] "r" (&SHUF_MASK),
        : .{ .xmm0 = true, .xmm1 = true, .xmm2 = true, .xmm3 = true, .xmm4 = true, .xmm5 = true, .xmm6 = true, .xmm7 = true, .xmm8 = true, .xmm9 = true, .xmm10 = true, .memory = true, .cc = true }
    );
}

/// 2-way: compress `nblocks` blocks of TWO independent messages, interleaving the
/// two SHA-NI chains so the OoO engine overlaps their dependent `sha256rnds2`
/// latency. Measured ~1.3x throughput vs single-stream on Raptor Cove -- capped
/// by the single shared SHA execution port, not the rnds2 latency this hides.
///
/// Same PURE LEGACY-SSE strategy as `compress1`, emitted twice (one body per lane)
/// and interleaved at round-GROUP granularity: lane A's whole 4-round group, then
/// lane B's whole group, then the next group. Group granularity (not instruction)
/// is forced by the SHARED xmm0 MSG register -- a lane holds its MSG in xmm0
/// across both of its rnds2 plus the pshufd between them, so a lane's group is
/// indivisible. Emitting the two lanes' groups adjacently keeps their independent
/// rnds2 latency chains within the OoO reorder window, which is what lets the
/// engine overlap them.
///
/// xmm map (exactly 16):
///   shared:  xmm0 MSG, xmm13 byte-swap mask
///   lane A:  xmm1 STATE0, xmm2 STATE1, xmm5..8 MSG0..3, xmm14 TMP
///   lane B:  xmm3 STATE0, xmm4 STATE1, xmm9..12 MSG0..3, xmm15 TMP
/// The 4 per-block state saves (ABEF/CDGH x2 lanes) spill to a 16-byte-aligned
/// stack buffer (`save`), added back via `paddd N(%[sv]), %%xmm` (memory operand,
/// aligned -> no #GP). K stays in memory (`paddd N(%[k]), %%xmm`).
fn compress2(st0: *State, st1: *State, base0: [*]const u8, base1: [*]const u8, nblocks: usize) void {
    if (nblocks == 0) return;
    var data0 = base0;
    var data1 = base1;
    var n = nblocks;
    var save: [16]u32 align(16) = undefined;
    asm volatile (
        \\ movdqu (%[mask]), %%xmm13       # shared byte-swap mask
        \\ # lane A state -> ABEF(xmm1)/CDGH(xmm2)
        \\ movdqu (%[st0]), %%xmm1
        \\ movdqu 16(%[st0]), %%xmm2
        \\ pshufd $0xB1, %%xmm1, %%xmm1
        \\ pshufd $0x1B, %%xmm2, %%xmm2
        \\ movdqa %%xmm1, %%xmm14
        \\ palignr $8, %%xmm2, %%xmm1
        \\ pblendw $0xF0, %%xmm14, %%xmm2
        \\ # lane B state -> ABEF(xmm3)/CDGH(xmm4)
        \\ movdqu (%[st1]), %%xmm3
        \\ movdqu 16(%[st1]), %%xmm4
        \\ pshufd $0xB1, %%xmm3, %%xmm3
        \\ pshufd $0x1B, %%xmm4, %%xmm4
        \\ movdqa %%xmm3, %%xmm15
        \\ palignr $8, %%xmm4, %%xmm3
        \\ pblendw $0xF0, %%xmm15, %%xmm4
        \\
        \\1:
        \\ # save both lanes' state for the post-block add-back
        \\ movdqa %%xmm1, 0(%[sv])
        \\ movdqa %%xmm2, 16(%[sv])
        \\ movdqa %%xmm3, 32(%[sv])
        \\ movdqa %%xmm4, 48(%[sv])
        \\
        \\ ###### group 0  (rounds 0-3) ######
        \\ # lane A
        \\ movdqu 0(%[data0]), %%xmm5
        \\ pshufb %%xmm13, %%xmm5
        \\ movdqa %%xmm5, %%xmm0
        \\ paddd 0(%[k]), %%xmm0
        \\ sha256rnds2 %%xmm1, %%xmm2
        \\ pshufd $0x0E, %%xmm0, %%xmm0
        \\ sha256rnds2 %%xmm2, %%xmm1
        \\ # lane B
        \\ movdqu 0(%[data1]), %%xmm9
        \\ pshufb %%xmm13, %%xmm9
        \\ movdqa %%xmm9, %%xmm0
        \\ paddd 0(%[k]), %%xmm0
        \\ sha256rnds2 %%xmm3, %%xmm4
        \\ pshufd $0x0E, %%xmm0, %%xmm0
        \\ sha256rnds2 %%xmm4, %%xmm3
        \\
        \\ ###### group 1  (rounds 4-7) ######
        \\ # lane A
        \\ movdqu 16(%[data0]), %%xmm6
        \\ pshufb %%xmm13, %%xmm6
        \\ movdqa %%xmm6, %%xmm0
        \\ paddd 16(%[k]), %%xmm0
        \\ sha256rnds2 %%xmm1, %%xmm2
        \\ sha256msg1 %%xmm6, %%xmm5
        \\ pshufd $0x0E, %%xmm0, %%xmm0
        \\ sha256rnds2 %%xmm2, %%xmm1
        \\ # lane B
        \\ movdqu 16(%[data1]), %%xmm10
        \\ pshufb %%xmm13, %%xmm10
        \\ movdqa %%xmm10, %%xmm0
        \\ paddd 16(%[k]), %%xmm0
        \\ sha256rnds2 %%xmm3, %%xmm4
        \\ sha256msg1 %%xmm10, %%xmm9
        \\ pshufd $0x0E, %%xmm0, %%xmm0
        \\ sha256rnds2 %%xmm4, %%xmm3
        \\
        \\ ###### group 2  (rounds 8-11) ######
        \\ # lane A
        \\ movdqu 32(%[data0]), %%xmm7
        \\ pshufb %%xmm13, %%xmm7
        \\ movdqa %%xmm7, %%xmm0
        \\ paddd 32(%[k]), %%xmm0
        \\ sha256rnds2 %%xmm1, %%xmm2
        \\ sha256msg1 %%xmm7, %%xmm6
        \\ pshufd $0x0E, %%xmm0, %%xmm0
        \\ sha256rnds2 %%xmm2, %%xmm1
        \\ # lane B
        \\ movdqu 32(%[data1]), %%xmm11
        \\ pshufb %%xmm13, %%xmm11
        \\ movdqa %%xmm11, %%xmm0
        \\ paddd 32(%[k]), %%xmm0
        \\ sha256rnds2 %%xmm3, %%xmm4
        \\ sha256msg1 %%xmm11, %%xmm10
        \\ pshufd $0x0E, %%xmm0, %%xmm0
        \\ sha256rnds2 %%xmm4, %%xmm3
        \\
        \\ ###### group 3  (rounds 12-15) ######
        \\ # lane A
        \\ movdqu 48(%[data0]), %%xmm8
        \\ pshufb %%xmm13, %%xmm8
        \\ movdqa %%xmm8, %%xmm0
        \\ paddd 48(%[k]), %%xmm0
        \\ sha256rnds2 %%xmm1, %%xmm2
        \\ movdqa %%xmm8, %%xmm14
        \\ palignr $4, %%xmm7, %%xmm14
        \\ paddd %%xmm14, %%xmm5
        \\ sha256msg2 %%xmm8, %%xmm5
        \\ sha256msg1 %%xmm8, %%xmm7
        \\ pshufd $0x0E, %%xmm0, %%xmm0
        \\ sha256rnds2 %%xmm2, %%xmm1
        \\ # lane B
        \\ movdqu 48(%[data1]), %%xmm12
        \\ pshufb %%xmm13, %%xmm12
        \\ movdqa %%xmm12, %%xmm0
        \\ paddd 48(%[k]), %%xmm0
        \\ sha256rnds2 %%xmm3, %%xmm4
        \\ movdqa %%xmm12, %%xmm15
        \\ palignr $4, %%xmm11, %%xmm15
        \\ paddd %%xmm15, %%xmm9
        \\ sha256msg2 %%xmm12, %%xmm9
        \\ sha256msg1 %%xmm12, %%xmm11
        \\ pshufd $0x0E, %%xmm0, %%xmm0
        \\ sha256rnds2 %%xmm4, %%xmm3
        \\
        \\ ###### group 4  (rounds 16-19) ######
        \\ # lane A : MSG0=xmm5 MSG1=xmm6 MSG2=xmm7 MSG3=xmm8
        \\ movdqa %%xmm5, %%xmm0
        \\ paddd 64(%[k]), %%xmm0
        \\ sha256rnds2 %%xmm1, %%xmm2
        \\ movdqa %%xmm5, %%xmm14
        \\ palignr $4, %%xmm8, %%xmm14
        \\ paddd %%xmm14, %%xmm6
        \\ sha256msg2 %%xmm5, %%xmm6
        \\ sha256msg1 %%xmm5, %%xmm8
        \\ pshufd $0x0E, %%xmm0, %%xmm0
        \\ sha256rnds2 %%xmm2, %%xmm1
        \\ # lane B
        \\ movdqa %%xmm9, %%xmm0
        \\ paddd 64(%[k]), %%xmm0
        \\ sha256rnds2 %%xmm3, %%xmm4
        \\ movdqa %%xmm9, %%xmm15
        \\ palignr $4, %%xmm12, %%xmm15
        \\ paddd %%xmm15, %%xmm10
        \\ sha256msg2 %%xmm9, %%xmm10
        \\ sha256msg1 %%xmm9, %%xmm12
        \\ pshufd $0x0E, %%xmm0, %%xmm0
        \\ sha256rnds2 %%xmm4, %%xmm3
        \\
        \\ ###### group 5  (rounds 20-23) ######
        \\ # lane A : MSG0=xmm6 MSG1=xmm7 MSG2=xmm8 MSG3=xmm5
        \\ movdqa %%xmm6, %%xmm0
        \\ paddd 80(%[k]), %%xmm0
        \\ sha256rnds2 %%xmm1, %%xmm2
        \\ movdqa %%xmm6, %%xmm14
        \\ palignr $4, %%xmm5, %%xmm14
        \\ paddd %%xmm14, %%xmm7
        \\ sha256msg2 %%xmm6, %%xmm7
        \\ sha256msg1 %%xmm6, %%xmm5
        \\ pshufd $0x0E, %%xmm0, %%xmm0
        \\ sha256rnds2 %%xmm2, %%xmm1
        \\ # lane B
        \\ movdqa %%xmm10, %%xmm0
        \\ paddd 80(%[k]), %%xmm0
        \\ sha256rnds2 %%xmm3, %%xmm4
        \\ movdqa %%xmm10, %%xmm15
        \\ palignr $4, %%xmm9, %%xmm15
        \\ paddd %%xmm15, %%xmm11
        \\ sha256msg2 %%xmm10, %%xmm11
        \\ sha256msg1 %%xmm10, %%xmm9
        \\ pshufd $0x0E, %%xmm0, %%xmm0
        \\ sha256rnds2 %%xmm4, %%xmm3
        \\
        \\ ###### group 6  (rounds 24-27) ######
        \\ # lane A : MSG0=xmm7 MSG1=xmm8 MSG2=xmm5 MSG3=xmm6
        \\ movdqa %%xmm7, %%xmm0
        \\ paddd 96(%[k]), %%xmm0
        \\ sha256rnds2 %%xmm1, %%xmm2
        \\ movdqa %%xmm7, %%xmm14
        \\ palignr $4, %%xmm6, %%xmm14
        \\ paddd %%xmm14, %%xmm8
        \\ sha256msg2 %%xmm7, %%xmm8
        \\ sha256msg1 %%xmm7, %%xmm6
        \\ pshufd $0x0E, %%xmm0, %%xmm0
        \\ sha256rnds2 %%xmm2, %%xmm1
        \\ # lane B
        \\ movdqa %%xmm11, %%xmm0
        \\ paddd 96(%[k]), %%xmm0
        \\ sha256rnds2 %%xmm3, %%xmm4
        \\ movdqa %%xmm11, %%xmm15
        \\ palignr $4, %%xmm10, %%xmm15
        \\ paddd %%xmm15, %%xmm12
        \\ sha256msg2 %%xmm11, %%xmm12
        \\ sha256msg1 %%xmm11, %%xmm10
        \\ pshufd $0x0E, %%xmm0, %%xmm0
        \\ sha256rnds2 %%xmm4, %%xmm3
        \\
        \\ ###### group 7  (rounds 28-31) ######
        \\ # lane A : MSG0=xmm8 MSG1=xmm5 MSG2=xmm6 MSG3=xmm7
        \\ movdqa %%xmm8, %%xmm0
        \\ paddd 112(%[k]), %%xmm0
        \\ sha256rnds2 %%xmm1, %%xmm2
        \\ movdqa %%xmm8, %%xmm14
        \\ palignr $4, %%xmm7, %%xmm14
        \\ paddd %%xmm14, %%xmm5
        \\ sha256msg2 %%xmm8, %%xmm5
        \\ sha256msg1 %%xmm8, %%xmm7
        \\ pshufd $0x0E, %%xmm0, %%xmm0
        \\ sha256rnds2 %%xmm2, %%xmm1
        \\ # lane B
        \\ movdqa %%xmm12, %%xmm0
        \\ paddd 112(%[k]), %%xmm0
        \\ sha256rnds2 %%xmm3, %%xmm4
        \\ movdqa %%xmm12, %%xmm15
        \\ palignr $4, %%xmm11, %%xmm15
        \\ paddd %%xmm15, %%xmm9
        \\ sha256msg2 %%xmm12, %%xmm9
        \\ sha256msg1 %%xmm12, %%xmm11
        \\ pshufd $0x0E, %%xmm0, %%xmm0
        \\ sha256rnds2 %%xmm4, %%xmm3
        \\
        \\ ###### group 8  (rounds 32-35) ######
        \\ # lane A : MSG0=xmm5 MSG1=xmm6 MSG2=xmm7 MSG3=xmm8
        \\ movdqa %%xmm5, %%xmm0
        \\ paddd 128(%[k]), %%xmm0
        \\ sha256rnds2 %%xmm1, %%xmm2
        \\ movdqa %%xmm5, %%xmm14
        \\ palignr $4, %%xmm8, %%xmm14
        \\ paddd %%xmm14, %%xmm6
        \\ sha256msg2 %%xmm5, %%xmm6
        \\ sha256msg1 %%xmm5, %%xmm8
        \\ pshufd $0x0E, %%xmm0, %%xmm0
        \\ sha256rnds2 %%xmm2, %%xmm1
        \\ # lane B
        \\ movdqa %%xmm9, %%xmm0
        \\ paddd 128(%[k]), %%xmm0
        \\ sha256rnds2 %%xmm3, %%xmm4
        \\ movdqa %%xmm9, %%xmm15
        \\ palignr $4, %%xmm12, %%xmm15
        \\ paddd %%xmm15, %%xmm10
        \\ sha256msg2 %%xmm9, %%xmm10
        \\ sha256msg1 %%xmm9, %%xmm12
        \\ pshufd $0x0E, %%xmm0, %%xmm0
        \\ sha256rnds2 %%xmm4, %%xmm3
        \\
        \\ ###### group 9  (rounds 36-39) ######
        \\ # lane A : MSG0=xmm6 MSG1=xmm7 MSG2=xmm8 MSG3=xmm5
        \\ movdqa %%xmm6, %%xmm0
        \\ paddd 144(%[k]), %%xmm0
        \\ sha256rnds2 %%xmm1, %%xmm2
        \\ movdqa %%xmm6, %%xmm14
        \\ palignr $4, %%xmm5, %%xmm14
        \\ paddd %%xmm14, %%xmm7
        \\ sha256msg2 %%xmm6, %%xmm7
        \\ sha256msg1 %%xmm6, %%xmm5
        \\ pshufd $0x0E, %%xmm0, %%xmm0
        \\ sha256rnds2 %%xmm2, %%xmm1
        \\ # lane B
        \\ movdqa %%xmm10, %%xmm0
        \\ paddd 144(%[k]), %%xmm0
        \\ sha256rnds2 %%xmm3, %%xmm4
        \\ movdqa %%xmm10, %%xmm15
        \\ palignr $4, %%xmm9, %%xmm15
        \\ paddd %%xmm15, %%xmm11
        \\ sha256msg2 %%xmm10, %%xmm11
        \\ sha256msg1 %%xmm10, %%xmm9
        \\ pshufd $0x0E, %%xmm0, %%xmm0
        \\ sha256rnds2 %%xmm4, %%xmm3
        \\
        \\ ###### group 10 (rounds 40-43) ######
        \\ # lane A : MSG0=xmm7 MSG1=xmm8 MSG2=xmm5 MSG3=xmm6
        \\ movdqa %%xmm7, %%xmm0
        \\ paddd 160(%[k]), %%xmm0
        \\ sha256rnds2 %%xmm1, %%xmm2
        \\ movdqa %%xmm7, %%xmm14
        \\ palignr $4, %%xmm6, %%xmm14
        \\ paddd %%xmm14, %%xmm8
        \\ sha256msg2 %%xmm7, %%xmm8
        \\ sha256msg1 %%xmm7, %%xmm6
        \\ pshufd $0x0E, %%xmm0, %%xmm0
        \\ sha256rnds2 %%xmm2, %%xmm1
        \\ # lane B
        \\ movdqa %%xmm11, %%xmm0
        \\ paddd 160(%[k]), %%xmm0
        \\ sha256rnds2 %%xmm3, %%xmm4
        \\ movdqa %%xmm11, %%xmm15
        \\ palignr $4, %%xmm10, %%xmm15
        \\ paddd %%xmm15, %%xmm12
        \\ sha256msg2 %%xmm11, %%xmm12
        \\ sha256msg1 %%xmm11, %%xmm10
        \\ pshufd $0x0E, %%xmm0, %%xmm0
        \\ sha256rnds2 %%xmm4, %%xmm3
        \\
        \\ ###### group 11 (rounds 44-47) ######
        \\ # lane A : MSG0=xmm8 MSG1=xmm5 MSG2=xmm6 MSG3=xmm7
        \\ movdqa %%xmm8, %%xmm0
        \\ paddd 176(%[k]), %%xmm0
        \\ sha256rnds2 %%xmm1, %%xmm2
        \\ movdqa %%xmm8, %%xmm14
        \\ palignr $4, %%xmm7, %%xmm14
        \\ paddd %%xmm14, %%xmm5
        \\ sha256msg2 %%xmm8, %%xmm5
        \\ sha256msg1 %%xmm8, %%xmm7
        \\ pshufd $0x0E, %%xmm0, %%xmm0
        \\ sha256rnds2 %%xmm2, %%xmm1
        \\ # lane B
        \\ movdqa %%xmm12, %%xmm0
        \\ paddd 176(%[k]), %%xmm0
        \\ sha256rnds2 %%xmm3, %%xmm4
        \\ movdqa %%xmm12, %%xmm15
        \\ palignr $4, %%xmm11, %%xmm15
        \\ paddd %%xmm15, %%xmm9
        \\ sha256msg2 %%xmm12, %%xmm9
        \\ sha256msg1 %%xmm12, %%xmm11
        \\ pshufd $0x0E, %%xmm0, %%xmm0
        \\ sha256rnds2 %%xmm4, %%xmm3
        \\
        \\ ###### group 12 (rounds 48-51) ######
        \\ # lane A : MSG0=xmm5 MSG1=xmm6 MSG2=xmm7 MSG3=xmm8
        \\ movdqa %%xmm5, %%xmm0
        \\ paddd 192(%[k]), %%xmm0
        \\ sha256rnds2 %%xmm1, %%xmm2
        \\ movdqa %%xmm5, %%xmm14
        \\ palignr $4, %%xmm8, %%xmm14
        \\ paddd %%xmm14, %%xmm6
        \\ sha256msg2 %%xmm5, %%xmm6
        \\ sha256msg1 %%xmm5, %%xmm8
        \\ pshufd $0x0E, %%xmm0, %%xmm0
        \\ sha256rnds2 %%xmm2, %%xmm1
        \\ # lane B
        \\ movdqa %%xmm9, %%xmm0
        \\ paddd 192(%[k]), %%xmm0
        \\ sha256rnds2 %%xmm3, %%xmm4
        \\ movdqa %%xmm9, %%xmm15
        \\ palignr $4, %%xmm12, %%xmm15
        \\ paddd %%xmm15, %%xmm10
        \\ sha256msg2 %%xmm9, %%xmm10
        \\ sha256msg1 %%xmm9, %%xmm12
        \\ pshufd $0x0E, %%xmm0, %%xmm0
        \\ sha256rnds2 %%xmm4, %%xmm3
        \\
        \\ ###### group 13 (rounds 52-55) ######
        \\ # lane A : MSG0=xmm6 MSG1=xmm7 MSG2=xmm8 MSG3=xmm5
        \\ movdqa %%xmm6, %%xmm0
        \\ paddd 208(%[k]), %%xmm0
        \\ sha256rnds2 %%xmm1, %%xmm2
        \\ movdqa %%xmm6, %%xmm14
        \\ palignr $4, %%xmm5, %%xmm14
        \\ paddd %%xmm14, %%xmm7
        \\ sha256msg2 %%xmm6, %%xmm7
        \\ pshufd $0x0E, %%xmm0, %%xmm0
        \\ sha256rnds2 %%xmm2, %%xmm1
        \\ # lane B
        \\ movdqa %%xmm10, %%xmm0
        \\ paddd 208(%[k]), %%xmm0
        \\ sha256rnds2 %%xmm3, %%xmm4
        \\ movdqa %%xmm10, %%xmm15
        \\ palignr $4, %%xmm9, %%xmm15
        \\ paddd %%xmm15, %%xmm11
        \\ sha256msg2 %%xmm10, %%xmm11
        \\ pshufd $0x0E, %%xmm0, %%xmm0
        \\ sha256rnds2 %%xmm4, %%xmm3
        \\
        \\ ###### group 14 (rounds 56-59) ######
        \\ # lane A : MSG0=xmm7 MSG1=xmm8 MSG2=xmm5 MSG3=xmm6
        \\ movdqa %%xmm7, %%xmm0
        \\ paddd 224(%[k]), %%xmm0
        \\ sha256rnds2 %%xmm1, %%xmm2
        \\ movdqa %%xmm7, %%xmm14
        \\ palignr $4, %%xmm6, %%xmm14
        \\ paddd %%xmm14, %%xmm8
        \\ sha256msg2 %%xmm7, %%xmm8
        \\ pshufd $0x0E, %%xmm0, %%xmm0
        \\ sha256rnds2 %%xmm2, %%xmm1
        \\ # lane B
        \\ movdqa %%xmm11, %%xmm0
        \\ paddd 224(%[k]), %%xmm0
        \\ sha256rnds2 %%xmm3, %%xmm4
        \\ movdqa %%xmm11, %%xmm15
        \\ palignr $4, %%xmm10, %%xmm15
        \\ paddd %%xmm15, %%xmm12
        \\ sha256msg2 %%xmm11, %%xmm12
        \\ pshufd $0x0E, %%xmm0, %%xmm0
        \\ sha256rnds2 %%xmm4, %%xmm3
        \\
        \\ ###### group 15 (rounds 60-63) ######
        \\ # lane A
        \\ movdqa %%xmm8, %%xmm0
        \\ paddd 240(%[k]), %%xmm0
        \\ sha256rnds2 %%xmm1, %%xmm2
        \\ pshufd $0x0E, %%xmm0, %%xmm0
        \\ sha256rnds2 %%xmm2, %%xmm1
        \\ # lane B
        \\ movdqa %%xmm12, %%xmm0
        \\ paddd 240(%[k]), %%xmm0
        \\ sha256rnds2 %%xmm3, %%xmm4
        \\ pshufd $0x0E, %%xmm0, %%xmm0
        \\ sha256rnds2 %%xmm4, %%xmm3
        \\
        \\ # add this block's result back into both running states
        \\ paddd 0(%[sv]), %%xmm1
        \\ paddd 16(%[sv]), %%xmm2
        \\ paddd 32(%[sv]), %%xmm3
        \\ paddd 48(%[sv]), %%xmm4
        \\
        \\ addq $64, %[data0]
        \\ addq $64, %[data1]
        \\ subq $1, %[n]
        \\ jne 1b
        \\
        \\ # store lane A: ABEF/CDGH -> DCBA/HGFE
        \\ pshufd $0x1B, %%xmm1, %%xmm1
        \\ pshufd $0xB1, %%xmm2, %%xmm2
        \\ movdqa %%xmm1, %%xmm14
        \\ pblendw $0xF0, %%xmm2, %%xmm1
        \\ palignr $8, %%xmm14, %%xmm2
        \\ movdqu %%xmm1, (%[st0])
        \\ movdqu %%xmm2, 16(%[st0])
        \\ # store lane B
        \\ pshufd $0x1B, %%xmm3, %%xmm3
        \\ pshufd $0xB1, %%xmm4, %%xmm4
        \\ movdqa %%xmm3, %%xmm15
        \\ pblendw $0xF0, %%xmm4, %%xmm3
        \\ palignr $8, %%xmm15, %%xmm4
        \\ movdqu %%xmm3, (%[st1])
        \\ movdqu %%xmm4, 16(%[st1])
        : [data0] "+r" (data0),
          [data1] "+r" (data1),
          [n] "+r" (n),
        : [st0] "r" (st0),
          [st1] "r" (st1),
          [k] "r" (&W),
          [mask] "r" (&SHUF_MASK),
          [sv] "r" (&save),
        : .{ .xmm0 = true, .xmm1 = true, .xmm2 = true, .xmm3 = true, .xmm4 = true, .xmm5 = true, .xmm6 = true, .xmm7 = true, .xmm8 = true, .xmm9 = true, .xmm10 = true, .xmm11 = true, .xmm12 = true, .xmm13 = true, .xmm14 = true, .xmm15 = true, .memory = true, .cc = true }
    );
}

/// Write a State (big-endian words) out as a 32-byte digest.
inline fn writeDigest(st: State, out: *[32]u8) void {
    inline for (0..8) |i| {
        std.mem.writeInt(u32, out[i * 4 ..][0..4], st[i], .big);
    }
}

/// Build the 1 or 2 padding blocks for a message of `total_len` bytes whose
/// final `rem` bytes (rem in 0..63) live at `tail`. Returns the padding bytes in
/// `pad` and the number of 64-byte blocks written (1 or 2). The caller has
/// already compressed all *whole* 64-byte blocks; `rem = total_len % 64`.
fn buildPadding(tail: []const u8, total_len: u64, pad: *[128]u8) usize {
    const rem = tail.len; // 0..63
    std.debug.assert(rem < 64);
    @memset(pad, 0);
    @memcpy(pad[0..rem], tail);
    pad[rem] = 0x80;
    // If fewer than 9 bytes remain after the 0x80, we need a second block for
    // the 64-bit length.
    const nblocks: usize = if (64 - rem < 9) 2 else 1;
    const bit_len: u64 = total_len *% 8;
    // Big-endian 64-bit length in the last 8 bytes of the final block.
    const len_off = nblocks * 64 - 8;
    std.mem.writeInt(u64, pad[len_off..][0..8], bit_len, .big);
    return nblocks;
}

/// Finish a single message: compress its trailing whole blocks (single-stream)
/// then the padding blocks. `state` already reflects `done_blocks` whole blocks.
inline fn finishOne(state: *State, msg: []const u8, done_blocks: usize) void {
    // Remaining whole blocks beyond what the multi-buffer pass consumed.
    const total_whole = msg.len / 64;
    if (total_whole > done_blocks) {
        compress1(state, msg.ptr + done_blocks * 64, total_whole - done_blocks);
    }
    // Padding.
    const rem = msg.len % 64;
    const tail = msg[total_whole * 64 ..][0..rem];
    var pad: [128]u8 = undefined;
    const npad = buildPadding(tail, msg.len, &pad);
    compress1(state, &pad, npad);
}

/// Scalar fallback (non-SHA-NI hosts): plain std SHA-256.
fn hashStd(in: []const u8, out: *[32]u8) void {
    std.crypto.hash.sha2.Sha256.hash(in, out, .{});
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Single-stream SHA-256 via this file's SHA-NI core (used to validate the
/// round before interleaving; also a correct general-purpose hash).
pub fn hash1(in: []const u8, out: *[32]u8) void {
    if (!have_shani) return hashStd(in, out);
    var st: State = IV;
    const whole = in.len / 64;
    if (whole > 0) compress1(&st, in.ptr, whole);
    finishOne(&st, in, whole);
    writeDigest(st, out);
}

/// 2-way multi-buffer SHA-256. Computes the standard SHA-256 of `in0` and `in1`
/// independently; output is byte-identical to std for each. Messages may have
/// different lengths: the common min number of whole 64-byte blocks is processed
/// 2-way interleaved, then each message is finished single-stream (remaining
/// whole blocks + padding).
pub fn hash2(in0: []const u8, in1: []const u8, out0: *[32]u8, out1: *[32]u8) void {
    if (!have_shani) {
        hashStd(in0, out0);
        hashStd(in1, out1);
        return;
    }
    var st0: State = IV;
    var st1: State = IV;
    const common = @min(in0.len / 64, in1.len / 64);

    if (common > 0) {
        compress2(&st0, &st1, in0.ptr, in1.ptr, common);
    }

    // Finish each message from where the 2-way pass left off.
    finishOne(&st0, in0, common);
    finishOne(&st1, in1, common);

    writeDigest(st0, out0);
    writeDigest(st1, out1);
}

/// 4-way multi-buffer SHA-256. Same semantics as hash2 but across 4 messages.
pub fn hash4(ins: [4][]const u8, outs: *[4][32]u8) void {
    // A true 4-way interleave needs >16 xmm (4 lanes x {2 state + 4 windows} plus
    // the shared MSG/mask) and would spill; and the SHA port -- not rnds2 latency
    // -- already bounds 2-way, so more lanes give nothing. Two independent 2-way
    // passes are simplest and stay byte-exact.
    hash2(ins[0], ins[1], &outs[0], &outs[1]);
    hash2(ins[2], ins[3], &outs[2], &outs[3]);
}

// ---------------------------------------------------------------------------
// Tests  (gate: zig test src\sha256_mb.zig -OReleaseFast -mcpu=native
//               zig test src\sha256_mb.zig -OReleaseSafe -mcpu=native)
// ---------------------------------------------------------------------------

const testing = std.testing;

fn refHash(in: []const u8, out: *[32]u8) void {
    std.crypto.hash.sha2.Sha256.hash(in, out, .{});
}

test "hash1 KAT abc / a / empty" {
    var out: [32]u8 = undefined;

    hash1("abc", &out);
    try testing.expectEqualSlices(u8, &[_]u8{
        0xba, 0x78, 0x16, 0xbf, 0x8f, 0x01, 0xcf, 0xea,
        0x41, 0x41, 0x40, 0xde, 0x5d, 0xae, 0x22, 0x23,
        0xb0, 0x03, 0x61, 0xa3, 0x96, 0x17, 0x7a, 0x9c,
        0xb4, 0x10, 0xff, 0x61, 0xf2, 0x00, 0x15, 0xad,
    }, &out);

    hash1("a", &out);
    try testing.expectEqualSlices(u8, &[_]u8{
        0xca, 0x97, 0x81, 0x12, 0xca, 0x1b, 0xbd, 0xca,
        0xfa, 0xc2, 0x31, 0xb3, 0x9a, 0x23, 0xdc, 0x4d,
        0xa7, 0x86, 0xef, 0xf8, 0x14, 0x7c, 0x4e, 0x72,
        0xb9, 0x80, 0x77, 0x85, 0xaf, 0xee, 0x48, 0xbb,
    }, &out);

    hash1("", &out);
    try testing.expectEqualSlices(u8, &[_]u8{
        0xe3, 0xb0, 0xc4, 0x42, 0x98, 0xfc, 0x1c, 0x14,
        0x9a, 0xfb, 0xf4, 0xc8, 0x99, 0x6f, 0xb9, 0x24,
        0x27, 0xae, 0x41, 0xe4, 0x64, 0x9b, 0x93, 0x4c,
        0xa4, 0x95, 0x99, 0x1b, 0x78, 0x52, 0xb8, 0x55,
    }, &out);
}

const boundary_sizes = [_]usize{ 0, 1, 2, 3, 55, 56, 57, 63, 64, 65, 119, 120, 127, 128, 129, 1000, 4096, 4097, 274000, 275354 };

fn fillPattern(buf: []u8, seed: u64) void {
    var s = seed;
    for (buf) |*b| {
        // xorshift64
        s ^= s << 13;
        s ^= s >> 7;
        s ^= s << 17;
        b.* = @truncate(s);
    }
}

test "hash1 parity vs std over boundary sizes" {
    if (!have_shani) return error.SkipZigTest;
    const max = 275354;
    const buf = try testing.allocator.alloc(u8, max);
    defer testing.allocator.free(buf);
    fillPattern(buf, 0x1234_5678_9abc_def0);

    for (boundary_sizes) |sz| {
        var expected: [32]u8 = undefined;
        var got: [32]u8 = undefined;
        refHash(buf[0..sz], &expected);
        hash1(buf[0..sz], &got);
        try testing.expectEqualSlices(u8, &expected, &got);
    }
}

test "hash2 parity vs std over boundary size pairs" {
    if (!have_shani) return error.SkipZigTest;
    const max = 275354;
    const a = try testing.allocator.alloc(u8, max);
    defer testing.allocator.free(a);
    const b = try testing.allocator.alloc(u8, max);
    defer testing.allocator.free(b);
    fillPattern(a, 0xdead_beef_cafe_babe);
    fillPattern(b, 0x0123_4567_89ab_cdef);

    for (boundary_sizes) |sz0| {
        for (boundary_sizes) |sz1| {
            var e0: [32]u8 = undefined;
            var e1: [32]u8 = undefined;
            var g0: [32]u8 = undefined;
            var g1: [32]u8 = undefined;
            refHash(a[0..sz0], &e0);
            refHash(b[0..sz1], &e1);
            hash2(a[0..sz0], b[0..sz1], &g0, &g1);
            try testing.expectEqualSlices(u8, &e0, &g0);
            try testing.expectEqualSlices(u8, &e1, &g1);
        }
    }
}

test "hash4 parity vs std over boundary size quads" {
    if (!have_shani) return error.SkipZigTest;
    const max = 275354;
    var bufs: [4][]u8 = undefined;
    inline for (0..4) |i| {
        bufs[i] = try testing.allocator.alloc(u8, max);
        fillPattern(bufs[i], 0x1111_1111_1111_1111 *% (@as(u64, i) + 1) +% 7);
    }
    defer inline for (0..4) |i| testing.allocator.free(bufs[i]);

    // Exhaustive over all pairs would be 20^4; instead sweep one dimension at a
    // time plus a few mixed quads.
    for (boundary_sizes) |sz| {
        const ins: [4][]const u8 = .{
            bufs[0][0..sz],
            bufs[1][0 .. (sz + 64) % (max + 1)],
            bufs[2][0 .. (sz + 1000) % (max + 1)],
            bufs[3][0 .. (sz *% 3) % (max + 1)],
        };
        var outs: [4][32]u8 = undefined;
        hash4(ins, &outs);
        inline for (0..4) |i| {
            var e: [32]u8 = undefined;
            refHash(ins[i], &e);
            try testing.expectEqualSlices(u8, &e, &outs[i]);
        }
    }
}

test "hash2 / hash4 random fuzz" {
    if (!have_shani) return error.SkipZigTest;
    var prng = std.Random.DefaultPrng.init(0xA5A5_1234_9999_0001);
    const rnd = prng.random();
    const max = 4500;
    const buf = try testing.allocator.alloc(u8, max);
    defer testing.allocator.free(buf);

    var iter: usize = 0;
    while (iter < 3000) : (iter += 1) {
        rnd.bytes(buf);
        const l0 = rnd.uintLessThan(usize, max + 1);
        const l1 = rnd.uintLessThan(usize, max + 1);
        const l2 = rnd.uintLessThan(usize, max + 1);
        const l3 = rnd.uintLessThan(usize, max + 1);

        // hash2 uses two disjoint-ish slices of the same buffer at different
        // offsets to vary content.
        const off = rnd.uintLessThan(usize, 64);
        const a = buf[0..l0];
        const b = if (off + l1 <= max) buf[off..][0..l1] else buf[0..l1];

        var e0: [32]u8 = undefined;
        var e1: [32]u8 = undefined;
        var g0: [32]u8 = undefined;
        var g1: [32]u8 = undefined;
        refHash(a, &e0);
        refHash(b, &e1);
        hash2(a, b, &g0, &g1);
        try testing.expectEqualSlices(u8, &e0, &g0);
        try testing.expectEqualSlices(u8, &e1, &g1);

        const ins: [4][]const u8 = .{ buf[0..l0], buf[0..l1], buf[0..l2], buf[0..l3] };
        var outs: [4][32]u8 = undefined;
        hash4(ins, &outs);
        inline for (0..4, .{ l0, l1, l2, l3 }) |i, li| {
            var e: [32]u8 = undefined;
            refHash(buf[0..li], &e);
            try testing.expectEqualSlices(u8, &e, &outs[i]);
        }
    }
}
