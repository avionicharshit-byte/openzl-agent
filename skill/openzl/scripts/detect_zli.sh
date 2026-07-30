#!/usr/bin/env bash
# Locate a usable `zli` (OpenZL CLI) and report its version + profiles.
#
# Search order: $ZLI -> PATH -> common build locations.
# On success: prints ZLI/ZLI_VERSION/ZLI_PROFILES to stdout, exits 0.
# On failure: prints build instructions to stderr, exits 1.
#
# Usage:   ./detect_zli.sh
#          ZLI=/path/to/zli ./detect_zli.sh
# Consume: eval "$(./detect_zli.sh | grep '^ZLI=')"

set -u

candidates=()
[ "${ZLI:-}" != "" ] && candidates+=("$ZLI")

if command -v zli >/dev/null 2>&1; then
  candidates+=("$(command -v zli)")
fi

for pat in \
  "$HOME"/Documents/*/openzl*/build/cli/zli \
  "$HOME"/Documents/*/openzl*/cmake-build-*/cli/zli \
  "$HOME"/openzl*/build/cli/zli \
  "$HOME"/src/openzl*/build/cli/zli \
  "$HOME"/code/openzl*/build/cli/zli \
  ./build/cli/zli \
  ../openzl/build/cli/zli
do
  [ -x "$pat" ] && candidates+=("$pat")
done

found=""
for c in "${candidates[@]:-}"; do
  [ -n "$c" ] && [ -x "$c" ] || continue
  if "$c" --version >/dev/null 2>&1; then
    found="$c"
    break
  fi
done

if [ -z "$found" ]; then
  cat >&2 <<'EOF'
error: could not find a working `zli` (OpenZL CLI).

Searched: $ZLI, PATH, ~/Documents/*/openzl*/build/cli/zli, ./build/cli/zli

Build it from source (~11 min, xgboost dominates):

  git clone https://github.com/facebook/openzl.git
  cd openzl
  cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
  cmake --build build --target zli -j"$(getconf _NPROCESSORS_ONLN)"
  # optional, for standalone SDDL syntax checking:
  cmake --build build --target sddl_compiler sddl2_compiler -j4

Then re-run with:  ZLI=$PWD/build/cli/zli ./detect_zli.sh
EOF
  exit 1
fi

raw_version="$("$found" --version 2>&1 | head -1)"
# "Demo CLI for OpenZL. Version 0.2.4" -> 0.2.4 ; "zstrong-cli version 0.1" -> 0.1
num_version="$(printf '%s' "$raw_version" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)"
[ -z "$num_version" ] && num_version="unknown"

# `list-profiles` prints "  -| name = description" -- ON STDERR, so merge it in.
profiles="$("$found" list-profiles 2>&1 \
  | sed -n 's/^[[:space:]]*-|[[:space:]]*\([A-Za-z0-9_-]*\).*/\1/p' \
  | paste -sd, - )"
[ -z "$profiles" ] && profiles="unknown"

echo "ZLI=$found"
echo "ZLI_VERSION=$num_version"
echo "ZLI_VERSION_RAW=$raw_version"
echo "ZLI_PROFILES=$profiles"

# SDDL compilers are optional cmake targets in the same build tree as zli.
build_root="$(dirname "$(dirname "$found")")"
sddl1="$build_root/tools/sddl/sddl_compiler"
sddl2="$build_root/tools/sddl2/sddl2_compiler"
[ -x "$sddl1" ] && echo "SDDL_COMPILER=$sddl1"
[ -x "$sddl2" ] && echo "SDDL2_COMPILER=$sddl2"

case "$num_version" in
  0.1|0.1.*)
    echo "ZLI_NOTE=v0.1 is old: use --chunk-size-mb (not --chunk-size); sddl2 needs pre-compiled bytecode; no --dict-bundle-output. Prefer building a current zli." ;;
esac

exit 0
