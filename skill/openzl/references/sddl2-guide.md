# SDDL2 guide (`--profile sddl2`)

The newer dialect. **~4% worse ratio than SDDL1, ~2x faster decompress.** Choose it when the
user's workload is decompress-heavy (hot reads, serving path) rather than storage-bound.

**Requires zli v0.2.4+.** On v0.1 the `sddl2` profile speaks a different, dead dialect and
cannot consume modern SDDL2 — verified: v0.1's `sddl2_compiler` rejects `record X() {` and
v0.1's `zli --profile sddl2` fails on both modern source and modern bytecode.

Verified 2026-07-31 against `sddl2_compiler` and `zli` 0.2.4 @ `a9de25e`, Apple Silicon.

---

## SDDL1 vs SDDL2 — do not mix them up

| | SDDL1 | SDDL2 |
|---|---|---|
| `zli` profile | `--profile sddl` | `--profile sddl2` |
| Record members | **newline-separated, NO commas** | **comma-separated, commas REQUIRED** |
| Record keyword | `Name = { ... }` | `record Name() { ... }` |
| Field names | optional (`a : Byte`) | required (`a: Byte`) |
| Unbounded array | `_rem / sizeof T` then `T[n]` | `x: T[]` |
| Compiler validates type names? | **No** (silently accepts junk) | **Yes** (`semantic error: Undefined variable`) |
| `Bytes(n)` type | not available | available |
| `Float8`/`BFloat8`/`BFloat32`/`BFloat64` | available | **not** available |
| Standalone compiler | `sddl_compiler` (stdin → stdout) | `sddl2_compiler -i IN -o OUT` |
| zli `--profile-arg` (v0.2.4) | description source | description source |
| Ratio on our tick data | 6,030,832 B | 6,281,718 B (+4.16%) |
| Decompress on our tick data | ~830 MB/s | ~1,585 MB/s (1.9x) |

The two languages have **opposite separator rules**. Feeding an SDDL1 description to
`--profile sddl2` (or vice versa) always fails.

---

## Verified drift from the public docs

The public docs and `openzl.org/sddl/` describe syntax that **does not compile**:

| Public/stale form | Actual v0.2.4 form |
|---|---|
| `Record Header() = { ... }` | `record Header() { ... }` |
| `var n = expr` | `n = expr` |

Verified: `Record R() = {` → `parse error: Failed to match args for rule: GrammarRule(Symbol::ASSIGN ...)`.
`var n = 5` → `internal error: Expected operator between expressions`. There is no `var`
keyword in the SDDL2 grammar table.

`Record X() = { }` compiles under **neither** compiler in **either** version — it is a dead
dialect. Never write SDDL from the published docs; use this file.

---

## Canonical reference — upstream shipped example

Verbatim copy of `examples/sddl2/sao_silesia.sddl` at commit `a9de25e` (compiles clean,
471 B bytecode). This is the file to pattern-match against:

```
# ==========================================
# Star Catalog
# File `sao` part of the silesia compression corpus
# Using SDDL v0.5
# ==========================================

# ------------------------------------------
# Star entry definition
# ------------------------------------------
record StarEntry() {
  SRA0:  Float64LE,     # Right Ascension (radians)
  SDEC0: Float64LE,     # Declination (radians)
  ISP:   Bytes(2),      # Spectral type
  MAG:   Int16LE,       # Magnitudes (0–10)
  XRPM:  Float32LE,     # R.A. proper motion
  XDPM:  Float32LE      # Dec. proper motion
}

# ------------------------------------------
# File structure
# ------------------------------------------
header: Byte[28]
stars: StarEntry[]
```

(The `# Using SDDL v0.5` comment is upstream's own and is misleading — this is the
current SDDL2 syntax.)

Note `stars: StarEntry[]` — an **empty-bracket array consumes the rest of the input**. That
replaces SDDL1's `_rem / sizeof T` idiom.

---

## Second worked example — our tick feed, ported

Port of `results/ticks.oldv1.sddl`. Compiles (443 B bytecode), compresses, and `cmp`
round-trips clean.

