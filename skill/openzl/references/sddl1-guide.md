# SDDL1 guide (`--profile sddl`)

The dialect that gives the **best compression ratio**. Use it unless the user specifically
needs faster decompression (then see `sddl2-guide.md`).

Verified 2026-07-31 against `sddl_compiler` and `zli` 0.2.4 @ `a9de25e`, Apple Silicon.

---

## READ THIS FIRST: two traps that will waste your time

### Trap 1 — the compiler does not validate type names

`sddl_compiler` exits **0** on descriptions containing types that do not exist. An unknown
capitalised word is parsed as a *variable reference*, not rejected. All of these "compile":

```
: Bogus123      # exit 0
: NotAType      # exit 0
: Bytes(4)      # exit 0  -- but `Bytes` does NOT exist in SDDL1
: Int16         # exit 0  -- no such type; you want Int16LE / Int16BE
```

They then fail at **runtime**, and by default `zli` **silently falls back to generic
compression and exits 0**. A passing syntax check proves nothing on its own.

**Therefore: always compress with `--strict`, and always `cmp` the round-trip.**

### Trap 2 — upstream's own `Syntax.md` is wrong about separators

`tools/sddl/compiler/Syntax.md` documents records as comma-separated:

```
Row = {
  Byte,          # <-- FAILS TO COMPILE
  UInt32LE[8],
}
```

Verified: that form gives `syntax error: Unexpected separator token ','`.
**SDDL1 record members are newline-separated, with no commas.** Do not copy the doc.

---

## Valid primitive types (authoritative)

Source of truth is the compiler keyword table, `tools/sddl/compiler/Syntax.cpp` (~line 283) —
**not** a successful compile. The complete SDDL1 list:

| Category | Names | Size |
|---|---|---|
| Raw byte | `Byte` | 1 |
| Signed int | `Int8`, `Int16LE`, `Int16BE`, `Int32LE`, `Int32BE`, `Int64LE`, `Int64BE` | 1/2/4/8 |
| Unsigned int | `UInt8`, `UInt16LE`, `UInt16BE`, `UInt32LE`, `UInt32BE`, `UInt64LE`, `UInt64BE` | 1/2/4/8 |
| Float | `Float8`, `Float16LE`, `Float16BE`, `Float32LE`, `Float32BE`, `Float64LE`, `Float64BE` | 1/2/4/8 |
| BFloat | `BFloat8`, `BFloat16LE`, `BFloat16BE`, `BFloat32LE`, `BFloat32BE`, `BFloat64LE`, `BFloat64BE` | 1/2/4/8 |
| Special | `Poison` | — |

Keywords: `expect`, `sizeof`, `consume`, `die`, `log`, `sendto`.

**There is no `Bytes` type in SDDL1** (that is SDDL2). For a fixed run of raw bytes use
`Byte[n]`. There are no endian-free `Int16`/`Int32`/`Int64`/`Float32`/`Float64` aliases —
always spell the endianness.

`Byte` is `ZL_Type` **Serial**; every other type is **Numeric**. Numeric typing is what buys
the ratio, so type numeric columns properly — see "If the ratio disappoints" below.

---

## Syntax

```
# Record: newline-separated members, no commas. Two member styles, both valid:
Trade = {
  Int64LE                 # bare type - positional, unnamed
  price : Float64LE       # named - value captured into the record's scope
}

Name = expr               # assignment (also declares reusable field aliases)
: Type[expr]              # anonymous root-level consume ("skip/consume N of these")
var : Type                # consume and capture the value
Type[n]                   # array of n
_rem                      # bytes remaining from the cursor to end of input
sizeof Name               # static byte size of a field
expect <cond>             # abort the parse if cond == 0
hdr.field                 # member access on a consumed record's scope
```

Statements are terminated by newline or `;`. `#` starts a comment.

Arithmetic is all **signed 64-bit**: `+ - * / % == != < <= > >= & | ^ ~ !`.

### Field instances matter for the output layout

Each *use* of a built-in type name declares a **new field instance**, and each instance gets
its own output stream. So:

```
Foo = { UInt64LE   UInt64LE }   # 2 fields -> 2 separate streams
U64 = UInt64LE
Bar = { U64        U64      }   # 1 field used twice -> 1 shared stream
```

Prefer separate instances when columns hold unrelated value ranges (the usual case — it lets
each stream pick its own encoding); alias into one shared field when the columns are genuinely
the same kind of value.

---

## Worked example: binary tick feed (our best SDDL result)

