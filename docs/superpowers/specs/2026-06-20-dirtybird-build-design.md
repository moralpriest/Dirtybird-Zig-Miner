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
- Tooling NOT on PATH: `zig` — `build.sh:17-19` hard-aborts
- Sudo assumed available (system-wide install was user-requested)

## Decisions

1. **Compile from source on this system.** (Rejected alternatives:
   install a prebuilt release archive; PGO retrain for THIS CPU; write
   a new miner from scratch.)
2. **Use the shipped `_pgo/merged.profdata`** so `build.zig` auto-applies
   `-Dpgo=use` + LTO. (Rejected: re-collect local profile ~20–60s extra;
   skip PGO for ~10–15% hashrate loss.)
3. **Pin Zig 0.14.1 system-wide at `/opt/zig-0.14.1` +
   `/usr/local/bin/zig -> /opt/zig-0.14.1/zig`.** Versioning note:
   `src/net.zig:1062` is a Zig 0.14.1 WebSocket client; using any other
   version risks a silent ABI/runtime mismatch.
4. **Call `zig build` directly, NOT `./build.sh`.** `build.sh:23`
   hard-codes `-Dcpu=native`, which would override the
   `cpu_arch=x86_64, cpu_model=x86_64_v3, cpu_features_add=sha` default
   chosen in `build.zig:56-61` for hash-rate reasons (build.zig comment:
   "legacy-SSE SHA path that beats native").
5. **Verify with `--selftest`** (no daemon required). Per
   `scripts/build-pgo.sh:114-117`, selftest failure is treated as a
   hard abort during PGO collection — same gate is appropriate here.
6. **Leave artifact at `zig-out/bin/zig-miner`.** No install-to-PATH,
   no reproduction of the v0.1.3 release-tarball convention.

## Sequence

### Phase 1 — Install Zig 0.14.1

```sh
# Fetch tarball + verify sha256 (filled live from ziglang.org SHA256SUMS)
curl -fL -o /tmp/zig-0.14.1.tar.xz \
  https://ziglang.org/download/0.14.1/zig-linux-x86_64-0.14.1.tar.xz
echo "<sha256>  /tmp/zig-0.14.1.tar.xz" | sha256sum -c -

sudo mkdir -p /opt/zig-0.14.1
sudo tar -xJf /tmp/zig-0.14.1.tar.xz -C /opt/zig-0.14.1 --strip-components=1
sudo ln -sfn /opt/zig-0.14.1/zig /usr/local/bin/zig

zig version      # expect: 0.14.1
```

**Failure handling**

- Network/HTTP error → print, do not retry automatically; surface to user.
- sha256 mismatch of the tarball → abort, do not extract.
- `zig version` ≠ `0.14.1` after symlink → check `$PATH` ordering;
  `which -a zig` should show `/usr/local/bin/zig` first.

### Phase 2 — Build

```sh
cd /home/priest/Projects/Dirtybird-Zig-Miner
zig build -Doptimize=ReleaseFast
```

**Expected console output (from `build.zig:78`)**

```
build: optimize=ReleaseFast cpu=x86_64_v3 pgo=use
```

- `optimize=ReleaseFast` — explicit
- `cpu=x86_64_v3` — from default_target (not native, per decision 4)
- `pgo=use` — auto-resolved because `_pgo/merged.profdata` exists +
  `target.result.cpu.arch == .x86_64` (`build.zig:70-77`). LTO applied
  via `-flto` on the SA objects (`build.zig:35`).

**Artifact**: `zig-out/bin/zig-miner` — single ELF, links libstdc++ +
libc++ for the SA objects.

**Failure handling**

- Non-Zig 0.14.1 toolchain (would emit a parse error on `std.comptime_only`
  etc.) — abort and ask user to repair `which zig`.
- `pgo=off` instead of `use` would mean `_pgo/merged.profdata` went
  missing between Phase 1 and here — re-check; don't proceed if so.

### Phase 3 — Verify

```sh
./zig-out/bin/zig-miner --selftest
```

- Exits 0 → pass (KAT matches).
- Exits non-zero → STOP. Do not print the run command. Surface the
  failure; do not proceed to Phase 4.

### Phase 4 — Hand off

Print:

1. `/home/priest/Projects/Dirtybird-Zig-Miner/zig-out/bin/zig-miner`
2. `file zig-out/bin/zig-miner` and `ls -la` for size/mtime confirmation.
3. The example run-line from `build.sh:42` with `zig-out/bin/zig-miner`
   substituted in:

```
/home/priest/Projects/Dirtybird-Zig-Miner/zig-out/bin/zig-miner \
  -d pool.example:10100 -w dero1q...your_wallet... -t 20
```

(Note: 20 threads ≈ 60% of the 32-core host — leaves room for
network/dashboards; user should adjust to taste.)

## Out of scope

- Fresh PGO collection (scripts/build-pgo.sh) — user explicitly chose
  not to (decision 2). Possible v0.1.4 follow-up.
- Building for additional targets (arm64, win64, macOS).
- Wiring up `-Dpgo=use` to a system-wide release-tarball workflow.
- Touching any host network/daemon configuration.

## Risks

- **Tarball download** — single network leg; mitigated by sha256 + curl `-f`.
  Probability of failure: low (Zig CDN is stable).
- **`which zig` ordering** — if a stale `zig` from another toolchain sits
  earlier in `$PATH`, Phase 2 breaks. Mitigation: explicitly call
  `/usr/local/bin/zig` after install + sanity-check `zig version`.

## Verification

- `zig version` prints `0.14.1`.
- Build prints `pgo=use`.
- `--selftest` exits 0.
- `zig-out/bin/zig-miner` exists and has non-zero size.
