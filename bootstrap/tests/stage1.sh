#!/bin/sh
# Runs stage 1's unit tests and checks that willow1 compiles itself. Stage 1
# is frozen: its job is to build stage 2, which bootstrap/tests/stage2.sh
# tests along with the programs. Each test is compiled with willow0 and run
# natively. The fixpoint check builds willow1 with itself and compares the
# IL both compilers emit for their own source. A test exits with status 1 on
# a failure.
#
# WILLOW0 names the compiler; it defaults to build/stage0/willow0.

set -u
if [ "$#" -ne 0 ]; then
    echo "usage: stage1.sh" >&2
    exit 1
fi
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root" || exit 1
willow0=${WILLOW0:-$root/build/stage0/willow0}
case $willow0 in /*) ;; *) willow0=$PWD/$willow0 ;; esac
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failed=0

# Stage 1's sources and the modules generated for them.
src=$work/src
bootstrap/prepare.sh bootstrap/stage1 "$src" || exit 1

# Builds stage 1's NAME.wlo.
build() {
    "$willow0" --legacy build "$src/$1.wlo" -o "$work/$1" && return 0
    echo "FAIL $1: does not compile"
    failed=1
    return 1
}

# Runs bootstrap/stage1/NAME.wlo, once built, with the remaining arguments.
run() {
    name=$1
    shift
    "$work/$name" "$@"
}

check_test() {
    build "$1" || return
    run "$1" || failed=1
}

check_willow1() {
    if ! "$willow0" --legacy build "$src/willow1.wlo" -o "$work/willow1"; then
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
