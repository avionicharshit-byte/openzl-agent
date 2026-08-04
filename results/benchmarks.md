# Stage 0 validation spike — results (2026-07-31)

Machine: macOS 26.2, Apple Silicon. zli: 6-month-old build (`~/Documents/OpenSource/openzl/build/cli/zli`).
All OpenZL round-trips verified byte-identical with `cmp`.

## Dataset 1 — NYC 311 CSV (real, 87.5 MB, 41 messy columns)

Source: `curl "https://data.cityofnewyork.us/resource/erm2-nwe9.csv?$limit=100000"`

| Compressor | Size | Ratio | Compress time |
|---|---|---|---|
| gzip -9 | 12.47 MB | 7.0x | 2.4 s |
| zstd -3 | 9.05 MB | 9.7x | 0.6 s |
| OpenZL csv untrained | 9.05 MB | 9.7x | ~0.6 s |
| zstd -19 -T0 | 5.12 MB | 17.1x | 14.6 s (34 s CPU) |
| **OpenZL csv trained (120 s)** | **5.56 MB** | **15.75x** | **0.8 s** (111 MB/s), decomp 408 MB/s |

**Verdict: PASS — 38.6% smaller than zstd -3 at the same speed class; ~zstd-19 ratio at 18x its speed.**
Training cost: one-time 120 s (`--no-ace-successors`; without it, a 90 s budget overran to 4 min and
wrote a 0-byte .zlc — see gotchas in `skill/openzl/references/zli-cheatsheet.md`).

## Dataset 2 — GitHub Archive JSONL (real event logs, 80 MB)

Source: `curl https://data.gharchive.org/2026-07-29-15.json.gz | gzip -dc | head -c 80000000`

| Compressor | Size | Ratio |
|---|---|---|
| gzip -9 | 16.23 MB | 4.9x |
| zstd -3 | 14.02 MB | 5.7x |
| OpenZL serial trained (120 s) | 12.07 MB | 6.6x |
| **zstd -19 -T0** | **9.55 MB** | **8.4x** |

**Verdict: FAIL vs the 30% bar — trained `serial` beats zstd -3 by only 13.9% and loses to zstd -19.**
OpenZL has NO json/jsonl profile, even in upstream as of 2026-07-30 (checked via git grep).
JSON needs structure-aware shredding (columnarize fields) — exactly what the agent would have to
provide. Gap, not dead end — but unproven.

## Dataset 3 — ResNet18 checkpoint (real float32 weights, 46.8 MB, zip-format .pth)

| Compressor | Size | Bytes removed | Speed |
|---|---|---|---|
| zstd -3 | 43.40 MB | 3.4 MB | fast |
| zstd -19 | 43.39 MB | 3.4 MB | slow |
| xz -9 | 42.86 MB | 4.0 MB | very slow |
| **OpenZL pytorch profile** | **39.04 MB** | **7.8 MB (2.3x more than zstd)** | **1,514 MB/s** |

**Verdict: MISS vs the 30% bar (10.1% smaller than zstd -3) but unique value: 2.3x the bytes removed
at ~50x the speed of anything else.** At checkpoint-pipeline scale this is real money; for a
one-off file it's meh. Note: legacy (pre-torch-1.6, non-zip) .pth files fail with "EOCD not found" —
the agent must detect format vintage.

## Dataset 0b — Binary tick feed, LLM-written SDDL (real trades, 65.6 MB)

Source: 1.6M real Binance BTCUSDT trades (2026-07-28), packed as a binary feed:
16 B header (`TICK`, u32 version, i64 count) + 41 B records (i64 trade_id, f64 price,
f64 qty, f64 quote_qty, i64 ts_us, u8 flags).
Repro: `curl -sL https://data.binance.vision/data/spot/daily/trades/BTCUSDT/BTCUSDT-trades-2026-07-28.zip`

No OpenZL profile covers this format. SDDL written by the LLM zero-shot from a hexdump +
format knowledge (one retry: documented v0.6 syntax → undocumented oldv1 dialect,
see `skill/openzl/references/sddl1-guide.md`). Description: `results/ticks.oldv1.sddl` (9 lines).

| Compressor | Size | Ratio | Compress time |
|---|---|---|---|
| gzip -9 | 12.45 MB | 5.3x | slow |
| zstd -3 | 11.74 MB | 5.6x | 0.08 s |
| OpenZL serial untrained | 10.60 MB | 6.2x | 0.33 s |
| zstd -19 -T0 | 9.21 MB | 7.1x | 12.1 s |
| **OpenZL + LLM SDDL** | **6.05 MB** | **10.85x** | **0.54 s** (122 MB/s), decomp 876 MB/s |

**Verdict: PASS, decisively — 48.5% smaller than zstd -3 AND 34.4% smaller than zstd -19,
at 22x zstd -19's speed.** Round-trip byte-identical. This is the core product hypothesis
(LLM writes the format description, OpenZL exploits it) working end-to-end.

## Score vs kill criterion (≥30% better than zstd -3 on 2 of 3)

**Final: 2 passes (CSV 38.6%, LLM-SDDL binary 48.5%), 1 fail (JSONL 13.9%), 1 miss-but-unique
(checkpoints 10.1%). Gate cleared — proceed to Stage 1 (the `/openzl` skill).**
The JSONL gap remains the open question: no json profile exists anywhere, so the agent would
have to columnarize JSON itself (shred to typed columns → SDDL or csv profile). Park it for
Stage 1.5; lead with CSV + binary-SDDL + checkpoint stories.
