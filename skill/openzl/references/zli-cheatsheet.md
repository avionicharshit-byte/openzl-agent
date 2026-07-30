# `zli` cheat sheet — verified command syntax

All commands below were executed against real binaries on 2026-07-31, Apple Silicon (8 cores):

- **NEW / primary target**: `zli` **0.2.4**, built from `facebook/openzl` @ `a9de25e`
  (`Demo CLI for OpenZL. Version 0.2.4`)
- **OLD / compat**: `zli` **0.1** (`zstrong-cli version 0.1`), ~515 commits behind

`zli` prints `NO VERSION STABILITY IS IMPLIED!!` in its own help. Treat every flag as
version-dependent and probe before relying on it.

---

## Gotcha #0: zli writes almost everything to stderr

`list-profiles`, the compression summary line (`Compressed X -> Y ...`), the decompression
summary, progress bars and errors all go to **stderr**. `zli list-profiles 2>/dev/null`
prints nothing. Any script that parses zli output must use `2>&1`.

```sh
zli list-profiles 2>&1 | sed -n 's/^[[:space:]]*-|[[:space:]]*\([A-Za-z0-9_-]*\).*/\1/p'
```

## Gotcha #1: a broken description or parser SILENTLY FALLS BACK

By default a profile that fails to parse its input does **not** fail the command. zli logs a
`Converted to warning` / `Forwarding error` trace, falls back to generic compression, prints a
normal `Compressed ...` line, and **exits 0**. Verified: an SDDL description using a
non-existent type produced `Compressed 100 -> 120 (0.83x)` and exit 0.

**Always pass `--strict` when compressing with `sddl`, `sddl2`, `parquet` or `pytorch`.**

```sh
zli compress in.bin --profile sddl --profile-arg d.sddl -o out.zl -f --strict
```

Verified: same broken description with `--strict` → **exit 1**. Good description with
`--strict` → exit 0, `Compressed 65600016 -> 6030832 (10.88x)`.

---

## Version differences (verified both ways)

| | v0.1 | v0.2.4 |
|---|---|---|
| Chunk size flag | `--chunk-size-mb 20` | `--chunk-size 20M` |
| Other flag | `--chunk-size` → `Unknown option` | `--chunk-size-mb` → `Unknown option` |
| Version flag | `--version` only (`-V` → `Error parsing arguments`) | `--version` or `-V` |
| `sddl2` `--profile-arg` | pre-compiled **bytecode** | **description source** (compiled in-process) |
| `sddl2` dialect | `Record X() = { }` (dead dialect) | `record X() { }` |
| Dictionary training | n/a | opt-in via `--dict-bundle-output` / `-O` |
| Trainer writes .zlc mid-run | **yes** (best-so-far snapshot usable) | **no** (0 bytes until done) |
| Trainer exits on its own | no (had to be killed) | yes, exit 0 |
| Training progress output | none | progress bar + `Training ACE graph N / M` |
| `--strict` on `compress` | not available | available |

`--chunk-size` suffixes (v0.2.4): `K/KB`=10^3, `M/MB`=10^6, `G/GB`=10^9, `T/TB`=10^12, plus
binary `KiB/MiB/GiB/TiB`. Bare numbers = bytes.

### v0.2.4 flags that do not exist in v0.1
`compress`: `--strict`, `--dict-bundle/-D`, `--store-on-expansion`, `--no-store-on-expansion`,
`--no-stream-preview`.
`train`: `--dict-bundle-output/-O`, `--save-ace-state`.
Global: `--chunk-size`, `-V`.

### v0.1 flags that do not exist in v0.2.4
Global: `--chunk-size-mb`.

---

## Profiles

**v0.2.4** (`zli list-profiles 2>&1`):

```
csv, i8, u8, le-i16, le-i32, le-i64, le-u16, le-u32, le-u64,
numeric-ml-selector-64, parquet, pytorch, sao, sddl, sddl2, serial, zstd
```

**v0.1**:

```
csv, le-i16, le-i32, le-i64, le-u16, le-u32, le-u64,
parquet, pytorch, sao, sddl, sddl2, serial
```

Added in 0.2.4: `i8`, `u8`, `numeric-ml-selector-64` (described upstream as "Placeholder"),
`zstd` ("Use this profile to train a Zstd dict").

**There is no JSON or JSONL profile in either version.** Confirmed against the full profile
list on 0.2.4 @ a9de25e. JSON-shaped data has to go through `serial`.

Profile notes from `list-profiles` output:
- `csv` — "Pass optional non-comma separator with `--profile-arg <char>`" (e.g. `--profile-arg $'\t'`)
- `parquet` — "Parquet in the canonical format (no compression, plain encoding)"
- `pytorch` — "Pytorch model generated from torch.save(). **Training is not supported.**"
- `sddl` / `sddl2` — "Pass a path to the ... file with `--profile-arg`"

---

## compress / decompress

