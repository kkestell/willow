#!/bin/sh
# Runs the bootstrap program tests: bootstrap/tests/programs/*.wlo, or the
# files named on the command line.
#
# Each program is built with willow0 and run from its own directory. Optional
# NAME.out and NAME.err hold the expected stdout and stderr; a missing file
# means no output. The expected exit status is 1 when NAME.err exists and 0
# otherwise. A program that fails to compile has the compiler's stderr as its
# stderr and exit status 1. Stdin is NAME.in when it exists and empty otherwise.
#
# WILLOW0 names the compiler; it defaults to the release build of stage 0.

set -u
root=$(cd "$(dirname "$0")/../.." && pwd)
willow0=${WILLOW0:-$root/bootstrap/stage0/target/release/willow0}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

if [ $# -eq 0 ]; then
    set -- "$root"/bootstrap/tests/programs/*.wlo
fi

passed=0
failed=0
for file in "$@"; do
    [ -e "$file" ] || continue
    dir=$(dirname "$file")
    name=$(basename "$file" .wlo)
    base=$dir/$name
    input=/dev/null
    [ -f "$base.in" ] && input=$base.in
    if "$willow0" build "$file" -o "$work/$name" >"$work/out" 2>"$work/err"; then
        (cd "$dir" && "$work/$name" <"$input" >"$work/out" 2>"$work/err")
        status=$?
    else
        status=1
    fi
    expected_status=0
    [ -f "$base.err" ] && expected_status=1
    ok=1
    if [ "$status" -ne "$expected_status" ]; then
        echo "FAIL $file: exit status $status, expected $expected_status"
        ok=0
    fi
    for stream in out err; do
        expected=/dev/null
        [ -f "$base.$stream" ] && expected=$base.$stream
        if ! cmp -s "$expected" "$work/$stream"; then
            echo "FAIL $file: std$stream differs"
            diff "$expected" "$work/$stream" | sed 's/^/    /'
            ok=0
        fi
    done
    if [ $ok -eq 1 ]; then
        passed=$((passed + 1))
    else
        failed=$((failed + 1))
    fi
done
echo "$passed passed, $failed failed"
[ $failed -eq 0 ]
