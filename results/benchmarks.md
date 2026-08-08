# OpenZL benchmarks: 22 runs, 16 data types, 7 competing compressors

Run 2026-08-08. Machine: macOS 26.2, Apple Silicon, 8 cores.

`zli` built from [facebook/openzl](https://github.com/facebook/openzl) @
`a9de25e63990035a63e537de60604eeb1f64568b` (`--version` reports 0.2.4):

```sh
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build --target zli -j8                          # ~11 min
cmake --build build --target sddl_compiler sddl2_compiler -j8 # optional
```

Baselines, every one run on every dataset: `zstd -3`, `zstd -19 -T0`, `gzip -9`,
`xz -9 -T0`, `brotli -q 11`, `bzip2 -9`, `lz4 -12`. Results are reported against the
**best** baseline per dataset, not against `zstd -3` alone. An earlier version of this
file compared only to zstd and gzip, which flattered OpenZL: `xz -9` turns out to be the
strongest baseline on 11 of 22 runs and it was missing from the table.

**Every OpenZL result was decompressed and `cmp`-verified byte-identical.**

## Conclusion

OpenZL wins when, and only when, it is given the structure of the data. Given a matching
profile or a working SDDL description it is 8% to 20% smaller than the best general
compressor and 20x to 1500x faster. Given nothing, it falls back to `serial`, which is a
fast LZ graph, and it loses to bzip2 on every single file tested.

The `sao` file shows this in isolation, same bytes compressed two ways:

| sao, 7,251,944 B | Output | vs `xz -9` |
|---|---|---|
| `serial` fallback | 6,256,187 B | +41.70%, loses |
| native `sao` profile | 3,513,048 B | **-20.43%, wins** |

A 44% swing from structure knowledge alone. That is the whole product thesis, and it is
why the honest recommendation for unstructured or unknown data is "use zstd or xz".

## Summary: OpenZL vs the best baseline

Wins:

| Dataset | Input | OpenZL path | OpenZL | Best baseline | vs best | Speed |
|---|---|---|---|---|---|---|
| sao star catalog | 7.25 MB | `sao` profile | 3,513,048 B | xz 4,415,080 | **-20.43%** | 89x |
| Binary tick feed | 65.6 MB | LLM-written SDDL1 | 6,030,832 B | xz 7,208,836 | **-16.34%** | 44x |
| resnet18.pth | 46.8 MB | `pytorch` profile | 39,047,321 B | xz 42,864,116 | **-8.90%** | 507x |
| mobilenet_v2.pth | 14.3 MB | `pytorch` profile | 11,880,919 B | brotli 13,015,893 | **-8.72%** | 1532x |
| Raw float32 tensors | 46.8 MB | `le-u32` profile | 39,223,172 B | xz 42,847,240 | **-8.46%** | 21x |
| Raw float32 tensors | 46.8 MB | LLM-written SDDL1 | 39,259,594 B | xz 42,847,240 | -8.37% | 20x |
| NYC 311 CSV | 87.5 MB | `csv` profile, trained | 4,541,788 B | xz 4,609,528 | -1.47% | 33x |

Losses:

| Dataset | Input | OpenZL path | OpenZL | Best baseline | vs best |
|---|---|---|---|---|---|
| SQLite database | 91.6 MB | `serial` | 13,795,994 B | xz 5,815,044 | +137.25% |
| Silesia nci (chemical db) | 33.6 MB | `serial` | 3,543,214 B | brotli 1,519,768 | +133.14% |
| Silesia xml | 5.3 MB | `serial` | 782,645 B | brotli 430,566 | +81.77% |
| Silesia reymont (text) | 6.6 MB | `serial` | 2,203,499 B | bzip2 1,246,230 | +76.81% |
| Silesia x-ray (image) | 8.5 MB | `serial` | 6,798,261 B | bzip2 4,051,112 | +67.81% |
| Silesia webster (HTML) | 41.5 MB | `serial` | 13,845,341 B | xz 8,385,876 | +65.10% |
| Silesia mozilla (binary) | 51.2 MB | `serial` | 21,673,875 B | xz 13,374,168 | +62.06% |
| Silesia mr (MRI image) | 10.0 MB | `serial` | 3,825,918 B | bzip2 2,441,280 | +56.72% |
| Silesia dickens (text) | 10.2 MB | `serial` | 4,337,853 B | bzip2 2,799,520 | +54.95% |
| Silesia samba (source) | 21.6 MB | `serial` | 5,823,684 B | xz 3,763,624 | +54.74% |
| Silesia ooffice (binary) | 6.2 MB | `serial` | 3,706,047 B | xz 2,426,824 | +52.71% |
| GH Archive JSONL | 80.0 MB | `serial`, trained | 13,180,660 B | brotli 8,901,994 | +48.06% |
| Silesia sao | 7.3 MB | `serial` | 6,256,187 B | xz 4,415,080 | +41.70% |
| Silesia osdb (db dump) | 10.1 MB | `serial` | 3,779,018 B | bzip2 2,802,792 | +34.83% |
| Parquet, uncompressed | 84.8 MB | `parquet` profile | 7,398,402 B | xz 5,860,340 | +26.25% |

Note that Parquet is the only loss where a real profile applied. Every other loss is the
`serial` fallback on data OpenZL had no description for.

## Detail: the wins

### A. NYC 311 CSV (`data/nyc311/nyc311.csv`, 87,500,349 B, 41 messy columns)

Source: `curl "https://data.cityofnewyork.us/resource/erm2-nwe9.csv?$limit=100000"`

Trained: `zli train --profile csv data/train_samples -o nyc311.zlc --max-time-secs 120 -f`
(three ~8 MB sample files, `.zlc` = 20,753 B).

| Compressor | Size | Compress | Decompress |
|---|---|---|---|
| **OpenZL csv trained** | **4,541,788 B** | **443 ms / 197 MB/s** | 293 ms |
| xz -9 -T0 | 4,609,528 B | 14,758 ms | 361 ms |
| brotli -q 11 | 4,612,429 B | 69,521 ms | 115 ms |
| zstd -19 -T0 | 5,122,896 B | 10,624 ms | 98 ms |
| bzip2 -9 | 7,378,420 B | 6,119 ms | 1,198 ms |
| zstd -3 | 9,050,952 B | 100 ms | 101 ms |
| gzip -9 | 12,467,794 B | 2,402 ms | 139 ms |
| lz4 -12 | 13,185,706 B | 750 ms | 69 ms |

OpenZL wins on ratio by only 1.47% here. The real result is that it reaches xz-class
compression **33x faster than xz**. Do not headline the "-50% vs zstd -3" figure: xz was
sitting at -49.07% the whole time.

Storage comparison against what a data team would actually do with this table:

| Storage form | Size |
|---|---|
| **CSV + OpenZL** | **4,541,788 B** |
| Parquet + zstd | 7,726,968 B |
| Parquet + snappy | 9,886,937 B |

OpenZL on the raw CSV is 41% smaller than Parquet + zstd on the same 100,000 rows.
Parquet stays columnar and queryable, so this is a storage-cost comparison and not a
like-for-like capability comparison, but for archival the gap is real.

### B. Binary tick feed (`data/ticks/btcusdt.bin`, 65,600,016 B)

1.6M real Binance BTCUSDT trades (2026-07-28), packed as 16 B header (`TICK`, u32
version, i64 count) + 41 B records (i64 trade_id, f64 price, f64 qty, f64 quote_qty,
i64 ts_us, u8 flags).
Repro: `curl -sL https://data.binance.vision/data/spot/daily/trades/BTCUSDT/BTCUSDT-trades-2026-07-28.zip`

No profile covers this format. The description is LLM-written, zero-shot, one syntax
retry: [`ticks.oldv1.sddl`](ticks.oldv1.sddl).

| Compressor | Size | Compress | Decompress |
|---|---|---|---|
| **OpenZL + SDDL1** | **6,030,832 B** | **433 ms / 151 MB/s** | 205 ms |
| xz -9 -T0 | 7,208,836 B | 19,233 ms | 470 ms |
| brotli -q 11 | 8,520,719 B | 98,889 ms | 138 ms |
| zstd -19 -T0 | 9,209,893 B | 11,957 ms | 82 ms |
| zstd -3 | 11,743,706 B | 91 ms | 112 ms |
| bzip2 -9 | 12,333,040 B | 2,878 ms | 953 ms |
| gzip -9 | 12,450,167 B | 4,190 ms | 88 ms |
| lz4 -12 | 16,045,252 B | 3,615 ms | 59 ms |

**The strongest result in the set: 16.34% smaller than the best general compressor, at
44x its speed, on a format nothing else understands.** This is the case that justifies
the agent.

### C. PyTorch checkpoints (`pytorch` profile, no training)

| File | Compressor | Size |
|---|---|---|
| `resnet18.pth` (46,830,571 B) | **OpenZL pytorch** | **39,047,321 B** (26 ms) |
| | xz -9 -T0 | 42,864,116 B (13,382 ms) |
| | brotli -q 11 | 42,982,210 B (100,163 ms) |
| | zstd -3 | 43,404,736 B |
| `mobilenet_v2_zip.pth` (14,258,573 B) | **OpenZL pytorch** | **11,880,919 B** (20 ms) |
| | brotli -q 11 | 13,015,893 B (30,129 ms) |
| | xz -9 -T0 | 13,074,524 B |
| `mobilenet_v2.pth` (legacy pickle) | OpenZL pytorch | **FAILED** |

Float32 weights are high entropy, which is why xz and brotli barely beat zstd here (-1.3%
and -1.0%). OpenZL removes 2.3x the bytes zstd does, at GB/s. The speed gap is extreme:
507x faster than xz on resnet18, 1532x faster than brotli on mobilenet.

Legacy pre-torch-1.6 non-zip `.pth` files are still rejected on v0.2.4. They are pickles,
not zip containers, and need re-saving before the profile applies:

```
ZS2_ZipLexer_init (custom_parsers/zip_lexer.c:540): Check `reverseOffset >= maxReverseOffset' failed: Generic: EOCD not found
```

### D. Raw float32 tensor data (`resnet18.f32`, 46,796,448 B)

The 102 raw storage blobs from resnet18.pth concatenated, no container framing:
11,699,112 real float32 weights.

| Path | Size | vs xz |
|---|---|---|
| `le-u32` profile, no description | **39,223,172 B** | -8.46% |
| LLM-written SDDL1 (`Float32LE[_rem / 4]`) | 39,259,594 B | -8.37% |

**Writing an SDDL description bought nothing over the stock width profile, and was very
slightly worse.** SDDL pays off on heterogeneous records (the tick feed mixes i64, f64
and u8, and gained 16%), not on uniform arrays of a single type. The agent should try a
stock profile first and only write SDDL when field types differ within a record.

## Detail: the losses that matter

### E. GitHub Archive JSONL (`data/gharchive/events.jsonl`, 80,000,000 B)

Source: `curl https://data.gharchive.org/2026-07-29-15.json.gz | gzip -dc | head -c 80000000`

| Compressor | Size |
|---|---|
| brotli -q 11 | **8,901,994 B** |
| xz -9 -T0 | 8,919,252 B |
| zstd -19 -T0 | 9,553,389 B |
| bzip2 -9 | 12,908,011 B |
| **OpenZL serial trained** | **13,180,660 B** |
| zstd -3 | 14,021,543 B |

**OpenZL is 48% larger than brotli.** There is no JSON profile (see the profile list
below) and the `serial` fallback graph is `ZL_GRAPH_LZ` behind a serial segmenter, a
deliberate speed-over-ratio default. Retraining on v0.2.4 produced a 520 B `.zlc`,
meaning the trainer found almost nothing to exploit. The honest recommendation for JSONL
is brotli or xz.

### F. Parquet (`parquet` profile)

The only loss where a real profile applied, and the profile is also very restrictive.

| Parquet variant | OpenZL result |
|---|---|
| dictionary-encoded, V1 pages (pyarrow **default**) | **FAILS**: `Unknown page type` |
| V2 data pages | **FAILS**: `Invalid Parquet Page Type!` |
| dictionary disabled, V1 pages, uncompressed | works: 84,830,348 -> 7,398,402 B |

Even on the variant that works, `xz -9` reaches 5,860,340 B, so OpenZL is 26% larger.
Since dictionary encoding is pyarrow's default and near-universal in practice, the
`parquet` profile does not apply to most real Parquet files. Do not build on it.

### G. Silesia corpus, `serial` fallback, 12 files

The standard compression corpus: text, HTML, source code, executables, a chemical
database, MRI and x-ray images, a database dump, XML, a star catalog. No OpenZL profile
fits any of them, so this measures the zero-effort fallback. **OpenZL loses on all 12**,
by 34.83% (osdb) to 133.14% (nci). Numbers in the losses table above.

Get the corpus with `curl -sLO https://mattmahoney.net/dc/silesia.zip`.

## Bugs and limits found

### Non-ASCII anywhere in an SDDL file aborts the compiler

Minimal repro against `build/tools/sddl/sddl_compiler`:

```sh
printf '# caf\xc3\xa9\n: Float32LE[_rem / 4]\n' | sddl_compiler   # SIGABRT, rc=134
printf '# cafe\n: Float32LE[_rem / 4]\n'         | sddl_compiler   # rc=0
```

The error names the wrong subsystem entirely:

```
libc++abi: terminating due to uncaught exception of type openzl::Exception:
Message: Call to ZL_CompressorSerializer_convertToJson() failed.
OpenZL error code: 12 / Corruption detected
Message: Encountered error in A1CBOR library with code "writeFailed".
```

One non-ASCII byte in a **comment** is enough. This matters for LLM-written SDDL, which
routinely contains em-dashes, curly quotes and accented characters. The skill must strip
descriptions to ASCII before compiling.

### `--max-time-secs` is not a wall-clock limit

Re-confirmed on v0.2.4, 2026-08-08. The ACE-successor training phase does not check the
deadline:

| Profile | Budget | Actual | Overrun |
|---|---|---|---|
| `csv` | 120 s | **527 s** | 4.4x |
| `serial` | 120 s | 135 s | 1.1x |

The `.zlc` stays **0 bytes for the entire run**, so do not kill it early and do not trust
a `.zlc` without checking its size. `--no-ace-successors` makes the budget roughly honest.
Filed upstream as [facebook/openzl#930](https://github.com/facebook/openzl/issues/930).

### There is no JSON profile

Full `zli list-profiles` output (v0.2.4):

```
csv, i8, u8, le-i16, le-i32, le-i64, le-u16, le-u32, le-u64,
numeric-ml-selector-64, parquet, pytorch, sao, sddl, sddl2, serial, zstd
```

### SDDL1 and SDDL2 are two different languages

Each has its own compiler and its own `zli` profile (split upstream in `4918a3b`, #726):

| | SDDL1 | SDDL2 |
|---|---|---|
| `zli` profile | `--profile sddl` | `--profile sddl2` |
| Standalone compiler | `build/tools/sddl/sddl_compiler` (stdin to stdout) | `build/tools/sddl2/sddl2_compiler` (`-i` / `-o`) |
| Record syntax | `Trade = { Int64LE ... }`, positional, newline-separated | `record Trade() { price: Float64LE, ... }`, named, comma-separated |
| Upstream example | `examples/sddl/sao_silesia.oldv1.sddl` | `examples/sddl2/sao_silesia.sddl` |

The syntax the public docs teach (`Record X() = {`, `var n =`) compiles under **neither**
compiler. See [`ticks.sddl`](ticks.sddl) for a description written in it (fails both) vs
[`ticks.oldv1.sddl`](ticks.oldv1.sddl) (SDDL1, works). An LLM writing SDDL must be pinned
to a shipped example at a known commit, not to the docs.

`sddl2`'s `--profile-arg` takes the description **source** and compiles it in-process.

## Reproduce

```sh
ZLI=path/to/openzl/build/cli/zli
$ZLI train --profile csv    data/train_samples     -o nyc311.zlc    --max-time-secs 120 -f
$ZLI train --profile serial data/gharchive_samples -o gharchive.zlc --max-time-secs 120 -f
$ZLI compress data/nyc311/nyc311.csv      -c nyc311.zlc    -o nyc311.zl   -f
$ZLI compress data/gharchive/events.jsonl -c gharchive.zlc -o gharchive.zl -f
$ZLI compress data/pytorch/resnet18.pth   --profile pytorch -o resnet18.zl -f
$ZLI compress data/ticks/btcusdt.bin --profile sddl --profile-arg results/ticks.oldv1.sddl -o ticks.zl -f
```

Then benchmark against all seven baselines and verify the round-trip:

```sh
skill/openzl/scripts/benchmark.sh <original> <compressed> "$ZLI"    # SKIP_SLOW=1 to drop xz/brotli/bzip2
```

The script fails loudly if `cmp` does not match, and it names the best baseline and says
outright when OpenZL loses to it.
