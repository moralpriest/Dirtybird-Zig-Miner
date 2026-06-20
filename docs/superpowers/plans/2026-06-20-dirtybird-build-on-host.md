# Dirtybird-Zig-Miner host build — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce a working `./zig-out/bin/zig-miner` on this AMD Ryzen AI MAX+ PRO 395 host by installing Zig 0.14.1 system-wide, building with the shipped PGO profile, and verifying the hash via `--selftest`.

**Architecture:** Four phases (install toolchain → build → verify → hand off). The verification gate at every step keeps mistakes cheap: each phase ends with a real command output that must match an explicit expectation. There is no custom code to write and no pytest-style unit tests; the miner's own `--selftest` IS the KAT test for the whole hash pipeline.

**Tech Stack:** Zig 0.14.1 (`zig build`), CachyOS Linux 7.0.12, AMD Zen 5 (`x86_64_v3 + sha_ni` per `build.zig:57-61`), `llvm-profdata` (already installed), `curl` + `sha256sum` for tarball authentication.

**Spec:** `docs/superpowers/specs/2026-06-20-dirtybird-build-design.md`

---

## File Structure

This plan only creates **three filesystem artifacts**:

| Path | Owner | Purpose |
|------|-------|---------|
| `/opt/zig-0.14.1/` | root | Installed Zig 0.14.1 toolchain |
| `/usr/local/bin/zig` | root | Versioned symlink to the binary above |
| `$REPO/zig-out/bin/zig-miner` | user | The compiled miner (binary lives in `.gitignore`-d `zig-out/`) |

Plus transient files in `/tmp/` that are deleted at the end of Task 4.

No source files in `src/`, `build.zig`, `_pgo/`, etc. are touched.

---

## Tasks

### Task 1: Pre-flight environment check

**Files:** none (read-only sanity probes)

- [ ] **Step 1.1: Confirm arch is x86_64 and CPU has the SIMD features the build target assumes**

Run:
```sh
uname -m
grep -m1 -oE 'sha_ni|avx2|avx512f|bmi2' /proc/cpuinfo | sort -u
```

Expected output:
```
x86_64
avx2
avx512f
bmi2
sha_ni
```

