#!/usr/bin/env bash
# Benchmark an OpenZL-compressed file against every general-purpose compressor
# available on the machine, and verify the OpenZL round-trip byte-for-byte.
#
# Usage: ./benchmark.sh <original_file> <openzl_compressed_file> [zli_path]
#
# Baselines: zstd -3, zstd -19 -T0, gzip -9, xz -9 -T0, brotli -q 11, bzip2 -9,
# lz4 -12. Missing binaries are skipped with a warning, never a failure.
#
# Env:
#   SKIP_SLOW=1   skip xz/brotli/bzip2 (they run minutes-to-hours on GB inputs)
#   ZLI=<path>    zli binary (also accepted as the 3rd positional arg)
#
# Reporting an OpenZL win against zstd alone is not enough - xz and brotli are
# the ratio-maximising incumbents a reader will ask about, so the report calls
# out the single best baseline and OpenZL's margin over it.
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
SKIP_SLOW="${SKIP_SLOW:-0}"

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
rm -f "$WORK/rt.out"

# ---- Baselines ----
have() { command -v "$1" >/dev/null 2>&1; }

# label | binary | slug | slow(1 = skipped when SKIP_SLOW=1)
# Kept as a newline-separated string, not an array, so this stays bash-3.2 safe
# (macOS ships bash 3.2 - no associative arrays, no mapfile).
BASELINES="zstd -3|zstd|zst3|0
zstd -19 -T0|zstd|zst19|0
gzip -9|gzip|gz|0
xz -9 -T0|xz|xz|1
brotli -q 11|brotli|br|1
bzip2 -9|bzip2|bz2|1
lz4 -12|lz4|lz4|0"

compress_cmd() { # label infile outfile
  case "$1" in
    "zstd -3")      zstd -3 -q -f -o "$3" "$2" ;;
    "zstd -19 -T0") zstd -19 -T0 -q -f -o "$3" "$2" ;;
    "gzip -9")      gzip -9 -c "$2" > "$3" ;;
    "xz -9 -T0")    xz -9 -T0 -c "$2" > "$3" ;;
    "brotli -q 11") brotli -q 11 -f -o "$3" "$2" ;;
    "bzip2 -9")     bzip2 -9 -c "$2" > "$3" ;;
    "lz4 -12")      lz4 -12 -q -f "$2" "$3" ;;
    *) return 127 ;;
  esac
}

decompress_cmd() { # label infile outfile
  case "$1" in
    zstd*)   zstd -d -q -f -o "$3" "$2" ;;
    gzip*)   gzip -dc "$2" > "$3" ;;
    xz*)     xz -dc -T0 "$2" > "$3" ;;
    brotli*) brotli -d -f -o "$3" "$2" ;;
    bzip2*)  bzip2 -dc "$2" > "$3" ;;
    lz4*)    lz4 -d -q -f "$2" "$3" ;;
    *) return 127 ;;
  esac
}

ZSTD3_SIZE=""

# Results are stashed in files (bash 3.2 has no associative arrays):
#   $WORK/res.<slug> = "<size> <compress_ms> <decompress_ms>"
OLDIFS="$IFS"
IFS='
'
for spec in $BASELINES; do
  IFS='|' read -r label bin slug slow <<EOF
$spec
EOF
  if ! have "$bin"; then
    echo "  warning: $bin not installed, skipping $label" >&2
    continue
  fi
  if [ "$slow" = "1" ] && [ "$SKIP_SLOW" = "1" ]; then
    echo "  skipping $label (SKIP_SLOW=1)" >&2
    continue
  fi

  echo "  $label ..." >&2
  out="$WORK/b.$slug"
  if ! run_timed "$WORK/tc.$slug" -- compress_cmd "$label" "$ORIG" "$out"; then
    echo "  warning: $label failed, skipping" >&2
    rm -f "$out"
    continue
  fi
  bsize=$(fsize "$out")
  cms=$(cat "$WORK/tc.$slug")

  run_timed "$WORK/td.$slug" -- decompress_cmd "$label" "$out" "$WORK/d.$slug"
  dms=$(cat "$WORK/td.$slug")
  rm -f "$WORK/d.$slug" "$out"

  echo "$bsize $cms $dms" > "$WORK/res.$slug"
  [ "$label" = "zstd -3" ] && ZSTD3_SIZE="$bsize"
done
IFS="$OLDIFS"

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
echo "### Compression benchmark - $(basename "$ORIG")"
echo
echo "Original: $(commafy "$ORIG_SIZE") bytes"
echo
echo "| Compressor | Size (B) | Ratio | % of orig | vs zstd -3 | Compress | Decompress |"
echo "|---|---|---|---|---|---|---|"
row "**OpenZL**" "$ZL_SIZE" "" "$ZL_DEC_MS"

BEST_LABEL=""; BEST_SIZE=""
IFS='
'
for spec in $BASELINES; do
  IFS='|' read -r label bin slug slow <<EOF
$spec
EOF
  [ -f "$WORK/res.$slug" ] || continue
  # IFS is newline for the outer loop - force space splitting for the fields.
  IFS=' ' read -r bsize cms dms < "$WORK/res.$slug"
  row "$label" "$bsize" "$cms" "$dms"
  if [ -z "$BEST_SIZE" ] || [ "$bsize" -lt "$BEST_SIZE" ]; then
    BEST_SIZE="$bsize"; BEST_LABEL="$label"
  fi
done
IFS="$OLDIFS"

echo
if [ -n "$BEST_SIZE" ]; then
  # The honest headline: OpenZL vs the strongest baseline, not vs the weakest.
  delta=$(python3 -c "print(f'{100.0*($ZL_SIZE - $BEST_SIZE)/$BEST_SIZE:+.2f}%')" 2>/dev/null || echo "-")
  if [ "$ZL_SIZE" -lt "$BEST_SIZE" ]; then
    echo "Best baseline: **$BEST_LABEL** ($(commafy "$BEST_SIZE") B). OpenZL is **$delta** vs it - OpenZL wins."
  else
    echo "Best baseline: **$BEST_LABEL** ($(commafy "$BEST_SIZE") B). OpenZL is **$delta** vs it - **OpenZL loses on ratio**; compare speed before recommending it."
  fi
fi
echo
echo "OpenZL round-trip (\`cmp\` vs original): **$ROUNDTRIP**"
echo
echo "_OpenZL compress time not measured here (depends on profile/compressor); re-run \`zli compress\` if needed._"

if [ "$ROUNDTRIP" != "OK" ]; then
  echo >&2
  echo "FATAL: OpenZL round-trip failed - do NOT report these savings." >&2
  exit 1
fi
exit 0
