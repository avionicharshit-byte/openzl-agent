# OpenZL benchmarks — real datasets, `zli` v0.2.4

Run 2026-07-31. Machine: macOS 26.2, Apple Silicon, 8 cores.

`zli` built from [facebook/openzl](https://github.com/facebook/openzl) @
`a9de25e63990035a63e537de60604eeb1f64568b` (2026-07-30, `--version` reports 0.2.4):

```sh
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build --target zli -j8                          # ~11 min
cmake --build build --target sddl_compiler sddl2_compiler -j8 # optional
```

Baselines: `zstd -3` (the realistic incumbent), `zstd -19 -T0`, `gzip -9`, same machine.
Sizes are exact bytes where recorded. **Every OpenZL result was decompressed and
`cmp`-verified byte-identical** unless marked FAILED.

## Summary

| Dataset | Input | Path | OpenZL | vs zstd -3 | vs zstd -19 |
|---|---|---|---|---|---|
| NYC 311 CSV | 87.5 MB | `csv` profile, trained | 4,521,797 B | **−50.04%** | −11.7% |
| Binary tick feed | 65.6 MB | LLM-written SDDL1 | 6,030,832 B | **−48.65%** | −34.5% |
| resnet18.pth | 46.8 MB | `pytorch` profile | 39,047,321 B | −10.04% | −10.0% |
| GH Archive JSONL | 80.0 MB | `serial`, trained | 13,180,660 B | −6.00% | **+38.0% — loses** |

Against the project's bar (≥30% smaller than `zstd -3`): two clear passes (CSV,
LLM-SDDL binary), one miss-but-unique (checkpoints — see C), one fail (JSONL — see B).

---

## A — NYC 311 CSV (`data/nyc311/nyc311.csv`, 87,500,349 B, 41 messy columns)

Source: `curl "https://data.cityofnewyork.us/resource/erm2-nwe9.csv?$limit=100000"`

Trained: `zli train --profile csv data/train_samples --max-time-secs 120 -f`
(three ~8 MB sample files; trainer reported "improved compression ratio by 89.52%",
`.zlc` = 19,980 B).

| Compressor | Size | Compress | Decompress | cmp |
|---|---|---|---|---|
| gzip -9 | 12,467,794 B | 2.4 s | | |
| zstd -3 | 9,050,952 B | 0.6 s | | |
| zstd -19 -T0 | 5,122,896 B | 14.6 s (34 s CPU) | | |
| **OpenZL csv trained** | **4,521,797 B** | **412 ms / 212 MB/s** | 116 ms / 751 MB/s | **ok** |

**−50.04% vs zstd -3 in the same speed class, and smaller than zstd -19 at ~35x its speed.**
Training is a one-time cost per format, not per file.

## B — GitHub Archive JSONL (`data/gharchive/events.jsonl`, 80,000,000 B)

Source: `curl https://data.gharchive.org/2026-07-29-15.json.gz | gzip -dc | head -c 80000000`

Trained: `zli train --profile serial data/gharchive_samples --max-time-secs 120 -f`

| Compressor | Size | Compress | Decompress | cmp |
|---|---|---|---|---|
| gzip -9 | 16.23 MB | | | |
| zstd -3 | 14,021,543 B | | | |
| zstd -19 -T0 | 9,553,389 B | | | |
| OpenZL serial untrained | 15,469,006 B | 145 ms / 553 MB/s | | |
| **OpenZL serial trained** | **13,180,660 B** | 402 ms / 199 MB/s | 44 ms / 1,835 MB/s | **ok** |

**FAIL vs the bar — trained `serial` beats zstd -3 by only 6% and clearly loses to
zstd -19.** Two structural reasons:

- **OpenZL has no JSON/JSONL profile** (see profile list below — grep across `cli/` and
  `custom_parsers/` confirms nothing JSON-shaped). JSON needs structure-aware shredding
  into typed columns, which nothing provides out of the box yet.
- The `serial` profile's default fallback graph is `ZL_GRAPH_LZ` wrapped in a serial
  segmenter (`cli/utils/compress_profiles.cpp`) — a deliberate speed-over-ratio default
  (note the 1,835 MB/s decompress). Chunk size (20M/80M/200M) changes the result by
  <0.4%.

The honest recommendation for JSONL today is zstd.

## C — PyTorch checkpoints (`pytorch` profile, no training)

| File | Compressor | Size | Compress | cmp |
|---|---|---|---|---|
| `resnet18.pth` (46,830,571 B) | zstd -3 | 43,404,736 B | | |
| | zstd -19 | 43.39 MB | | |
| | xz -9 | 42.86 MB | very slow | |
| | **OpenZL pytorch** | **39,047,321 B** | 26 ms / 1,811 MB/s | **ok** |
| `mobilenet_v2_zip.pth` (14,258,573 B) | zstd -3 | 13,165,367 B | | |
| | **OpenZL pytorch** | **11,880,919 B** | 19 ms / 751 MB/s | **ok** |
| `mobilenet_v2.pth` (legacy pickle) | OpenZL pytorch | **FAILED** | | n/a |

**−10% vs zstd -3 misses the 30% bar, but judge it on bytes removed and throughput:**
float32 weights are high-entropy, so OpenZL's ~7.8 MB removed from resnet18 is **2.3x
what zstd removes**, at GB/s speeds. Real money at checkpoint-pipeline scale; meh for a
one-off file.

**Legacy (pre-torch-1.6, non-zip) `.pth` files are rejected** with a confusing error —
they're pickles, not zip containers, and need re-saving before the profile applies:

