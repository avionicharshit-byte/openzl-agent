---
name: openzl
description: >-
  Compress structured data with OpenZL (Meta's format-aware compressor) to cut storage
  costs, and prove the savings with a benchmark. Use when the user wants to compress a
  file or directory, reduce storage/S3/data-lake costs, asks "what would this save me",
  asks how to shrink logs/exports/datasets/checkpoints, or mentions OpenZL, zli, .zlc,
  .zl, or SDDL. Applies to CSV/TSV exports, Parquet, JSON/JSONL logs and event streams,
  PyTorch checkpoints (.pth/.pt), time-series and tick data, embeddings, and unknown or
  proprietary binary formats. Handles locating or building zli, choosing a profile,
  training a compressor, writing an SDDL data description for binary formats,
  round-trip verification, and a savings report versus zstd and gzip.
---

# OpenZL compression expert

OpenZL decomposes structured data into typed streams and compresses each with a
specialised codec. On well-described data it beats `zstd -3` by ~50%. On data it cannot
model it is barely better than zstd, and sometimes worse.

**Your job is to find out which case the user is in, and to prove it with numbers.**
Never report a saving you have not measured, and never report one whose round-trip you
have not `cmp`-verified.

Two rules that override everything else:

1. **Always compress with `--strict`.** Without it, a failed parser silently falls back to
   generic compression, prints a normal success line, and exits 0. You will report a fake
   win. (Verified on 0.2.4.)
2. **Always `zli decompress` + `cmp` before reporting.** No exceptions.

Reference files (read them when you reach the relevant step, not upfront):
- `references/zli-cheatsheet.md` — verified flags, v0.1 vs v0.2.4 differences, training bugs
- `references/sddl1-guide.md` — SDDL1 dialect (best ratio) — **the docs are wrong, use this**
- `references/sddl2-guide.md` — SDDL2 dialect (faster decompress) — likewise
- `scripts/detect_zli.sh`, `scripts/benchmark.sh`

---

## Step 0 — Locate `zli`

```sh
eval "$(scripts/detect_zli.sh | grep -E '^(ZLI|SDDL2?_COMPILER)=')"
```

`detect_zli.sh` checks `$ZLI`, `PATH`, then `~/Documents/*/openzl*/build/cli/zli`,
`./build/cli/zli` and friends. It prints `ZLI=`, `ZLI_VERSION=`, `ZLI_PROFILES=`, and
`SDDL_COMPILER=` / `SDDL2_COMPILER=` when those optional tools are built; exits 1 with build
instructions otherwise. Use `"$ZLI"` everywhere after.

If not found, offer to build it and **ask before starting** — it takes ~11 minutes:

```sh
git clone https://github.com/facebook/openzl.git && cd openzl
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build --target zli -j"$(getconf _NPROCESSORS_ONLN)"
cmake --build build --target sddl_compiler sddl2_compiler -j4   # optional, for SDDL work
```

Version matters. `0.2.4`+ is the target. If you find `0.1`, read the version table in
`references/zli-cheatsheet.md` before writing any command — flags differ
(`--chunk-size-mb` vs `--chunk-size`), `--strict` does not exist, and SDDL2 is unusable.

**Note: `zli` writes its output — including `list-profiles` and the `Compressed ...`
summary — to stderr.** Use `2>&1` when parsing.

---

## Step 1 — Identify the data and route it

```sh
file DATA; ls -l DATA; head -c 400 DATA | xxd | head -20
```

For a directory, sample it: check that all files really share one format before treating
them as one dataset.

| Input | Route | Expect (see numbers below) |
|---|---|---|
| CSV / TSV | `--profile csv`, **train** | **Best case: ~50% smaller than zstd -3** |
| Parquet | `--profile parquet`, only if canonical/uncompressed | varies |
| `.pth` / `.pt` | `--profile pytorch`, **no training** | ~10% vs zstd -3, but at GB/s |
| JSON / JSONL | `--profile serial`, train — **be honest, it is weak** | ~6% vs zstd -3, loses to zstd -19 |
| Unknown binary, **mixed** field types per record | **SDDL** → Step 3 | -16% vs the best baseline on our tick data |
| Uniform array of one numeric type (embeddings, raw tensors, `le-*` shaped) | **stock `le-i32`/`le-u32`/`le-u64`/... first**, SDDL only if that disappoints | -8.5% vs the best baseline |
| Text, logs, source, executables, images, generic files | **do not use OpenZL**, recommend `zstd` or `xz` | OpenZL loses on all 12 Silesia files |

Routing details:

- **TSV / other separator**: `--profile csv --profile-arg $'\t'`.
- **Parquet**: the profile only handles *canonical* Parquet (plain encoding, uncompressed
  pages). If pages are snappy/zstd/gzip-compressed internally, OpenZL cannot see the structure
  — tell the user to re-export uncompressed, or skip Parquet. Check the codec (needs
  `pyarrow`; if the import fails, say so rather than guessing):

  ```sh
  python3 -c "import pyarrow.parquet as pq,sys
  m=pq.ParquetFile(sys.argv[1]).metadata
  print({m.row_group(g).column(c).compression
         for g in range(m.num_row_groups) for c in range(m.num_columns)})" f.parquet
  ```

  `{'UNCOMPRESSED'}` → necessary but **not sufficient**. The lexer also rejects
  dictionary-encoded pages (`Unknown page type`) and V2 data pages
  (`Invalid Parquet Page Type!`), and **dictionary encoding is pyarrow's default**, so most
  real Parquet files fail even when uncompressed. Only this combination works:

  ```python
  pq.write_table(t, "out.parquet", compression="none",
                 use_dictionary=False, version="1.0", data_page_version="1.0")
  ```

  Measured 2026-08-08: even on that variant OpenZL lost to `xz -9` by 26%. **Treat Parquet
  as unsupported in practice.** If the user's data started as CSV, the `csv` path is the
  better answer anyway: it beat Parquet + zstd on identical rows by 41%.
- **`.pth`/`.pt`**: you **must** check the container format first —

  ```sh
  python3 -c "import zipfile,sys; print(zipfile.is_zipfile(sys.argv[1]))" model.pth
  ```

  `True` (modern, torch ≥1.6, starts `PK\x03\x04`) → `--profile pytorch` works.
  `False` (legacy pickle, starts `\x80\x02`) → **zli fails**:
  `Check 'reverseOffset >= maxReverseOffset' failed: Generic: EOCD not found`.
  Explain that it is a pre-1.6 pickle checkpoint, not a zip, and offer the conversion:

  ```python
  import torch
  sd = torch.load("old.pth", map_location="cpu", weights_only=False)
  torch.save(sd, "new.pth")   # torch >=1.6 writes the zip format
  ```

  Set expectations honestly: model weights are high-entropy floats, so the *ratio* looks
  unimpressive (~1.20x) — but OpenZL removes **~2.3x as many bytes as `zstd -3`** and does
  it at ~1.8 GB/s compress, ~2.4 GB/s decompress. Frame it as bytes saved and speed, not
  ratio. Training is not supported for this profile.
- **JSON / JSONL**: **there is no JSON profile** (verified against the full 0.2.4 profile
  list). Trained `serial` is the best available and it is mediocre. Say so upfront, offer it
  with the caveat that **`zstd -19` beats it** on our data, and note the real fix is to
  columnarise (JSONL → CSV/Parquet by field) and take the `csv` path, where the win lives.
- **No exploitable structure**: if the data is prose, logs, source code, executables, images,
  or any format with no matching profile and no fixed record layout, **say so and recommend
  `zstd -19` or `xz -9` instead**. Measured 2026-08-08 on the full Silesia corpus: with the
  `serial` fallback OpenZL lost on all 12 files, by 35% to 133%, including to `bzip2`.
  OpenZL's win comes entirely from structure knowledge, so with none available there is
  nothing to win. Recommending against the tool here is correct, not a failure.
- **Already-compressed input** (`.gz`, `.zst`, `.jpg`, `.mp4`, Parquet with compressed pages):
  decompress first or there is nothing to win. Say so rather than benchmarking pointlessly.
- **> 2 GB single file**: known limit (chunking was WIP at launch). Warn, and suggest sharding
  or an explicit `--chunk-size`.

---

## Step 2 — Train (profile-based formats)

Training is where CSV gets its ~50%. It is optional but almost always worth it.

`zli train` takes a **sample directory** as a positional argument — not a file.

**One dataset per directory. Never mix formats or unrelated schemas in one sample dir** —
the trainer will fit a compromise graph that is good at nothing.

### Building samples from one big file

Use ~3 samples of 5–10 MB drawn from **different regions** of the file, so the trainer sees
schema drift and value-range drift rather than one contiguous slab.

Text (CSV/JSONL) — **verify record boundaries before slicing.** CSV allows newlines inside
quoted fields; on such files every `head`/`sed`/`tail` line slice cuts mid-record. Nothing
errors — training just fits corrupted samples and quietly produces a worse compressor. So
first compare physical lines against parsed records (expect records = lines − 1 header):

```sh
wc -l < big.csv
python3 -c 'import csv,sys; csv.field_size_limit(10**9); print(sum(1 for _ in csv.reader(open(sys.argv[1],newline=""))))' big.csv
```

Only if they agree is line-based slicing safe:

```sh
mkdir -p /tmp/samples
TOTAL=$(wc -l < big.csv | tr -d ' ')
BYTES=$(wc -c < big.csv | tr -d ' ')
AVG=$(( BYTES / TOTAL ))            # average bytes per row
N=$(( 8000000 / AVG ))              # rows per sample, targeting ~8 MB
head -1 big.csv > /tmp/hdr          # keep the CSV header on every sample
{ cat /tmp/hdr; sed -n "2,$((N+1))p"                     big.csv; } > /tmp/samples/s1.csv
{ cat /tmp/hdr; sed -n "$((TOTAL/2)),$((TOTAL/2+N))p"    big.csv; } > /tmp/samples/s2.csv
{ cat /tmp/hdr; tail -n "$N"                             big.csv; } > /tmp/samples/s3.csv
ls -l /tmp/samples/                 # confirm ~8 MB each, not 50
```

Derive the row count from a byte budget rather than hard-coding it — row sizes vary wildly
between datasets, and a fixed line count silently produces 50 MB samples on wide tables.

If lines ≠ records, do **not** line-slice. Find record boundaries with a quote-aware scan
(a newline is a boundary only outside quotes — track quote parity) and copy the **original
bytes** between boundary offsets. Don't re-serialize rows through a CSV writer: it changes
quoting style, so the trainer fits samples that don't look like the real file. Field-tested:
a 72 MB municipal CSV with 250k records across 750k physical lines trained to −53.9% vs
`zstd -3` from byte-offset samples, after line slicing had visibly broken records.

Binary — cut at **exact multiples of the record size**, never arbitrary byte offsets:

```sh
REC=41; HDR=16; N=200000
dd if=big.bin of=/tmp/samples/s1.bin bs=1 skip=$HDR count=$((REC*N)) 2>/dev/null
```

### Run it

```sh
"$ZLI" train --profile csv /tmp/samples -o trained.zlc --max-time-secs 120 -f
```

**`--max-time-secs` is not a wall-clock guarantee.** The ACE-successor phase ignores the
deadline. Measured on 0.2.4 @ a9de25e with a 120 s budget: CSV took **504 s** (4.2x), serial
146 s (1.2x). Exit code is 0 either way.

- Default to `--max-time-secs 120` and **warn the user that wall time may be ~4x the budget**
  on CSV. Do not silently block for 8 minutes without having said so.
- If the user needs a hard budget, add `--no-ace-successors`. The budget then holds (measured:
  60 s budget → 49 s wall) but it **costs real ratio**: on our CSV, `--no-ace-successors` gave
  −40.90% vs `zstd -3` where the full run gave −49.74%. Roughly 9 points of savings for ~10x
  less CPU time. Offer the choice rather than picking silently.

**Do not kill a v0.2.4 training run early.** It writes the `.zlc` only at the end; the file
is legitimately 0 bytes for the entire run. (v0.1 wrote a usable best-so-far snapshot
mid-run; v0.2.4 does not.)

**Always size-check the result** — a 0-byte `.zlc` means failure *regardless of exit code*:

```sh
[ -s trained.zlc ] || { echo "training failed: 0-byte compressor"; exit 1; }
```

Defaults: 150 MiB max per file, 300 MiB max total, `greedy` trainer, all cores. Override with
`--max-file-size-mb`, `--max-total-size-mb`, `--trainer`, `--threads`.

Dictionary training is **opt-in** on v0.2.4 via `--dict-bundle-output/-O`. Worth suggesting
when samples are small or repetitive — but the `.zd` bundle is then required at decompress
time too, forfeiting the "any zli can decompress it" property. Say so rather than enabling it
silently.

**If the user's `zli` is newer than 0.2.4, check for `zli train --format-version`.** It landed
upstream after `a9de25e` and defaults to the maximum supported format version. Two consequences
worth checking before you trust a trained compressor from a newer build: frames may target a
format version an older decompressor refuses, and a trainer that cannot meet the target version
is **silently fallen back to zstd**, which yields a valid non-empty `.zlc` that is just zstd.
Neither is caught by the size check above. Compare the achieved ratio against the benchmark
table at the end of this file. Details in `references/zli-cheatsheet.md`.

Then compress with the trained compressor:

```sh
"$ZLI" compress big.csv -c trained.zlc -o big.zl -f
```

(`--train-inline` trains and compresses in one shot; fine for a quick look, but you cannot
reuse the compressor — prefer the two-step form for anything real.)

---

## Step 3 — SDDL for unknown binary formats

This is where OpenZL earns its keep: a hand-written description of a proprietary record
format got us **16% smaller than `xz -9`**, the best of seven general compressors, at 44x
its speed.

**First check whether you need SDDL at all.** It pays off on records whose fields have
*differing* types (the tick feed mixes `Int64LE`, `Float64LE` and `Byte`). On a uniform
array of a single numeric type it buys nothing: measured 2026-08-08 on 46.8 MB of raw
float32 tensor data, a hand-written `Float32LE[_rem / 4]` description scored -8.37% vs
`xz -9` while the stock `--profile le-u32` scored **-8.46%** for zero work. Try the stock
width profile first and only write SDDL if it disappoints.

### Inspect

```sh
xxd data.bin | head -40      # magic bytes? version? a count in the first 16-32 bytes?
ls -l data.bin               # exact size
```

Hypothesise a header size and a fixed record size, then **test the hypothesis**:

```sh
python3 -c "print((SIZE - HDR) % REC)"   # must be 0
```

Look for repeating column structure in the hex dump — IEEE-754 doubles in a narrow range
share their high bytes, which is very visible. Note field alignment and endianness.

### Pick a dialect

Two dialects exist, with **opposite syntax rules**, and this is documented nowhere public:

- **SDDL1** (`--profile sddl`) — best ratio. Members newline-separated, **no commas**.
  *Default choice.*
- **SDDL2** (`--profile sddl2`) — ~4% worse ratio, ~2x faster decompress, v0.2.4+ only.
  Members **comma-separated**. Takes the description source directly.

**The public docs and `openzl.org/sddl/` are stale and compile under neither dialect**
(e.g. `Record X() = { ... }` and `var n = ...` are both dead). **Never write SDDL from the
published docs or from memory.** Read `references/sddl1-guide.md` or
`references/sddl2-guide.md` and pattern-match the worked examples there.

### Workflow

```sh
# 0. MANDATORY: strip the description to ASCII before anything touches it.
#    One non-ASCII byte ANYWHERE, comments included, aborts the compiler (see below).
LC_ALL=C tr -d '\200-\377' < desc.sddl > desc.ascii.sddl && mv desc.ascii.sddl desc.sddl
LC_ALL=C grep -n '[^ -~   ]' desc.sddl && echo "STILL NON-ASCII, fix before continuing"

# 1. syntax check (optional but fast). The compilers are NOT on PATH -- they sit in the
#    same build tree as zli, and detect_zli.sh emits SDDL_COMPILER= / SDDL2_COMPILER=.
"$SDDL_COMPILER"  < desc.sddl > /dev/null        # SDDL1: stdin -> stdout
"$SDDL2_COMPILER" -i desc.sddl2 -o /dev/null     # SDDL2: -i / -o

# 2. compress -- --strict is MANDATORY here
"$ZLI" compress data.bin --profile sddl --profile-arg desc.sddl -o data.zl -f --strict

# 3. MANDATORY round-trip
"$ZLI" decompress data.zl -o data.out -f && cmp data.bin data.out

# 4. benchmark
scripts/benchmark.sh data.bin data.zl "$ZLI"
```

A clean SDDL1 syntax check proves almost nothing: **the SDDL1 compiler accepts type names
that do not exist** (`: Bogus123` exits 0) and they fail only at runtime. SDDL2's compiler
does catch them. This is exactly why `--strict` and `cmp` are non-negotiable.

**Non-ASCII bytes abort the compiler with a misleading error.** You are an LLM writing this
file, so you will emit em-dashes, curly quotes and accented characters in comments by habit.
One of them is enough to kill the run. Minimal repro, verified on v0.2.4 2026-08-08:

```sh
printf '# caf\xc3\xa9\n: Float32LE[_rem / 4]\n' | "$SDDL_COMPILER"   # SIGABRT, rc=134
printf '# cafe\n: Float32LE[_rem / 4]\n'         | "$SDDL_COMPILER"   # rc=0
```

The error blames CBOR serialization and says nothing about encoding:

```
libc++abi: terminating due to uncaught exception of type openzl::Exception:
Message: Call to ZL_CompressorSerializer_convertToJson() failed.
OpenZL error code: 12 / Corruption detected
Message: Encountered error in A1CBOR library with code "writeFailed".
```

If you see that error, **the cause is almost certainly a non-ASCII byte, not corruption**.
Write descriptions in plain ASCII and run step 0 above regardless.

### If the ratio disappoints

Almost always a **typing** problem, not a structural one. A `f64` column typed as `Byte[8]`
kills the win — the transform sees opaque bytes instead of numbers. Check endianness, type
timestamps/IDs as `Int64LE` so they delta-encode, and split unrelated columns into separate
field instances. See the checklist at the end of `references/sddl1-guide.md`.

---

## Step 4 — Benchmark. Never assume, always measure

OpenZL's own docs admit default profiles sometimes lose to zip/flac. Measure every time.

```sh
scripts/benchmark.sh ORIGINAL_FILE OPENZL_FILE "$ZLI"
```

Runs **seven** baselines into a temp dir (auto-cleaned): `zstd -3`, `zstd -19 -T0`, `gzip -9`,
`xz -9 -T0`, `brotli -q 11`, `bzip2 -9`, `lz4 -12`. Missing binaries are skipped with a
warning. It times everything, decompresses the OpenZL file, `cmp`-verifies it, prints a
markdown table, and ends with the **best baseline and OpenZL's margin over it**, stating
outright when OpenZL loses. It **exits nonzero if the round-trip fails**, so report the
failure, not the savings.

`SKIP_SLOW=1` drops `xz`/`brotli`/`bzip2` when the input is large. `brotli -q 11` runs at
roughly 0.5 to 1.3 MB/s, so budget minutes per 100 MB.

**Report against the best baseline, never against `zstd -3` alone.** `zstd -3` is what the
user runs today, so lead with it, but `xz -9` was the strongest competitor on 11 of 22
datasets measured 2026-08-08 and it is the first thing a reader will ask about. On the CSV
case the margin over `zstd -3` is 50% and the margin over `xz -9` is 1.5%: quoting only the
first is how you lose the argument in public. When OpenZL wins mainly on speed, say that
plainly, and give the multiple.

---

## Step 5 — Deliver

Hand back:

1. **The artifacts**: `trained.zlc` and/or the `.sddl` description, saved somewhere durable,
   plus the compressed `.zl`.
2. **The decompression command their SREs will need.** Lead with this — it is the objection
   you will get:

   ```sh
   zli decompress data.zl -o data.out
   ```

   **No `.zlc` and no `.sddl` are required to decompress.** The `.zl` frame is
   self-describing; any recent `zli` reads it. This is OpenZL's no-lock-in property — state it
   explicitly. (Exception: with `--dict-bundle-output`, the `.zd` *is* needed to decompress.)
3. **The benchmark table** from Step 4, with the round-trip verification noted.
4. **A monthly savings estimate**, if the user gives you a volume. Use the measured ratio:

   > At 40 TB/month of this CSV, `zstd -3` stores ~10.3 TB; OpenZL stores ~5.2 TB —
   > about **5.1 TB/month less**, ~62 TB/year.

   Only extrapolate from data you actually measured, and say what you measured it on
   (e.g. "measured on an 87 MB sample of the same export").
5. **The honest caveat**, when it applies: JSONL loses to `brotli` and `xz` by ~48%;
   checkpoints win on bytes and speed but not on ratio; CSV beats `xz` by only ~1.5% on ratio
   and wins on speed instead; training costs minutes of CPU and overruns its stated budget by
   4x. Users trust the win more when you name the losses. If the data has no exploitable
   structure, the correct deliverable is "use `zstd` or `xz`", not a marginal OpenZL result.

---

## Reference numbers

Benchmarked 2026-08-08, `zli` 0.2.4 @ `a9de25e`, Apple Silicon (8 cores), 22 runs across 16
data types against all seven baselines. All round-trip `cmp`-verified byte-identical. Full
tables in `results/benchmarks.md`. Use these to set expectations, **not** as a substitute for
measuring the user's own data.

Wins, measured against the *best* of the seven baselines:

| Dataset | Size | Path | OpenZL | vs best baseline | Speed |
|---|---|---|---|---|---|
| sao star catalog | 7.3 MB | `sao` profile | 3,513,048 B | **-20.43%** (xz) | 89x |
| Binary tick feed | 65.6 MB | SDDL1 | 6,030,832 B | **-16.34%** (xz) | 44x |
| resnet18.pth | 46.8 MB | `pytorch` | 39,047,321 B | -8.90% (xz) | 507x |
| Raw float32 tensors | 46.8 MB | `le-u32` | 39,223,172 B | -8.46% (xz) | 21x |
| NYC 311 CSV | 87.5 MB | `csv`, trained | 4,541,788 B | -1.47% (xz) | 33x |

Losses, all of which must be reported honestly:

| Dataset | Path | vs best baseline |
|---|---|---|
| SQLite database | `serial` | +137% (xz) |
| GH Archive JSONL | `serial`, trained | +48% (brotli) |
| Parquet, uncompressed | `parquet` profile | +26% (xz) |
| Silesia corpus, all 12 files | `serial` | +35% to +133% |

**The rule that explains every one of these results:** OpenZL wins when it is given the
structure of the data and loses when it is not. Same `sao` file, `serial` fallback gives
6,256,187 B (loses to xz by 42%), native profile gives 3,513,048 B (beats xz by 20%). A 44%
swing from structure knowledge alone. So: describe the structure, or recommend another tool.

**Training is stochastic.** Independent retrains of the CSV case produced 4,521,797 B,
4,541,788 B and 4,548,794 B. Expect roughly +/-0.5 points run to run, and quote the user the
number *you* measured, not this table.
