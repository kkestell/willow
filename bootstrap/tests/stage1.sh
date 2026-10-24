#!/bin/sh
# Runs stage 1's unit tests and checks that willow1 compiles itself. Stage 1
# is frozen: its job is to build stage 2, which bootstrap/tests/stage2.sh
# tests along with the programs. By default each test is compiled with
# willow0 and run natively; with --lua each runs under the Lua implementation
# (./willow run, after make), which helps when a stage 0 bug is suspected.
# Native runs also check that willow1 and a self-built willow1 emit identical
# IL for their own source. A test exits with status 1 on a failure.
#
# WILLOW0 names the compiler; it defaults to the release build of stage 0.

set -u
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root" || exit 1
willow0=${WILLOW0:-$root/bootstrap/stage0/target/release/willow0}
case $willow0 in /*) ;; *) willow0=$PWD/$willow0 ;; esac
lua=0
[ "${1:-}" = --lua ] && lua=1
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failed=0

# Stage 1's sources and the modules generated for them.
src=$work/src
bootstrap/prepare.sh bootstrap/stage1 "$src" || exit 1

# Builds stage 1's NAME.wlo when native.
build() {
    [ $lua -eq 1 ] && return 0
    "$willow0" build "$src/$1.wlo" -o "$work/$1" && return 0
    echo "FAIL $1: does not compile"
    failed=1
    return 1
}

# Runs bootstrap/stage1/NAME.wlo, once built, with the remaining arguments.
run() {
    name=$1
    shift
    if [ $lua -eq 1 ]; then
        ./willow run "$src/$name.wlo" "$@"
    else
        "$work/$name" "$@"
    fi
}

check_test() {
    build "$1" || return
    run "$1" || failed=1
}

# Under --lua there is no willow1, since the Lua implementation has no core
# module for willow1 to import.
check_willow1() {
    [ $lua -eq 1 ] && return
    if ! "$willow0" build "$src/willow1.wlo" -o "$work/willow1"; then
        echo "FAIL willow1: does not compile"
        failed=1
        return
    fi
    if ! "$work/willow1" build "$src/willow1.wlo" -o "$work/willow1-self"; then
        echo "FAIL willow1-self: does not compile"
        failed=1
        return
    fi
    if ! "$work/willow1" compile "$src/willow1.wlo" -o "$work/willow1.ssa" ||
        ! "$work/willow1-self" compile "$src/willow1.wlo" -o "$work/willow1-self.ssa"; then
        echo "FAIL fixpoint: does not compile"
        failed=1
        return
    fi
    if ! cmp -s "$work/willow1.ssa" "$work/willow1-self.ssa"; then
        echo "FAIL fixpoint: IL differs between willow1 and willow1-self"
        failed=1
    fi
}

check_test lexer_test
check_test parser_test
check_test types_test
check_test bind_test
check_willow1

exit $failed