```
ZS2_ZipLexer_init (custom_parsers/zip_lexer.c:540): Check `reverseOffset >= maxReverseOffset' failed: Generic: EOCD not found
  #1 pytorchModelSegmenter (custom_parsers/pytorch_model_parser.c:175)
```

## D — Binary tick feed + LLM-written SDDL (`data/ticks/btcusdt.bin`, 65,600,016 B)

Source: 1.6M real Binance BTCUSDT trades (2026-07-28), packed as a binary feed:
16 B header (`TICK`, u32 version, i64 count) + 41 B records (i64 trade_id, f64 price,
f64 qty, f64 quote_qty, i64 ts_us, u8 flags).
Repro: `curl -sL https://data.binance.vision/data/spot/daily/trades/BTCUSDT/BTCUSDT-trades-2026-07-28.zip`

No OpenZL profile covers this format — this is the core product hypothesis: the LLM
writes the data description from a hexdump + format knowledge (zero-shot, one syntax
retry), OpenZL exploits it. Description: [`ticks.oldv1.sddl`](ticks.oldv1.sddl).

| Compressor | Size | Compress | Decompress | cmp |
|---|---|---|---|---|
| gzip -9 | 12.45 MB | slow | | |
| zstd -3 | 11,743,706 B | 0.08 s | | |
| zstd -19 -T0 | 9.21 MB | 12.1 s | | |
| **OpenZL + SDDL1** | **6,030,832 B** | **427 ms / 154 MB/s** | 78 ms / 837 MB/s | **ok** |
| OpenZL + SDDL2 port | 6,281,742 B | 308 ms / 213 MB/s | 41 ms / 1,604 MB/s | ok |

**PASS, decisively — 48.65% smaller than zstd -3 AND ~34.5% smaller than zstd -19, at
~28x zstd -19's speed.** The SDDL2 path costs 4.16% ratio and buys 1.9x faster
decompress — a backend trade-off, not a bug; prefer SDDL1 (`--profile sddl`) when ratio
matters.

---

## Findings that shaped the skill

### SDDL1 and SDDL2 are two different languages

Each has its own compiler and its own `zli` profile (split upstream in `4918a3b`, #726):

| | SDDL1 | SDDL2 |
|---|---|---|
| `zli` profile | `--profile sddl` | `--profile sddl2` |
| Standalone compiler | `build/tools/sddl/sddl_compiler` (stdin → stdout) | `build/tools/sddl2/sddl2_compiler` (`-i` / `-o`) |
| Record syntax | `Trade = { Int64LE … }` — positional, no field names, newline-separated | `record Trade() { price: Float64LE, … }` — named fields, comma-separated |
| Upstream example | `examples/sddl/sao_silesia.oldv1.sddl` | `examples/sddl2/sao_silesia.sddl` |

The syntax the public docs teach (`Record X() = {`, `var n =`) compiles under **neither**
compiler — it's a dead dialect. See [`ticks.sddl`](ticks.sddl) for a description written
in it (fails both compilers) vs [`ticks.oldv1.sddl`](ticks.oldv1.sddl) (SDDL1, works).
SDDL2's actual keyword set (`tools/sddl2/compiler/Syntax.cpp`): `record`, `when`,
`expect`, `sizeof`, `abs`, `between`, `@`, types `Byte`, `UInt8`/`Int8`,
`{U,}Int{16,32,64}{LE,BE}`, `Float{16,32,64}{LE,BE}`, `BFloat16{LE,BE}`, `Bytes` — and
no `var`. An LLM writing SDDL must be pinned to a shipped example at a known commit, not
the docs.

`sddl2`'s `--profile-arg` takes the description **source** file and compiles it
in-process — no separate `sddl2_compiler` step needed in the pipeline.

### There is no JSON profile

Full `zli list-profiles` output (v0.2.4):

```
csv, i8, u8, le-i16, le-i32, le-i64, le-u16, le-u32, le-u64,
numeric-ml-selector-64, parquet, pytorch, sao, sddl, sddl2, serial, zstd
```

### `--max-time-secs` is not a wall-clock limit

The ACE-successor training phase does not check the deadline. Measured with
`--max-time-secs 120`: csv training took **495 s** (4.1x budget — ~370 s of it cycling
"Training ACE graph 1..15 / 15" after the budget expired); serial took 146 s. The
process does exit 0 on its own, but the `.zlc` stays **0 bytes until training finishes**
— don't kill it early, and always check the `.zlc` size before trusting it.
Workaround: `--no-ace-successors` makes the budget roughly honest. Otherwise budget
4–5x for csv.

---

## Reproduce

```sh
ZLI=path/to/openzl/build/cli/zli
$ZLI train --profile csv    data/train_samples      -o nyc311.zlc    --max-time-secs 120 -f
$ZLI train --profile serial data/gharchive_samples  -o gharchive.zlc --max-time-secs 120 -f
$ZLI compress data/nyc311/nyc311.csv       -c nyc311.zlc     -o nyc311.zl    -f
$ZLI compress data/gharchive/events.jsonl  -c gharchive.zlc  -o gharchive.zl -f
$ZLI compress data/pytorch/resnet18.pth    --profile pytorch -o resnet18.zl  -f
$ZLI compress data/ticks/btcusdt.bin --profile sddl --profile-arg results/ticks.oldv1.sddl -o ticks.zl -f
```

Verify every round-trip: `zli decompress out.zl -o out.orig && cmp out.orig <input>`.
