# Perf baseline — 2026-06-20 (Ryzen AI MAX+ PRO 395, linux 7.0.12, zig 0.16.0)

## Host

- `uname -m`: x86_64
- `cat /proc/cpuinfo | grep "model name"`: AMD Ryzen AI MAX+ PRO 395 w/ Radeon 8060S
- `nproc`: 32
- `/proc/cpuinfo flags`: sse4_2, avx2, avx512f, avx512dq, sha_ni, bmi2, aes
- `lscpu | grep "CPU(s) on-line"`: 32 logical / 16 cores / 2 SMT threads/core (Zen 5 chiplet, 16 P-cores)

## Variants

| Tag | Build flags | Source |
|---|---|---|
| **v1** | `-Doptimize=ReleaseFast` (default) | shipped `_pgo/merged.profdata` (48 KB, generic) |
| **v2** | `-Doptimize=ReleaseFast -Dcpu=native` | same shipped profile (note: `native` printed `cpu=znver5`) |

## Results (30-second median per variant × thread count, linux bench, no Windows affinity)

### v1 — `-Doptimize=ReleaseFast` (default cpu=x86_64_v3 + sha, shipped PGO)

| threads | KH/s/thread | KH/s total | scaling |
|--------:|------------:|-----------:|--------:|
| 1  | 1.730 | 1.73  | 100% |
| 8  | 1.438 | 11.50 | 83% |
| 16 | 1.155 | 18.48 | 67% |
| 32 | 0.759 | 24.27 | 44% |

### v2 — `-Dcpu=native` (znver5 with AVX-512)

| threads | KH/s/thread | KH/s total | vs v1 |
|--------:|------------:|-----------:|------:|
| 1  | 1.645 | 1.64 | -5% |
| 8  | 1.392 | 11.14 | -3% |
| 16 | 1.109 | 17.75 | -4% |
| 32 | 0.724 | 23.16 | -5% |

## Conclusion

- **Default `x86_64_v3 + sha` wins on this CPU.** The comment at `build.zig:54` ("the legacy-SSE SHA path that beats native") is empirically confirmed for Zen 5 — even with AVX-512 enabled via `-Dcpu=native`, the SHA-NI instructions interleaved with VMOVQ+SHA256RNDS2 lose 5% per thread.
- **Scaling is poor with default 32 threads:** 32t = 0.759 KH/s/thread (44% of single-thread peak). `recommendedAffinityForThreads(32)` returns 8 distinct P-core physicals + HT-siblings-of-the-same-8-cores because the static order array in `src/system.zig:291` was authored against an i7-13700HX (8 P + 8 E). On this Zen 5 host (16 P + 0 E) that maps wrong: the second batch of "E-cores" is actually HT siblings of the first 8 physicals, so threads 8-15 hit the same L1/L2 as threads 0-7.

Next step per `docs/superpowers/plans/2026-06-20-bench-tune-tls-adapter.md` Stage 2: rewrite `src/system.zig:291 recommendedAffinityForThreads` with a `/sys` topology probe that handles both topologies, plus add a test that catches this Zen-5 regression.

## PGO retrain — abandoned in this session

The script `scripts/build-pgo.sh` was thrown by the Zig 0.16 port: `build.zig:29` panics on absolute paths to `addObjectFile` ("sub_path is expected to be relative to the build root"). A small `cwd_relative` fix at `build.zig:29-32` gets the instrumented build through. After that, the LLVM profile-rt emits warnings about value-profiler counter exhaustion and the bench run drops to 0.033 KH/s/thread (34× slowdown from instrumented overhead). The `default.profraw` file was *not* written under either `_pgo/` (relative to binary's cwd) or `LLVM_PROFILE_FILE=...` absolute path. The instrumented build is functional but its profile data isn't being flushed, and a proper retrain would need a stronger `LLVM_PROFILE_FILE` env + the profile-rt with `-fprofile-counter-atomic` and/or higher `-vp-counters-per-site`. Out of scope for this baseline run.