`data/ticks/btcusdt.bin` — 16-byte header (`"TICK"` magic, u32 version, i64 count) followed by
fixed 41-byte trade records.

`results/ticks.oldv1.sddl`:

```
# Binary tick/trade feed (BTCUSDT sample), SDDL1 old syntax
# 16-byte header (magic "TICK", u32 version, i64 count), then 41-byte records.

Trade = {
  Int64LE      # trade_id (monotonic)
  Float64LE    # price
  Float64LE    # qty
  Float64LE    # quote_qty
  Int64LE      # ts_us (near-monotonic microseconds)
  Byte         # flags: bit0 isBuyerMaker, bit1 isBestMatch
}

: Byte[16]
num_trades = _rem / sizeof Trade
: Trade[num_trades]
```

The named-field style is equivalent and produces a **byte-identical** result (verified):

```
Trade = {
  trade_id  : Int64LE
  price     : Float64LE
  qty       : Float64LE
  quote_qty : Float64LE
  ts_us     : Int64LE
  flags     : Byte
}

: Byte[16]
num_trades = _rem / sizeof Trade
: Trade[num_trades]
```

Prefer the named style — it is self-documenting and costs nothing.

### Result (benchmarked 2026-07-31, zli 0.2.4 @ a9de25e, Apple Silicon)

Input 65,600,016 B (65.6 MB).

| Compressor | Size | vs zstd -3 | Notes |
|---|---|---|---|
| **OpenZL SDDL1** | **6,030,832 B** | **−48.65%** | 10.88x, ~150 MB/s compress, ~830 MB/s decompress |
| zstd -3 | 11,743,706 B | — | the realistic incumbent |
| zstd -19 | 9,209,893 B | +56.7% larger than OpenZL | OpenZL is 34.5% smaller than zstd -19 |
| gzip -9 | 12,450,167 B | | |

Round-trip `cmp`-verified byte-identical.

The `Byte[16]` header skip plus `_rem / sizeof Trade` is the workhorse pattern: **skip a fixed
header, then divide the remainder by the record size.**

---

## The `sao` pattern (upstream shipped example)

`examples/sddl/sao_silesia.oldv1.sddl` — same shape, mixed field widths:

```
StarEntry = {
  Float64LE
  Float64LE
  Byte
  Byte
  Int16LE
  Float32LE
  Float32LE
}

: Byte[28]
num_stars = _rem / sizeof StarEntry
: StarEntry[num_stars]
```

Note the 2-byte `ISP` spectral-type string is expressed as two separate `Byte` fields, not a
`Bytes(2)` — because SDDL1 has no `Bytes`.

---

## Workflow

```sh
# Not on PATH -- both live in the same build tree as zli. detect_zli.sh emits these.
eval "$(scripts/detect_zli.sh | grep -E '^(ZLI|SDDL_COMPILER)=')"

# 1. syntax check (stdin -> stdout bytecode). Catches structural errors ONLY.
"$SDDL_COMPILER" < desc.sddl > /dev/null && echo "parses"

# 2. compress -- --strict is mandatory, or failures pass silently
"$ZLI" compress data.bin --profile sddl --profile-arg desc.sddl -o data.zl -f --strict

# 3. MANDATORY round-trip
"$ZLI" decompress data.zl -o data.out -f
cmp data.bin data.out || echo "ROUND-TRIP FAILED"

# 4. benchmark
scripts/benchmark.sh data.bin data.zl "$ZLI"
```

## Deriving a description from an unknown binary

1. `xxd data.bin | head -40` — look for ASCII magic, version fields, a count.
2. `ls -l` for the exact byte size.
3. Hypothesise `header_size` and `record_size`, then test:
   `python3 -c "print((SIZE - HDR) % REC)"` → must print `0`.
4. Look at column alignment in `xxd` output: repeating 8-byte float patterns are easy to spot
   (IEEE-754 doubles in a narrow range share high bytes, e.g. `...@` bytes `40 xx`).
5. Write the record, `--strict` compress, `cmp`, benchmark.

## If the ratio disappoints

Almost always a **typing** problem, not a structural one.

- A float column typed as `Byte[8]` kills the win — the transform sees opaque bytes instead of
  numbers. Type it `Float64LE`.
- Wrong endianness produces garbage-looking values that compress poorly. Try the other one.
- Timestamps/IDs typed as floats lose delta-encoding. Use `Int64LE`.
- Merging unrelated columns into one aliased field forces them to share a stream. Split them.
- Ratio near 1.0 with exit 0 and no `--strict` = your description silently failed. Re-run with
  `--strict`.
