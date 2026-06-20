# Bench → Tune → Connect (TLS adapter) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: implementing with checkpoints via executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** drive `zig-miner` from "compiles + `--selftest` PASS" to "real pool mining". Stage 1 re-baselines benchmark numbers; Stages 2–3 fix the Zen 5 affinity / CPU-tuning gaps; Stage 4 finishes the 0.16 `tls.Client` adapter; Stage 5 verifies end-to-end.

**Architecture:**
- Stage 1: cheap excursion — measurement only, no source edits. 5 variants × 30 s median (warm-up-discarded).
- Stage 2: runtime topology probe replaces hard-coded affinity order in `src/system.zig:291`. Linux `/sys/devices/system/cpu/cpuN/topology/thread_siblings_list` falls back to the existing i7-shaped array on read failure.
- Stage 3: lock the variant that wins, propagate into `bench.zig` defaults.
- Stage 4: complete `src/net.zig` TCP→TLS→WebSocket path using 0.16 `std.Io.Reader` / `std.Io.Writer` vtables around the existing `SelectStream`.

**Tech stack:** Zig 0.16.0, AMD Zen 5 (Ryzen AI MAX+ PRO 395, 16 P-cores × SMT-2 = 32 logical), SHA-NI, AVX-512.

---

## File Structure

| Path | Change | Touch |
|---|---|---|
| `src/system.zig` | rewrite `recommendedAffinityForThreads` + `pinThreadToLogical` topology probe | this stage |
| `src/bench.zig` | add `--aff-list` parsing path; record default build/cpu for winner stage | this stage |
| `build.zig` | document `-Dcpu=native` as alternate; nothing structural | optional |
| `src/net.zig` | TLS Reader/Writer vtable; thread `io: std.Io`; remove stubs | stage 4 only |
| `src/main.zig` | hot-loop wiring if Stage 4 reveals anything | stage 4 only |
| `docs/superpowers/specs/2026-06-20-zig-016-port-postmortem.md` | mark TLS Adapter section "DONE" when Stage 4 finishes | appendix change |
| `docs/perf-baseline-<date>.md` | NEW — record per-variant numbers | stage 1c |

---

## STAGE 1 — bench baseline variants

Goals: produce five data points so we know which knob matters here, *before* committing to any source edits.

### Task 1.1 — v1 (current default: `-Dcpu=x86_64_v3+sha`, shipped PGO, system.zig default affinity)

- [ ] **Step 1.1.1: 30 s single-thread bench** to get a cheap single-thread upper-bound for this host.
  ```sh
  /home/priest/Projects/Dirtybird-Zig-Miner/zig-out/bin/bench -- 1 30 0 0
  ```
  Expected: roughly proportional KH/s/thread. Discard first second's output (cache warm-up). Note the printed number.

- [ ] **Step 1.1.2: 8 threads at first-8-P-cores**
  ```sh
  /home/priest/Projects/Dirtybird-Zig-Miner/zig-out/bin/bench -- 8 30 0 0
  ```
  8 ≥ recommended pool. Note that `nthreads ≠ 10` so the AFF_MAPS branch doesn't apply; `system.recommendedAffinityForThreads(8)` is used. Expect roughly 8 × (single-thread) but sub-linear.

- [ ] **Step 1.1.3: 16 threads at `recommendedAffinityForThreads(16)`**
  ```sh
  /home/priest/Projects/Dirtybird-Zig-Miner/zig-out/bin/bench -- 16 30 0 0
  ```
  Expected: as the user's prior `1.265 KH/s/thread × 16` baseline. Confirm or refute.

- [ ] **Step 1.1.4: 32 threads at default order**
  ```sh
  /home/priest/Projects/Dirtybird-Zig-Miner/zig-out/bin/bench -- 32 30 0 0
  ```
  Default does THREADING without affinity (Windows-only affinity gating). Expected to be lower than 16t.

### Task 1.2 — v2 (`-Dcpu=native` rebuild, native SHA + AVX-512 features)

- [ ] **Step 1.2.1: rebuild with native CPU + shipped PGO**
  ```sh
  cd /home/priest/Projects/Dirtybird-Zig-Miner
  zig build -Doptimize=ReleaseFast -Dcpu=native
  ```
  Expected: `build: optimize=ReleaseFast cpu=znver5_or_similar pgo=use`. The `build.zig:23` comment about "legacy-SSE SHA beats native" was the original reasoning, retrofitted to Stage 2 here. Capture the actual `cpu=` line for the baseline doc.