```sh
# with a profile
zli compress data.csv --profile csv -o data.zl -f --strict

# with a trained compressor
zli compress data.csv -c trained.zlc -o data.zl -f

# train and compress in one shot
zli compress data.csv --profile csv --train-inline -o data.zl -f

# SDDL (both dialects; v0.2.4 takes source for either)
zli compress ticks.bin --profile sddl  --profile-arg desc.sddl  -o t.zl -f --strict
zli compress ticks.bin --profile sddl2 --profile-arg desc.sddl2 -o t.zl -f --strict

# universal decompressor: needs NO .zlc and NO description
zli decompress data.zl -o data.out -f
cmp data.csv data.out
```

The `.zl` frame is self-describing. The `.zlc` compressor and the `.sddl` description are
**compression-side only** — anyone with any recent `zli` can decompress. This is OpenZL's
"no lock-in" property and is the single most reassuring thing to tell an SRE.

---

## train

```sh
zli train --profile csv <SAMPLE_DIR> -o trained.zlc --max-time-secs 120 -f
```

`sample-dir` is a **positional directory**, not a file. One dataset per directory — never mix
formats or unrelated schemas in one sample dir.

Defaults (from `--help`): `--max-file-size-mb` 150MiB, `--max-total-size-mb` 300MiB,
trainer `greedy`, threads = hardware concurrency.
(Upstream help is internally inconsistent: `--num-samples` describes the file-size limit as
500Mb while `--max-file-size-mb` says 150MiB. Pass the flag explicitly if it matters.)

Useful flags: `--trainer full-split|greedy|bottom-up`, `--threads N`, `--num-samples N`,
`--use-all-samples`, `--no-clustering`, `--pareto-frontier`.

### The `--max-time-secs` overrun bug (reproduced on 0.2.4 @ a9de25e)

`--max-time-secs` is **not a wall-clock guarantee**. The ACE-successor training phase does not
check the deadline, so it runs to completion after the budget expires.

| Run (budget 120 s) | Wall | Overrun |
|---|---|---|
| `--profile csv`, 25 MB samples | **495 s** | 4.1x |
| `--profile serial`, 26 MB samples | **146 s** | 1.2x |

The csv run spent ~370 s of its 495 s cycling `Training ACE graph 1..15 / 15` after the budget
had expired. Re-confirmed 2026-07-31: mid-run the `.zlc` was still 0 bytes with the log at
`Training ACE graph 2 / 15`.

Re-measured 2026-07-31: `--profile csv`, 25 MB samples, budget 120 s → **504 s wall (4.2x)**,
exit 0, `.zlc` 19,954 B, "Training improved compression ratio by 88.01%".

**Guidance:** default to `--max-time-secs 120` and warn the user wall time can be ~4x that on
CSV. If a hard budget is required, add `--no-ace-successors`.

### The `--no-ace-successors` trade-off (measured)

| Run | Budget | Wall | Result on 87.5 MB CSV | vs `zstd -3` |
|---|---|---|---|---|
| default (ACE on) | 120 s | 504 s (4.2x) | 4,548,794 B | **−49.74%** |
| `--no-ace-successors` | 60 s | 49 s (holds) | 5,348,979 B | −40.90% |

~9 points of savings for ~10x less CPU. Present this as a choice; do not pick silently.

### Always size-check the output

```sh
[ -s trained.zlc ] || { echo "training produced a 0-byte compressor"; exit 1; }
```

A 0-byte `.zlc` means failure **regardless of exit code**. On v0.2.4 the file is legitimately
0 bytes for the whole run and only written at the end — so **do not kill a v0.2.4 training run
early**, you get nothing. On v0.1 the file is a usable best-so-far snapshot mid-run.

### Dictionary training (v0.2.4 only, opt-in)

Without `-O` no dictionary is trained and a standalone compressor is produced. With it, the
compressor references dictionaries in the bundle, and **the bundle must be supplied at both
compress and decompress time**:

```sh
zli train --profile csv samples/ -o t.zlc -O t.zd --max-time-secs 120 -f
zli compress   data.csv -c t.zlc -D t.zd -o data.zl -f
zli decompress data.zl  -D t.zd  -o data.out -f
```

Worth trying when samples are small or highly repetitive. Note it forfeits the
"decompress with a bare zli" property — mention that trade-off to the user.

---

## Other commands

```sh
zli benchmark <INPUT_DIR> -c trained.zlc -n 5     # input is a DIRECTORY
zli inspect trained.zlc                           # dump a serialized compressor
```

## Known limits

- **2 GB single-file limit** (chunking was WIP at launch). For larger inputs, split first and
  compress per-shard, or set an explicit `--chunk-size`.
- Default profiles sometimes **lose** to zip/flac/zstd -19 — OpenZL's own docs say so. Always
  benchmark; never assume.
- `pytorch` profile supports **no training**.
- `parquet` only handles canonical Parquet (plain encoding, uncompressed pages).