```
# Binary tick/trade feed (BTCUSDT sample) — SDDL2 port of ticks.oldv1.sddl
# 16-byte header (magic "TICK", u32 version, i64 count), then 41-byte records.

record Trade() {
  trade_id:  Int64LE,     # monotonic trade id
  price:     Float64LE,
  qty:       Float64LE,
  quote_qty: Float64LE,
  ts_us:     Int64LE,     # near-monotonic microseconds
  flags:     Byte         # bit0 isBuyerMaker, bit1 isBestMatch
}

header: Byte[16]
trades: Trade[]
```

Porting SDDL1 → SDDL2 needed only: `Name = {` → `record Name() {`, add commas between
members, add field names, and `_rem / sizeof T` + `T[n]` → `T[]`.

### Result (benchmarked 2026-07-31, zli 0.2.4 @ a9de25e, Apple Silicon)

Input 65,600,016 B.

| Path | Size | vs zstd -3 | Compress | Decompress |
|---|---|---|---|---|
| SDDL1 (`--profile sddl`) | 6,030,832 B | −48.65% | 443 ms / 148 MB/s | 79 ms / **827 MB/s** |
| SDDL2 (`--profile sddl2`) | 6,281,718 B | −46.51% | 306 ms / 214 MB/s | 41 ms / **1,585 MB/s** |
| zstd -3 | 11,743,706 B | — | | |

Both `cmp`-verified byte-identical. SDDL2 costs 4.16% ratio and buys 1.9x decompress
(and 1.4x compress).

---

## Valid types (authoritative)

From `tools/sddl2/compiler/Syntax.cpp` (~line 171):

`Byte`, `Bytes(n)`, `UInt8`, `Int8`,
`UInt16LE/BE`, `Int16LE/BE`, `UInt32LE/BE`, `Int32LE/BE`, `UInt64LE/BE`, `Int64LE/BE`,
`Float16LE/BE`, `Float32LE/BE`, `Float64LE/BE`, `BFloat16LE/BE`.

Keywords: `record`, `when`, `expect`, `sizeof`, `abs`, `between`, `@`.

No `Float8`, no `BFloat8`, no `BFloat32*`, no `BFloat64*` (those are SDDL1-only).
No `var`, no `die`, no `log`, no `consume`, no `sendto`, no `Poison`.

---

## Workflow

```sh
# Not on PATH -- both live in the same build tree as zli. detect_zli.sh emits these.
eval "$(scripts/detect_zli.sh | grep -E '^(ZLI|SDDL2_COMPILER)=')"

# 1. syntax + type check (SDDL2 really does catch unknown types)
"$SDDL2_COMPILER" -i desc.sddl2 -o /dev/null && echo "compiles"

# 2. compress -- v0.2.4 takes the SOURCE file directly, no bytecode step needed
"$ZLI" compress data.bin --profile sddl2 --profile-arg desc.sddl2 -o data.zl -f --strict

# 3. MANDATORY round-trip
"$ZLI" decompress data.zl -o data.out -f
cmp data.bin data.out || echo "ROUND-TRIP FAILED"

# 4. benchmark
scripts/benchmark.sh data.bin data.zl "$ZLI"
```

`--strict` still matters: as with SDDL1, a runtime parse failure otherwise falls back to
generic compression and exits 0.

On v0.1 only, `--profile-arg` wanted pre-compiled bytecode (`sddl2_compiler` was a
stdin→stdout tool there). Not worth supporting — tell the user to build a current `zli`.

---

## When to choose SDDL2 over SDDL1

Pick **SDDL2** when:
- decompression speed is the bottleneck (data read far more often than written),
- the description is complex enough that compile-time type checking is worth the 4% ratio,
- you need `Bytes(n)` for short fixed strings.

Pick **SDDL1** (default) when:
- storage cost is the goal — it simply compresses better,
- the target may run an older `zli`.

If unsure, write SDDL1 first, then port (it is mechanical, see above) and benchmark both. They
take about a minute each on a 65 MB file.
