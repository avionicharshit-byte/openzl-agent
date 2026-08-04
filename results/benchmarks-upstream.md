# Upstream re-benchmark — OpenZL `dev` @ 2026-07-30 (run 2026-07-31)

Re-runs the Stage-0 spike (`results/benchmarks.md`) against a freshly built upstream
`zli`, to check whether the 6-month-old baseline binary was hiding anything.

## Build

| | Old build (baseline) | New build (upstream) |
|---|---|---|
| Repo path | `~/Documents/OpenSource/openzl` (branch `dev`) | `~/Documents/OpenSource/openzl-upstream` (git worktree, detached) |
| Commit | `87b06a7587e2c5c2a83033d658a352faa7c66f5e` (2026-01-09) | `a9de25e63990035a63e537de60604eeb1f64568b` (2026-07-30 07:04:38 -0700, "Remove noisy trained graph logging (#924)") |
| Binary | `build/cli/zli` (Dec 6 2025) | `build/cli/zli` |
| `--version` | `zstrong-cli version 0.1` | `Demo CLI for OpenZL. Version 0.2.4` |

515 commits between them. Machine: macOS 26.2, Apple Silicon, 8 cores.

Build notes: clean, no fixes needed.
```
git worktree add --detach ~/Documents/OpenSource/openzl-upstream upstream/dev
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release   # ~15 s configure
cmake --build build --target zli -j8             # ~11 min (xgboost_external dominates)
cmake --build build --target sddl_compiler sddl2_compiler -j8
```
Only warning: one `ld: warning: ignoring duplicate libraries` at link. The old
`build/cli/zli` was not touched.

CLI flag change: `--chunk-size-mb <N>` was replaced by `--chunk-size <20M|1G|…>`.
New `train` flags: `--dict-bundle-output/-O`, `--save-ace-state`, `--pareto-frontier`,
`--num-samples`, `--use-all-samples`, `--threads`, `--no-clustering`.

All numbers below are exact bytes. **Every OpenZL result was round-tripped and `cmp`-verified
byte-identical** unless marked FAILED. zstd/gzip baselines are carried over from
`results/benchmarks.md` (not re-run).

---

## A — NYC 311 CSV (`data/nyc311/nyc311.csv`, 87,500,349 B)

Trained: `zli train --profile csv data/train_samples --max-time-secs 120 -f`

| Compressor | Size (B) | vs zstd -3 | Compress | Decompress | cmp |
|---|---|---|---|---|---|
| zstd -3 (baseline) | 9,050,952 | — | | | |
| OpenZL trained, old build | 5,556,920 | −38.60% | | | ok |
| **OpenZL trained, new build** | **4,521,797** | **−50.04%** | 412 ms / 212 MB/s | 116 ms / 751 MB/s | **ok** |

**IMPROVEMENT: new build is 18.63% smaller than old build.** Biggest change in the set.
Trained compressor grew 3,084 B → 19,980 B. Trainer reported "improved compression ratio by 89.52%".

## B — GitHub Archive JSONL (`data/gharchive/events.jsonl`, 80,000,000 B)

Trained: `zli train --profile serial data/gharchive_samples --max-time-secs 120 -f`

| Compressor | Size (B) | vs zstd -3 | Compress | Decompress | cmp |
|---|---|---|---|---|---|
| zstd -3 (baseline) | 14,021,543 | — | | | |
| OpenZL serial trained, old build | 12,069,808 | −13.92% | 670 ms / 119 MB/s | | ok |
| **OpenZL serial trained, new build** | **13,180,660** | **−6.00%** | 402 ms / 199 MB/s | 44 ms / 1,835 MB/s | **ok** |
| new build + `--save-ace-state` | 13,180,660 | −6.00% | 403 ms | 43 ms | ok |
| OpenZL serial **untrained**, old build | 13,096,336 | −6.60% | 417 ms / 192 MB/s | | |
| OpenZL serial **untrained**, new build | 15,469,006 | +10.32% (worse) | 145 ms / 553 MB/s | | |

**REGRESSION: new build is 9.20% larger than old build.** Root cause identified — the `serial`
profile's default fallback graph was changed:

* old `cli/utils/compress_profiles.cpp`: `ZL_Compressor_buildACEGraphWithDefault(compressor, ZL_GRAPH_ZSTD)`
* new: `ZL_Compressor_buildACEGraphWithDefault(compressor, ZL_GRAPH_LZ)` wrapped in `ZL_Compressor_buildSerialSegmenter`

This is a deliberate ratio-for-speed trade (untrained serial: 18% worse ratio, 2.9x faster;
trained: 9.2% worse ratio, 1.7x faster compress, and decompress went 1,835 MB/s).
Ruled out as causes: chunk size (20M / 80M / 200M all within 0.4%) and ACE state
(`--save-ace-state` produced a byte-identical output).

JSONL remains the weak dataset; the new build makes it worse, not better.

## C — PyTorch checkpoints