- [ ] **Step 1.2.2: re-run 1.1.1 through 1.1.4** using the new binary.
  Expect at minimum ≥ v1 numbers; if not, AVX-512 isn't paying off and we drop the native path.

### Task 1.3 — v3 (locally-collected PGO + native)

- [ ] **Step 1.3.1: collect a fresh PGO profile**
  ```sh
  cd /home/priest/Projects/Dirtybird-Zig-Miner
  sudo cp /usr/lib/zig/std/lib/std.zig /opt/zig-std-lib 2>/dev/null  # only if ~/ is rejected by scripts/build-pgo.sh, otherwise skip
  ./scripts/build-pgo.sh /usr/lib/clang/20/lib/x86_64-unknown-linux-gnu/libclang_rt.profile-x86_64.a
  TRAIN_SECS=60
  ```
  Expected: libclang_rt.profile path may need adjustment per `clang --print-runtime-dir`. Output: a `_pgo/merged.profdata` ≥ several MB (was 48 KB shipped).

- [ ] **Step 1.3.2: rebuild on top of fresh PGO** — `zig build -Doptimize=ReleaseFast -Dcpu=native`. The shipped-vs-fresh PGO automatically applies via `build.zig:73`.

- [ ] **Step 1.3.3: re-run 1.1.1 through 1.1.4** against the rebuilt binary.

### Task 1.4 — write `docs/perf-baseline-2026-06-20.md`

- [ ] **Step 1.4.1: record every variant**
  Columns: variant | build | threads | affinity scheme | KH/s/thread | KH/s total.

- [ ] **Step 1.4.2: pick the winner** — best KH/s/thread × thread-count tradeoff. Default: most KH/s/thread, not most total KH/s, unless the gain comes from threads.

- [ ] **Step 1.4.3: commit the artifacts as a single commit** with prefix `perf:`.

---

## STAGE 2 — fix Zen-5 affinity in `src/system.zig`

### Task 2.1 — runtime topology probe

