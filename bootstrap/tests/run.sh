#!/bin/sh
# Runs the bootstrap program tests, bootstrap/tests/programs/*.wlo, and core's
# own tests, bootstrap/tests/core/*.wlo, or the files named on the command line.
# Modules the programs import live in subdirectories, which are not run.
#
# Each program is built with willow0 and run from its own directory, so
# diagnostics name the bare file. Optional NAME.out and NAME.err hold the
# expected stdout and stderr; a missing file means no output. The expected exit
# status is 1 when NAME.err exists and 0 otherwise. With STAGE1=1, stderr is
# compared with NAME.stage1.err instead when it exists, for the failures that
# stage 0 reports without a location. A program that fails to compile has the
# compiler's stderr as its stderr and exit status 1. Stdin is NAME.in when it
# exists and empty otherwise. A program that compiles must compile to the same
# IL twice.
#
# WILLOW0 names the compiler; it defaults to the release build of stage 0.

set -u
root=$(cd "$(dirname "$0")/../.." && pwd)
willow0=${WILLOW0:-$root/bootstrap/stage0/target/release/willow0}
case $willow0 in /*) ;; *) willow0=$PWD/$willow0 ;; esac
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

if [ $# -eq 0 ]; then
    set -- "$root"/bootstrap/tests/programs/*.wlo "$root"/bootstrap/tests/core/*.wlo
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
    ok=1
    if (cd "$dir" && "$willow0" build "$name.wlo" -o "$work/$name") >"$work/out" 2>"$work/err"; then
        (cd "$dir" && "$willow0" compile "$name.wlo" -o "$work/a.ssa" &&
            "$willow0" compile "$name.wlo" -o "$work/b.ssa")
        if ! cmp -s "$work/a.ssa" "$work/b.ssa"; then
            echo "FAIL $file: IL differs between compilations"
            ok=0
        fi
        (cd "$dir" && "$work/$name" <"$input" >"$work/out" 2>"$work/err")
        status=$?
    else
        status=1
    fi
    expected_status=0
    [ -f "$base.err" ] && expected_status=1
    if [ "$status" -ne "$expected_status" ]; then
        echo "FAIL $file: exit status $status, expected $expected_status"
        ok=0
    fi
    for stream in out err; do
        expected=/dev/null
        [ -f "$base.$stream" ] && expected=$base.$stream
        [ "$stream" = err ] && [ "${STAGE1:-0}" = 1 ] && [ -f "$base.stage1.err" ] && expected=$base.stage1.err
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