| File | Compressor | Size (B) | vs zstd -3 | Compress | cmp |
|---|---|---|---|---|---|
| `resnet18.pth` (46,830,571 B) | zstd -3 | 43,404,736 | — | | |
| | pytorch profile, old build | 39,035,988 | −10.06% | | ok |
| | **pytorch profile, new build** | **39,047,321** | **−10.04%** | 26 ms / 1,811 MB/s | **ok** |
| `mobilenet_v2_zip.pth` (14,258,573 B) | zstd -3 | 13,165,367 | — | | |
| | pytorch profile, old build | 11,873,139 | −9.81% | | ok |
| | **pytorch profile, new build** | **11,880,919** | **−9.76%** | 19 ms / 751 MB/s | **ok** |
| `mobilenet_v2.pth` (legacy pickle) | pytorch profile, new build | **FAILED** | | | n/a |

resnet18 +0.029%, mobilenet_zip +0.066% — both within noise, no meaningful change.

**Legacy `.pth` still rejected upstream**, identical error:
```
ZS2_ZipLexer_init (custom_parsers/zip_lexer.c:540): Check `reverseOffset >= maxReverseOffset' failed: Generic: EOCD not found
  #1 pytorchModelSegmenter (custom_parsers/pytorch_model_parser.c:175)
