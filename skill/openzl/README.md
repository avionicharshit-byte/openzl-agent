# `openzl` — a Claude Code skill for format-aware compression

Turns Claude Code into an OpenZL compression expert. Point it at data; it figures out the
structure, picks a profile or writes an SDDL data description, trains a compressor, verifies
the round-trip, and hands back a trained compressor plus a benchmark against zstd and gzip.

[OpenZL](https://openzl.org) (Meta, open-sourced Oct 2025) compresses structured data by
decomposing it into typed streams and compressing each with a specialised codec. It beats
`zstd` substantially — *if* you can describe your data's structure. That description step is
the adoption barrier. This skill does it for you.

Built for data/platform engineers who own a storage bill and have zero compression expertise.

## Does it actually help?

Benchmarked 2026-07-31, `zli` 0.2.4 @ `a9de25e`, Apple Silicon (8 cores).
Every OpenZL result was decompressed and `cmp`-verified byte-identical.

| Dataset | Size | Path | OpenZL | vs `zstd -3` | vs `zstd -19` |
|---|---|---|---|---|---|
| NYC 311 CSV | 87.5 MB | `csv` profile, trained | 4,521,797 B | **−50.04%** | −11.7% |
| Binary tick feed | 65.6 MB | LLM-written SDDL1 | 6,030,832 B | **−48.65%** | −34.5% |
| resnet18.pth | 46.8 MB | `pytorch` profile | 39,047,321 B | −10.04% | −10.0% |
| GH Archive JSONL | 80.0 MB | `serial`, trained | 13,180,660 B | −6.00% | **+38.0% — loses** |

Read that table honestly, and the skill will tell users the same thing:

- **CSV and describable binary formats are the win** — roughly half the bytes of `zstd -3`,
  at 150–210 MB/s compress and 750–830 MB/s decompress.
- **PyTorch checkpoints** look unimpressive by ratio (1.20x) because weights are
  high-entropy floats — but OpenZL removes **~2.3x as many bytes as `zstd -3`**, at
  ~1.8 GB/s. Judge it on bytes saved and throughput, not ratio.
- **JSON/JSONL is weak.** There is no JSON profile in OpenZL (verified against the full
  0.2.4 profile list). Trained `serial` gains only ~6% over `zstd -3` and *loses* to
  `zstd -19`. The skill says so rather than selling it.

## Install

```sh
cp -r skill/openzl ~/.claude/skills/
```

Then just ask Claude Code for compression work — the skill triggers on intent, no slash
command needed.

## Usage examples

- "Compress this directory of CSVs and show me what it saves."
- "What would OpenZL save me on `exports/2026-07/`?"
- "We store 40 TB/month of these event logs. Is there anything better than zstd?"
- "Here's a binary file from our trading feed — can you write an SDDL description for it?"
- "Compress this PyTorch checkpoint."
- "Why is my OpenZL output barely smaller than zstd?"

A typical run: locate `zli` → identify the format → build sample files → train (minutes) →
compress with `--strict` → decompress and `cmp` → print a benchmark table → estimate monthly
savings from the user's stated volume.

## Requirements

- **`zli`**, built from [facebook/openzl](https://github.com/facebook/openzl). **v0.2.4 or
  newer recommended**; v0.1 works with reduced capability (no `--strict`, different flags,
  no usable SDDL2). The skill finds it via `$ZLI`, `PATH`, or common build paths, and offers
  to build it if missing:

  ```sh
  git clone https://github.com/facebook/openzl.git && cd openzl
  cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
  cmake --build build --target zli -j"$(getconf _NPROCESSORS_ONLN)"   # ~11 min
  cmake --build build --target sddl_compiler sddl2_compiler -j4       # optional
  ```

- `zstd` and `gzip` for the benchmark baselines (optional — skipped with a warning if absent).
- `python3` for timing, PyTorch container detection, and record-size arithmetic.

## What's in here

| File | Purpose |
|---|---|
| `SKILL.md` | The playbook: detect → identify → train → SDDL → benchmark → deliver |
| `references/zli-cheatsheet.md` | Verified `zli` syntax, v0.1 vs v0.2.4 differences, known bugs |
| `references/sddl1-guide.md` | SDDL1 dialect — best ratio; public docs are wrong, this isn't |
| `references/sddl2-guide.md` | SDDL2 dialect — ~4% worse ratio, ~2x faster decompress |
| `scripts/detect_zli.sh` | Finds `zli`, prints path/version/profiles |
| `scripts/benchmark.sh` | zstd/gzip baselines + mandatory round-trip `cmp`, markdown table |

## Things the skill knows that the docs don't

Learned by running the binaries, and the reason this skill exists rather than a prompt saying
"use OpenZL":

- **A broken description fails silently.** By default `zli` falls back to generic compression,
  prints a success line, and exits 0 — so you report a fake win. `--strict` is mandatory.
- **There are two SDDL dialects with opposite syntax rules.** SDDL1 records are
  newline-separated (commas are a syntax error); SDDL2 records are comma-separated (newlines
  are a syntax error). Upstream's own `Syntax.md` documents SDDL1 with commas — it's wrong.
- **The published SDDL syntax compiles under neither dialect** (`Record X() = {`, `var n =`).
- **The SDDL1 compiler doesn't validate type names** — `: Bogus123` exits 0 and fails at
  runtime. SDDL2's compiler does catch them.
- **`--max-time-secs` is not a wall-clock limit.** The ACE phase ignores it: a 120 s budget
  took 495 s on CSV.
- **A v0.2.4 `.zlc` is 0 bytes until training finishes** — don't kill it early. v0.1 wrote a
  usable snapshot mid-run; v0.2.4 doesn't.
- **`zli` writes almost everything to stderr**, including `list-profiles`.
- **Legacy `.pth` checkpoints are rejected** with a confusing `EOCD not found`; they're
  pre-torch-1.6 pickles, not zips, and need re-saving first.

## Decompression has no lock-in

The `.zl` frame is self-describing. Decompressing needs **no** `.zlc` and **no** `.sddl`:

```sh
zli decompress data.zl -o data.out
```

The trained compressor and the data description are compression-side artifacts only. (The one
exception is `--dict-bundle-output`, where the `.zd` bundle is also needed to decompress — the
skill flags this when it applies.)

## Status

Early release. Benchmark methodology: each dataset compressed with the listed path,
decompressed, `cmp`-verified, and measured against `zstd -3`, `zstd -19 -T0`, `gzip -9`
on the same machine.