If `uname -m` ≠ `x86_64` → STOP (this plan is Linux amd64 only).
If `sha_ni` missing → STOP (build.zig's `cpu_features_add=.sha` cannot be honored).

- [ ] **Step 1.2: Confirm Zig is NOT installed (or is the wrong version)**

Run:
```sh
command -v zig 2>/dev/null && zig version 2>/dev/null || echo "zig: not found"
```

Expected output:
```
zig: not found
```

If a non-`0.14.1` Zig is found → surface to user; the plan assumes the `/opt/zig-0.14.1` install will become the `/usr/local/bin/zig` link, which will take precedence. Don't pre-emptively uninstall the existing Zig — note its path for the user.

- [ ] **Step 1.3: Confirm `clang` + `llvm-profdata` are present**

Run:
```sh
command -v clang && command -v llvm-profdata || command -v llvm-profdata-18 || command -v llvm-profdata-19
```

Expected: at least one `llvm-profdata` binary printed.
If `clang` missing → STOP (vendor/v114 C/C++ objects won't compile).
If no `llvm-profdata` → STOP (this plan doesn't run `-Dpgo=gen`, but having `llvm-profdata` lets the user re-collect a profile later).

- [ ] **Step 1.4: Confirm the shipped PGO profile is in place**

Run:
```sh
ls -la /home/priest/Projects/Dirtybird-Zig-Miner/_pgo/merged.profdata
```

Expected: file present, ≥100 B (actually 48 KB).
If missing → STOP (this plan deliberately uses the shipped profile; rebuilding it is out of scope).

- [ ] **Step 1.5: Print pre-flight summary**

Print a one-line summary:
```
preflight: arch=x86_64  cpu=sha_ni+avx2+avx512f+bmi2  clang=ok  profdata=ok  pgo_profile=present(v0.1.3)  zig=absent
```

No commit. Proceed to Task 2.

---

### Task 2: Fetch Zig 0.14.1 tarball and verify SHA256

**Files:**
- Create (transient): `/tmp/zig-0.14.1.tar.xz`, `/tmp/zig-shasums.txt`, `/tmp/zig-expected.sha256`

- [ ] **Step 2.1: Fetch the unsigned SHA256 manifest from ziglang.org**

Run:
```sh
curl -fsSL -o /tmp/zig-shasums.txt https://ziglang.org/download/0.14.1/SHA256SUMS
ls -la /tmp/zig-shasums.txt
awk '/zig-linux-x86_64-0.14.1.tar.xz/ {print $1}' /tmp/zig-shasums.txt
```

Expected: manifest file exists, and the awk line prints a 64-hex-char SHA256.

- [ ] **Step 2.2: Fetch the tarball itself**

Run:
```sh
curl -fL -o /tmp/zig-0.14.1.tar.xz https://ziglang.org/download/0.14.1/zig-linux-x86_64-0.14.1.tar.xz
ls -la /tmp/zig-0.14.1.tar.xz
```

Expected: file present, ~50 MB class.
If `curl` prints an HTTP error: STOP, surface the URL + error message.

- [ ] **Step 2.3: Verify the tarball's SHA256 against the manifest**

Run:
```sh
cd /tmp && awk '/zig-linux-x86_64-0.14.1.tar.xz/ {print $1"  zig-0.14.1.tar.xz"}' zig-shasums.txt | sha256sum -c -
```

Expected output (must contain `OK`):
```
zig-0.14.1.tar.xz: OK
```

**Failure path** (do NOT proceed):
```sh
rm -f /tmp/zig-0.14.1.tar.xz /tmp/zig-shasums.txt /tmp/zig-expected.sha256
echo "ABORT: tarball hash mismatch — see sha256sum output above"
```
STOP and report to user.

No commit. Proceed to Task 3.

---

### Task 3: Install Zig 0.14.1 to /opt + symlink /usr/local/bin/zig

**Files:**
- Create: `/opt/zig-0.14.1/` (root-owned, toolchain tree)
- Create: `/usr/local/bin/zig` (root-owned symlink → `/opt/zig-0.14.1/zig`)

- [ ] **Step 3.1: Extract into /opt/zig-0.14.1**

Run:
```sh
sudo mkdir -p /opt/zig-0.14.1
sudo tar -xJf /tmp/zig-0.14.1.tar.xz -C /opt/zig-0.14.1 --strip-components=1
ls /opt/zig-0.14.1/zig /opt/zig-0.14.1/lib | head
```

Expected: `/opt/zig-0.14.1/zig` exists; `lib/` directory listing begins with std/ etc.

- [ ] **Step 3.2: Symlink into /usr/local/bin**

Run:
```sh
sudo ln -sfn /opt/zig-0.14.1/zig /usr/local/bin/zig
ls -la /usr/local/bin/zig
```

Expected: `... /usr/local/bin/zig -> /opt/zig-0.14.1/zig`

- [ ] **Step 3.3: Verify the new toolchain is now on PATH and reports 0.14.1**

Run:
```sh
command -v zig
zig version
hash -r 2>/dev/null || true   # fish-only cache invalidation; harmless if missing
```

Expected output:
```
/usr/local/bin/zig
0.14.1
```

**Failure path** — wrong version reported:
```sh
which -a zig
```
If `/usr/local/bin/zig` is not first in the list, the user's shell hasn't seen the new symlink. Fix:
- Re-source the rc file (`source ~/.bashrc` / `source ~/.config/fish/config.fish`)
- OR re-login
- OR invoke `/usr/local/bin/zig` directly for the rest of the plan

No commit. Proceed to Task 4.

---

### Task 4: Build the miner (ReleaseFast + PGO use + x86_64_v3 baseline)

**Files:**
- Create: `/home/priest/Projects/Dirtybird-Zig-Miner/zig-out/bin/zig-miner`

- [ ] **Step 4.1: Clean any prior build cache to make PGO=$use deterministic**

Run:
```sh
rm -rf /home/priest/Projects/Dirtybird-Zig-Miner/zig-out /home/priest/Projects/Dirtybird-Zig-Miner/.zig-cache
```

Expected: no output. (Safe: this plan is purely a build, not an edit.)

- [ ] **Step 4.2: Call `zig build` directly (NOT `./build.sh`, which would force `-Dcpu=native`)**

Run:
```sh
cd /home/priest/Projects/Dirtybird-Zig-Miner
zig build -Doptimize=ReleaseFast
```

Expected console output (printed by `build.zig:78` BEFORE the compile; capture the line):
```
build: optimize=ReleaseFast cpu=x86_64_v3 pgo=use
```

**Failure paths** (do NOT proceed):

- `pgo=off` printed → `_pgo/merged.profdata` is missing or unreadable. STOP; check Task 1.4.
- `cpu=` is anything other than `x86_64_v3` (e.g. `x86_64`, `znver5`, `native`) → STOP; the `-Dcpu=native` flag was leaked. Re-invoke as `zig build -Doptimize=ReleaseFast` (no extra flags) and re-check.
- A Zig 0.14.1 parse error on `std.comptime_only` etc. → another `zig` is shadowing `/usr/local/bin/zig`. Re-run as `/usr/local/bin/zig build -Doptimize=ReleaseFast` and re-check version.
- Linker error involving `libsais`/`v114` SA objects → STOP; surface the error.

- [ ] **Step 4.3: Verify the binary exists and is a real ELF**

Run:
```sh
ls -la /home/priest/Projects/Dirtybird-Zig-Miner/zig-out/bin/zig-miner
file /home/priest/Projects/Dirtybird-Zig-Miner/zig-out/bin/zig-miner
```

Expected output (size will vary, but non-zero and ELF-class=x86_64):
```
-rwxr-xr-x 1 priest priest [NN]M ... /home/priest/Projects/Dirtybird-Zig-Miner/zig-out/bin/zig-miner
/home/priest/Projects/Dirtybird-Zig-Miner/zig-out/bin/zig-miner: ELF 64-bit LSB executable, x86-64, ...
```

If file is missing, `<1 MB`, or wrong arch → STOP; re-run with `-Dcpu=native -Dverbose` and surface.

- [ ] **Step 4.4: Clean up transient /tmp files**

Run:
```sh
rm -f /tmp/zig-0.14.1.tar.xz /tmp/zig-shasums.txt /tmp/zig-expected.sha256
```

Expected: silent completion.

No commit. Proceed to Task 5.

---

### Task 5: Verify the binary with `--selftest`

**Files:** none

- [ ] **Step 5.1: Run the known-answer test built into the miner**

Run:
```sh
cd /home/priest/Projects/Dirtybird-Zig-Miner
./zig-out/bin/zig-miner --selftest
echo "selftest exit code: $?"
```

Expected:
- Process prints KAT pass message (per `src/pow.zig`/`src/astrobwt.zig`, the selftest exercises the entire AstroBWTv3 pipeline).
- `$?` prints `0`.

**Failure path** — non-zero exit:
STOP. Do not proceed to Task 6. Surface stdout AND stderr to the user; a KAT mismatch means the binary's hash is wrong and it would never produce valid shares on a pool.

No commit. Proceed to Task 6.

---

### Task 6: Hand off (print binary path + run command)

**Files:** none (`zig-out/` is `.gitignore`-d; no commit expected)

- [ ] **Step 6.1: Print binary metadata**

Run:
```sh
file /home/priest/Projects/Dirtybird-Zig-Miner/zig-out/bin/zig-miner
ls -la /home/priest/Projects/Dirtybird-Zig-Miner/zig-out/bin/zig-miner
```

Expected: same ELF info as Task 4.3, with a fresh mtime (just-built).

- [ ] **Step 6.2: Print the run-line with this binary's absolute path**

Print:
```
binary  : /home/priest/Projects/Dirtybird-Zig-Miner/zig-out/bin/zig-miner
toolchain: /usr/local/bin/zig -> /opt/zig-0.14.1/zig (Zig 0.14.1)
cpu target: x86_64_v3 + sha_ni
pgo/lto: applied (shipped _pgo/merged.profdata, default-on)

example run:
  /home/priest/Projects/Dirtybird-Zig-Miner/zig-out/bin/zig-miner \
    -d pool.example:10100 -w dero1q...your_wallet... -t 20

thread-count note:
  -t 20 ≈ 60% of this host's 32 cores; adjust to taste
  (see README for the rest of the CLI surface: -a affinity, etc.)
```

- [ ] **Step 6.3: Confirm "no commit" — binary lives in `zig-out/`, which is `.gitignore`-d**

Run:
```sh
git check-ignore zig-out/bin/zig-miner && echo "zig-out/: ignored (correct — artifact not committed)"
```

Expected: prints `zig-out/: ignored (correct — artifact not committed)`.

End of plan.

---

## Self-review against the spec

- **Decision 1** (compile from source): Task 4 ✓
- **Decision 2** (use shipped PGO): Task 1.4 verifies presence; Task 4.2 confirms `pgo=use` printed ✓
- **Decision 3** (Zig 0.14.1 system-wide at /opt/zig-0.14.1 + /usr/local/bin/zig): Tasks 2, 3 ✓
- **Decision 4** (call `zig build` directly, bypass `./build.sh`): Task 4.2 explicit; failure-mode covers `cpu=native` leak ✓
- **Decision 5** (verify with `--selftest`): Task 5 ✓
- **Decision 6** (leave at `zig-out/bin/zig-miner`, no install-tarball): Task 6 ✓ (no Phase 5/6 to package)
- **Out of scope** (no fresh PGO, no extra targets, no daemon config): README's build.zig options explicitly unused ✓
- **Risks** (tarball download + which-zig ordering): Tasks 2.3, 3.3 cover both ✓

No placeholders, no "TBD", no "implement later". Every step has a real command and an explicit expected output. Type/path consistency: `/home/priest/Projects/Dirtybird-Zig-Miner/zig-out/bin/zig-miner` and `/opt/zig-0.14.1/zig` are used identically across all tasks.