```
An agent still has to detect pre-torch-1.6 non-zip checkpoints and route them elsewhere.

## D — Binary tick feed + LLM-written SDDL (`data/ticks/btcusdt.bin`, 65,600,016 B)

| Compressor | Size (B) | vs zstd -3 | Compress | Decompress | cmp |
|---|---|---|---|---|---|
| zstd -3 (baseline) | 11,743,706 | — | | | |
| SDDL1 (`results/ticks.oldv1.sddl`), old build | 6,045,256 | −48.52% | 540 ms / 122 MB/s | 876 MB/s | ok |
| **SDDL1 (`results/ticks.oldv1.sddl`), new build** | **6,030,832** | **−48.65%** | 427 ms / 154 MB/s | 78 ms / 837 MB/s | **ok** |
| SDDL2 (ported description, see below), new build | 6,281,742 | −46.51% | 308 ms / 213 MB/s | 41 ms / 1,604 MB/s | ok |

New build 0.24% smaller than old on the SDDL1 path — no meaningful change. The best working
description is still `results/ticks.oldv1.sddl` via `--profile sddl`.

The SDDL2 path costs 4.16% ratio but buys 1.9x decompress speed.

---

## SDDL dialect findings

The "documented v0.5/v0.6 syntax vs undocumented oldv1 dialect" confusion from the spike is now
explained: **they are two different languages, SDDL1 and SDDL2, each with its own compiler and its
own `zli` profile.** Upstream commit `4918a3b` ("Reorganize SDDL examples into sddl/ and sddl2/
directories", #726, 2026-05-04) split them explicitly.

| | SDDL1 | SDDL2 |
|---|---|---|
| `zli` profile | `--profile sddl` | `--profile sddl2` |
| Standalone compiler | `build/tools/sddl/sddl_compiler` (stdin → stdout) | `build/tools/sddl2/sddl2_compiler` (`-i` / `-o`) |
| Record syntax | `Trade = { Int64LE … }`, positional, no field names | `record Trade() { price: Float64LE, … }`, named fields, commas |
| Upstream example | `examples/sddl/sao_silesia.oldv1.sddl` | `examples/sddl2/sao_silesia.sddl` |

### Does the shipped example still fail?

**No — fixed, and it was never a compiler bug.** In the old checkout,
`examples/sddl/sao_silesia.sddl` contained *SDDL2* source sitting in the *SDDL1* directory, so
feeding it to `sddl_compiler` failed. Verified on both builds:

* old `sddl_compiler` < old `examples/sddl/sao_silesia.sddl` → exit 1, `syntax error: Unexpected separator token ','`
* new `sddl_compiler` < `examples/sddl/sao_silesia.oldv1.sddl` → **exit 0**, 1,360 B bytecode
* new `sddl2_compiler` -i `examples/sddl2/sao_silesia.sddl` → **exit 0**, 471 B bytecode
* new `sddl_compiler` < `examples/sddl2/sao_silesia.sddl` → exit 1 (expected: wrong language)

Upstream no longer ships `examples/sddl/sao_silesia.sddl`; it moved to `examples/sddl2/`.
It does still ship `sao_silesia.oldv1.sddl` (plus a new `sao_full.oldv1.sddl`).

### Our two tick descriptions on the new build

| Description | Profile | Result |
|---|---|---|
| `results/ticks.oldv1.sddl` | `sddl` | **compiles**, 6,030,832 B, cmp ok |
| `results/ticks.oldv1.sddl` | `sddl2` | fails (SDDL1 syntax) |
| `results/ticks.sddl` | `sddl` | fails — `syntax error: Unexpected separator token ','` at `magic: Bytes(4),` |
| `results/ticks.sddl` | `sddl2` | fails — `parse error: Failed to match args for rule: GrammarRule(Symbol::ASSIGN …)` at `Record Header() = {` |

`results/ticks.sddl` fails on upstream because **SDDL2's record syntax changed**: the keyword is now
lowercase `record` with no `=`, i.e. `record Header() { … }`, not `Record Header() = { … }`.
Same change is visible in the shipped example (`git show 62852de`, `4918a3b`). The `Record X() = {}`
form compiles under *neither* compiler in *either* build — it is a dead dialect.

Confirmed by porting it (scratch copy at
`…/scratchpad/upstream-bench/ticks_sddl2_port.sddl`; `results/ticks.sddl` left untouched) — only
`Record X() = {` → `record X() {` and `var n =` → `n =` were needed; `expect` and member access
still work. It compiles (892 B bytecode) and round-trips.

Upstream SDDL2 keyword table (`tools/sddl2/compiler/Syntax.cpp:150-200`): `record`, `when`,
`expect`, `sizeof`, `abs`, `between`, `@`, and types `Byte`, `UInt8`/`Int8`, `{U,}Int{16,32,64}{LE,BE}`,
`Float{16,32,64}{LE,BE}`, `BFloat16{LE,BE}`, `Bytes`. There is no `var`.

**Implication for the agent:** an LLM writing SDDL must be told which of the two languages it is
targeting, and the SDDL2 record syntax it will most likely emit from the public docs
(`Record X() = {`) is stale. Pin the prompt to `examples/sddl2/sao_silesia.sddl` from the pinned
upstream commit, and prefer SDDL1 (`--profile sddl`) when ratio matters.

## Is there a JSON/JSONL profile upstream?

**No.** Full `zli list-profiles` on the new build:

```
csv, i8, u8, le-i16, le-i32, le-i64, le-u16, le-u32, le-u64,
numeric-ml-selector-64, parquet, pytorch, sao, sddl, sddl2, serial, zstd
```

Added since the old build: `i8`, `u8`, `numeric-ml-selector-64` (placeholder), and `zstd`
("Use this profile to train a Zstd dict"). Nothing JSON-shaped.
`git grep -li json` across `cli/` and `custom_parsers/` hits exactly one file,
`cli/commands/cmd_inspect.cpp` (output formatting only). The JSONL gap in the Stage-0 spike is
still wide open, and B above shows it got worse.

Also changed: `sddl2`'s `--profile-arg` now takes a **description source file** and compiles it
in-process; the old build required pre-compiled bytecode. That removes the separate
`sddl2_compiler` step from the agent's pipeline.

## Training-overrun bug: partially fixed

| | Old build | New build |
|---|---|---|
| Respects `--max-time-secs`? | no | **still no** |
| Process exits on its own? | no (had to be killed) | **yes, exit 0** |
| Writes best-so-far `.zlc` mid-run? | yes | no — file stays 0 B until the end |
| Progress reporting | none | progress bar, "Training ACE graph N / M" |

Measured with `--max-time-secs 120`:

* csv / `data/train_samples` (25 MB): **495 s wall** = 4.1x the budget. Exit 0.
* serial / `data/gharchive_samples` (26 MB): **146 s wall** = 1.2x the budget. Exit 0.

The overrun is in the ACE-successor training phase, which does not check the deadline: the csv run
spent ~370 s of its 495 s cycling "Training ACE graph 1..15 / 15" after the 120 s budget expired.
The old workaround (`--no-ace-successors`) still applies and is still the way to make the budget
mean something. Net: the hang is gone and the trainer is now safe to call synchronously, but
`--max-time-secs` is still not a wall-clock guarantee — budget 4-5x for csv.

---

## Summary of changes > 2%

| Dataset | Change | Direction |
|---|---|---|
| NYC 311 CSV | −18.63% size | **improvement** |
| GitHub Archive JSONL | +9.20% size | **regression** (deliberate `ZL_GRAPH_ZSTD` → `ZL_GRAPH_LZ` default) |
| Ticks, SDDL2 vs SDDL1 path | +4.16% size | not a regression — different profile, 1.9x faster decompress |

resnet18 (+0.029%), mobilenet_v2_zip (+0.066%) and ticks SDDL1 (−0.239%) are all within noise.

Verdict against the Stage-0 kill criterion (≥30% better than zstd -3): unchanged in shape but
stronger at the top — CSV now −50.04% (was −38.60%), LLM-SDDL binary −48.65%, checkpoints −10.04%,
JSONL −6.00% (was −13.92%). Two clear passes, and the JSONL failure is now more decisive.

### Reproduce

```sh
NEWZLI=~/Documents/OpenSource/openzl-upstream/build/cli/zli
$NEWZLI train --profile csv    data/train_samples      -o nyc311_up.zlc    --max-time-secs 120 -f
$NEWZLI train --profile serial data/gharchive_samples  -o gharchive_up.zlc --max-time-secs 120 -f
$NEWZLI compress data/nyc311/nyc311.csv       -c nyc311_up.zlc    -o nyc311_up.zl    -f
$NEWZLI compress data/gharchive/events.jsonl  -c gharchive_up.zlc -o gharchive_up.zl -f
$NEWZLI compress data/pytorch/resnet18.pth    --profile pytorch   -o resnet18_up.zl  -f
$NEWZLI compress data/ticks/btcusdt.bin --profile sddl --profile-arg results/ticks.oldv1.sddl -o ticks_up.zl -f
```
