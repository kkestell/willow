#!/bin/sh
# Exercise lazy PCRE2 loading without changing the host's installed library.
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
willow=${WILLOW:-$root/build/willow2b}
willow1=${WILLOW1:-$root/build/willow1}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
bootstrap/prepare.sh compiler "$work/src"
sed 's/libpcre2-8/libwillow-missing-pcre2/g' "$work/src/core_source.wlo" >"$work/core_source.wlo"
mv "$work/core_source.wlo" "$work/src/core_source.wlo"
"$willow1" build "$work/src/willow.wlo" -o "$work/compiler"
"$work/compiler" build tests/re/load_failure.wlo -o "$work/load-failure"
"$work/load-failure" >"$work/load-failure.out"
diff -u tests/re/load_failure.out "$work/load-failure.out"
echo "PCRE2 loading passed"
