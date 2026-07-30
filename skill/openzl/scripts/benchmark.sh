#!/usr/bin/env bash
# Benchmark an OpenZL-compressed file against zstd -3 / zstd -19 / gzip -9,
# and verify the OpenZL round-trip byte-for-byte.
#
# Usage: ./benchmark.sh <original_file> <openzl_compressed_file> [zli_path]
#
# Exits nonzero if the OpenZL round-trip does not reproduce the original.
# Baseline artifacts go to a temp dir and are deleted on exit.

set -u

usage() {
  echo "usage: $0 <original_file> <openzl_compressed_file> [zli_path]" >&2
  exit 2
}

[ $# -ge 2 ] || usage
ORIG="$1"
ZL="$2"
ZLI="${3:-${ZLI:-zli}}"

[ -f "$ORIG" ] || { echo "error: no such file: $ORIG" >&2; exit 2; }
[ -f "$ZL" ]   || { echo "error: no such file: $ZL" >&2; exit 2; }
command -v "$ZLI" >/dev/null 2>&1 || [ -x "$ZLI" ] || {
  echo "error: zli not executable: $ZLI (pass path as 3rd arg or set \$ZLI)" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ozlbench.XXXXXX")" || exit 1
trap 'rm -rf "$WORK"' EXIT INT TERM

fsize() { wc -c < "$1" | tr -d ' '; }

# Portable millisecond wall clock (macOS `date` has no %N).
now_ms() { python3 -c 'import time;print(int(time.time()*1000))'; }

run_timed() { # run_timed <out_var_file> -- cmd...
  local tfile="$1"; shift; [ "$1" = "--" ] && shift
  local s e
  s=$(now_ms); "$@" >/dev/null 2>&1; local rc=$?; e=$(now_ms)
  echo $((e - s)) > "$tfile"
  return $rc
}

ORIG_SIZE=$(fsize "$ORIG")
ZL_SIZE=$(fsize "$ZL")

echo "Benchmarking $(basename "$ORIG") ($ORIG_SIZE B)" >&2

# ---- OpenZL round-trip (mandatory correctness gate) ----
echo "  openzl decompress + cmp ..." >&2
run_timed "$WORK/t_zl_d" -- "$ZLI" decompress "$ZL" -o "$WORK/rt.out" -f
ZL_DEC_RC=$?
ZL_DEC_MS=$(cat "$WORK/t_zl_d" 2>/dev/null || echo 0)

ROUNDTRIP="FAIL"
if [ $ZL_DEC_RC -eq 0 ] && cmp -s "$ORIG" "$WORK/rt.out"; then
  ROUNDTRIP="OK"
fi

# ---- Baselines ----
have() { command -v "$1" >/dev/null 2>&1; }

ZSTD3_SIZE=""; ZSTD3_C_MS=""; ZSTD3_D_MS=""
ZSTD19_SIZE=""; ZSTD19_C_MS=""; ZSTD19_D_MS=""
GZIP_SIZE=""; GZIP_C_MS=""; GZIP_D_MS=""

if have zstd; then
  echo "  zstd -3 ..." >&2
  run_timed "$WORK/t3c" -- zstd -3 -q -f -o "$WORK/b.zst3" "$ORIG"
  ZSTD3_SIZE=$(fsize "$WORK/b.zst3"); ZSTD3_C_MS=$(cat "$WORK/t3c")
  run_timed "$WORK/t3d" -- zstd -d -q -f -o "$WORK/b3.out" "$WORK/b.zst3"
  ZSTD3_D_MS=$(cat "$WORK/t3d"); rm -f "$WORK/b3.out"

  echo "  zstd -19 -T0 ..." >&2
  run_timed "$WORK/t19c" -- zstd -19 -T0 -q -f -o "$WORK/b.zst19" "$ORIG"
  ZSTD19_SIZE=$(fsize "$WORK/b.zst19"); ZSTD19_C_MS=$(cat "$WORK/t19c")
  run_timed "$WORK/t19d" -- zstd -d -q -f -o "$WORK/b19.out" "$WORK/b.zst19"
  ZSTD19_D_MS=$(cat "$WORK/t19d"); rm -f "$WORK/b19.out"
else
  echo "  warning: zstd not installed, skipping zstd baselines" >&2
fi

if have gzip; then
  echo "  gzip -9 ..." >&2
  run_timed "$WORK/tgc" -- sh -c 'gzip -9 -c "$1" > "$2"' _ "$ORIG" "$WORK/b.gz"
  GZIP_SIZE=$(fsize "$WORK/b.gz"); GZIP_C_MS=$(cat "$WORK/tgc")
  run_timed "$WORK/tgd" -- sh -c 'gzip -dc "$1" > "$2"' _ "$WORK/b.gz" "$WORK/bg.out"
  GZIP_D_MS=$(cat "$WORK/tgd"); rm -f "$WORK/bg.out"
else
  echo "  warning: gzip not installed, skipping gzip baseline" >&2
fi

# ---- Report ----
pct_of_orig() { python3 -c "print(f'{100*$1/$2:.2f}%')" 2>/dev/null || echo "-"; }
ratio()       { python3 -c "print(f'{$2/$1:.2f}x')" 2>/dev/null || echo "-"; }
vs_zstd3() {
  [ -z "$ZSTD3_SIZE" ] && { echo "-"; return; }
  python3 -c "
d = 100.0*($1 - $ZSTD3_SIZE)/$ZSTD3_SIZE
print(f'{d:+.2f}%')" 2>/dev/null || echo "-"
}
ms() { [ -z "$1" ] && echo "-" || echo "${1} ms"; }

commafy() { python3 -c "print(f'{$1:,}')" 2>/dev/null || echo "$1"; }

row() { # name size c_ms d_ms
  printf '| %s | %s | %s | %s | %s | %s | %s |\n' \
    "$1" "$(commafy "$2")" \
    "$(ratio "$2" "$ORIG_SIZE")" "$(pct_of_orig "$2" "$ORIG_SIZE")" \
    "$(vs_zstd3 "$2")" "$(ms "$3")" "$(ms "$4")"
}

echo
echo "### Compression benchmark — $(basename "$ORIG")"
echo
echo "Original: $(python3 -c "print(f'{$ORIG_SIZE:,}')" 2>/dev/null || echo "$ORIG_SIZE") bytes"
echo
echo "| Compressor | Size (B) | Ratio | % of orig | vs zstd -3 | Compress | Decompress |"
echo "|---|---|---|---|---|---|---|"
row "**OpenZL**" "$ZL_SIZE" "" "$ZL_DEC_MS"
[ -n "$ZSTD3_SIZE" ]  && row "zstd -3" "$ZSTD3_SIZE" "$ZSTD3_C_MS" "$ZSTD3_D_MS"
[ -n "$ZSTD19_SIZE" ] && row "zstd -19 -T0" "$ZSTD19_SIZE" "$ZSTD19_C_MS" "$ZSTD19_D_MS"
[ -n "$GZIP_SIZE" ]   && row "gzip -9" "$GZIP_SIZE" "$GZIP_C_MS" "$GZIP_D_MS"
echo
echo "OpenZL round-trip (\`cmp\` vs original): **$ROUNDTRIP**"
echo
echo "_OpenZL compress time not measured here (depends on profile/compressor); re-run \`zli compress\` if needed._"

if [ "$ROUNDTRIP" != "OK" ]; then
  echo >&2
  echo "FATAL: OpenZL round-trip failed — do NOT report these savings." >&2
  exit 1
fi
exit 0
