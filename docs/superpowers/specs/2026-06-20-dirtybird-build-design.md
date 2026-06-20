# 2026-06-20 — Compile Dirtybird-Zig-Miner on this host

## Context

User request: "Can you build this miner for my system?"
Project: Dirtybird-Zig-Miner — AstroBWTv3 CPU miner for DERO.
Repo state: clean working tree on `main`, last tag v0.1.3, last commit
`7c903e3 fix(console): build the POSIX local-time path without std.c.tm`.
Build helpers present: `build.sh`, `scripts/build-pgo.sh`, `build.bat`,
`start.bat`. PGO profile shipped: `_pgo/merged.profdata` (PGO+LTO
auto-applies on x86_64 hosts unless overridden).

### Host inventory (verified via `uname -a`, `/proc/cpuinfo`, `which`)

- Kernel/arch: Linux 7.0.12 x86_64 (CachyOS)
- CPU: AMD RYZEN AI MAX+ PRO 395 w/ Radeon 8060S (Zen 5, 32 cores)
- SIMD present: SSE4_2, AVX2, AVX-512 (F + DQ), SHA-NI, BMI2, AES
- Tooling on PATH: `gcc`, `clang`, `llvm-profdata` (all `/usr/bin/`)
- Tooling NOT on PATH at start: `zig` — `build.sh:17-19` hard-aborts

## Decisions

1. **Compile from source on this system** (originally: install Zig 0.14.1 to
   `/opt/zig-0.14.1` via SHA-verified tarball). Blocked because sudo needs a
   password this host.
2. **Use the shipped `_pgo/merged.profdata`** so `build.zig` auto-applies
   `-Dpgo=use` + LTO.
3. **Zig 0.14.1 system-wide at `/opt/zig-0.14.1`** was the original target;
   pivoted to Zig 0.16.0 from CachyOS pacman (see Deviation below).
4. **Call `zig build` directly, NOT `./build.sh`** — `build.sh:23` hard-codes
   `-Dcpu=native`, which would override the
   `cpu_arch=x86_64, cpu_model=x86_64_v3, cpu_features_add=sha` default
   chosen in `build.zig:56-61` for hash-rate reasons (build.zig comment:
   "legacy-SSE SHA path that beats native").
5. **Verify with `--selftest`** (no daemon required).
6. **Leave artifact at `zig-out/bin/zig-miner`**.

## Deviation from plan (post-execution)

The system-wide Zig 0.14.1 install (Decision 3) was unachievable because sudo
on this host requires a password for every invocation, and the user did not
want to be interrupted. Instead:

- `pacman -S zig` installed Zig 0.16.0 (CachyOS `cachyos-extra-znver4/zig
  0.16.0-1.1`) system-wide. The series continues
  `zig → clang21 + lld21 + compiler-rt21`.
- The user authorized porting the source against the new std.api rather than
  abandoning.

The Pivot, the per-file edits, and the residual `src/net.zig` tls.Client
work are documented in the companion
`docs/superpowers/specs/2026-06-20-zig-016-port-postmortem.md` (created during
execution; capturing the full deviation).

## Verification

- `zig version` prints `0.16.0` (deviated from the 0.14.1 originally planned;
  pinned by the CachyOS package).
- For `src/*.zig` covered by the port: build prints
  `pgo=use cpu=x86_64_v3`.
- `--selftest` KAT runs (covered by the port).
- Pool connection (covered by `src/net.zig`) is NOT restored this session —
  see the postmortem doc for the residual `tls.Client` adapter work.