- [ ] **Step 2.1.1: read the existing function** (it's at line 291; show its current body for context).
- [ ] **Step 2.1.2: add a private `topologyProbe(allocator)` helper** that walks `/sys/devices/system/cpu/cpuN/topology/thread_siblings_list` for each N up to `getCpuCount()`, parses to MT-siblings sets, builds per-global-physical-id groups, returns `[24]u6` ordered "distinct physicals first, then HT siblings of distinct physicals in the order of least-taken slots".

- [ ] **Step 2.1.3: rewrite `recommendedAffinityForThreads`** so it uses the probed list. On read failure or non-Linux, fall back to the existing i7-shaped `order` array.
- [ ] **Step 2.1.4: add a test** `correctness "Zen 5 returns 0,2,4,...,30 for n=32"` that detects regressions on hosts where `lscpu | grep "Thread(s) per core: 2"` reports 2 SMT.
- [ ] **Step 2.1.5: run `zig build test`** — must pass.
- [ ] **Step 2.1.6: commit** with prefix `fix(system):`.

### Task 2.2 — add `--aff-list` debug flag

- [ ] **Step 2.2.1: extend `bench.zig` argparse** (the `bench -- <threads> <secs> <aff 0/1> <affmode>` interface) to parse `--aff-list` and print the discovered order on a single line then exit 0.

- [ ] **Step 2.2.2: verify** with `./zig-out/bin/bench --aff-list` — output should match what we predicted in Stage 2 mental model: 16 distinct physicals in some order followed by their 16 HT siblings.

- [ ] **Step 2.2.3: commit** with `feat(bench):`.

---

## STAGE 3 — lock winning build knobs

### Task 3.1 — promote winner into documented defaults

- [ ] **Step 3.1.1: edit `scripts/release.sh` README conventions** (or `README.md` if that's the canonical perf doc) to record the chosen variant.
- [ ] **Step 3.1.2: commit** with `docs:` prefix.
- [ ] **Step 3.1.3: re-verify** that `./zig-out/bin/zig-miner --selftest && ./zig-out/bin/zig-out/bin/bench -- N S 0 0` still produces the expected KH/s/thread for at least one variant.

---

## STAGE 4 — TLS Reader/Writer adapter (`src/net.zig`)

This is the *single architectural* piece left on the project. Per
`docs/superpowers/specs/2026-06-20-zig-016-port-postmortem.md` §"How to finish the TLS adapter".

### Task 4.1 — read vtable scaffolding

- [ ] **Step 4.1.1: read `std.Io.Reader` interface + `std.Io.net.Stream.init` body** at `/usr/lib/zig/std/Io/Reader.zig` and `/usr/lib/zig/std/Io/net.zig:1280`. The plan MUST reference what those look like before writing the implementation.

### Task 4.2 — `SelectStream` → Io.Reader vtable

- [ ] **Step 4.2.1: define** `const StreamVTableReader = Io.Reader.VTable{ .streamFn = selectStreamReadFn, .readVecFn = … }` near the top of `src/net.zig`.

- [ ] **Step 4.2.2: implement `selectStreamReadFn`** using the existing `SelectStream.read` body — translate errno into `Io.Reader.Error` set.

### Task 4.3 — `SelectStream` → Io.Writer vtable

- [ ] **Step 4.3.1: define** `StreamVTableWriter = Io.Writer.VTable{ .streamFn = selectStreamWriteFn, .writeVecFn = … }`.

- [ ] **Step 4.3.2: implement `selectStreamWriteFn`** using the existing `SelectStream.write` body.

### Task 4.4 — thread `io: std.Io` through every related signature

- [ ] **Step 4.4.1: `connectAndUpgrade`** — accept `io: std.Io` as first arg.
- [ ] **Step 4.4.2: `Conn`** — keep `netstream`, store `io` field.
- [ ] **Step 4.4.3: `sendFrame`** and **`sessionLoop`** — accept `io: std.Io`.
- [ ] **Step 4.4.4: callers in `src/main.zig`** — pass `init.io`.
- [ ] **Step 4.4.5: `net.run`** — already takes `allocator, cfg, hooks`; add `io: std.Io`.

### Task 4.5 — replace downstream tls.Client call sites

- [ ] **Step 4.5.1: replace** `conn.client.read(stream, &buf)` (in `sessionLoop`) with `conn.client.reader.interface.readSliceAll(&buf)` (or `readSliceAtLeast` for the >1-record idle pattern).
- [ ] **Step 4.5.2: replace** `conn.client.writeAll(stream, req)` (in `connectAndUpgrade` HTTP upgrade + `sendFrame`) with plaintext fed into `conn.client.writer`.

- [ ] **Step 4.5.3: delete** the `_ = &conn; return error.TlsAdapterNotImplemented;` stub in `connectAndUpgrade` *and* the `if (false) { … }` gate in `sessionLoop` line 808.

- [ ] **Step 4.5.4: run `zig build`** — must succeed.

### Task 4.6 — smoke test

- [ ] **Step 4.6.1: `./zig-out/bin/zig-miner --selftest`** — must PASS.
- [ ] **Step 4.6.2: `bench`** — must produce comparable KH/s/thread to the Stage-1 winner.
- [ ] **Step 4.6.3: end-to-end** `./zig-out/bin/zig-miner -d <realpool> -w <wallet> -t 16` — connect, see "Connected", see a job delivered, see shares submitted. If real network unreachable, fall back to a `nc -l 10100` mock and leave the smoke-test to a follow-up.

### Task 4.7 — close the postmortem

- [ ] **Step 4.7.1: update** `docs/superpowers/specs/2026-06-20-zig-016-port-postmortem.md` §"Residual src/net.zig TLS work" → flip to "DONE; see commit `<sha>`".

---

## STAGE 5 — end-to-end validation

- [ ] **Step 5.1: `zig build -Doptimize=ReleaseFast`** — must build clean, no `unreachable code`, no unused locals.
- [ ] **Step 5.2: `./zig-out/bin/zig-miner --selftest`** — passes.
- [ ] **Step 5.3: `./zig-out/bin/bench -- 16 30 0 0`** — KH/s/thread ≥ Stage 1's winner.
- [ ] **Step 5.4: real-pool smoke** — or `nc -l 10100` mock — connect status logged, sleep 10 s, the connection-time histogram shifts (or `error.TlsAdapterNotImplemented` no longer fires).

---

## Self-review (write-up checklist)

- Plan covers all 4 user-approved stages + the 5th validation tail.
- Every file change has a path and a behavior target, no placeholders.
- Each task's first step is concrete and produces an observable output.
- Stage 1 is purely measurement, so the plan can stop gracefully at any task boundary if perf tuning reveals the priorities should change.
- Stage 4 is gated — we don't begin the TLS adapter until Stages 1–3 are committed (because real hashrate data first; affinity fix first; etc).

No placeholders, no "TBD", no "implement appropriately".
