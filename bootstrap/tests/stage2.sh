#!/bin/sh
# Runs stage 2's tests and drivers, and the program tests with stage 2's
# compiler. willow1 compiles the tests, the drivers, and willow2, with the
# test library modules in bootstrap/tests/lib/ embedded along with lib/.
#
# A test exits with status 1 on a failure. A file driver takes every .wlo
# file in tests/ and examples/ and writes the first error in each to stderr as
# PATH:LINE:COL: error: MESSAGE. A program driver takes every entry program
# and writes the first error in each as ENTRY: DIAGNOSTIC. A file or program
# may have an error only when its NAME.err starts with the same diagnostic,
# written with paths relative to the program's directory, as the test runner,
# which runs each program from its own directory, sees it.
#
# The bind driver takes the entry programs that are programs: those with a
# main function, and test files. Its rule is the program drivers', so a
# program whose first error in the Lua implementation comes from its checker
# or at run time must bind without error. Besides, the programs in
# bind_errors, whose first error comes from loading or binding, and each case
# in bootstrap/tests/loader/ and bootstrap/tests/bind/ must report the error
# its NAME.err expects, so that a missed binder error fails too.
#
# willow2 then runs, through run.sh, all top-level programs in
# bootstrap/tests/programs/, core/, and check/, each
# bootstrap/tests/modules/*/main.wlo, and the programs in tests/programs/
# except those named in bootstrap/tests/pending, which stage 2 does not pass
# yet. Each case in bootstrap/tests/commands/ runs its script `command` with
# sh in a copy of its directory without `expected`, with WILLOW naming
# willow2; the script must
# exit with status 0, and its stdout and stderr together must equal the
# case's `expected`. Last, willow2 must emit the same IL for its own source as
# a willow2 built by itself.
#
# WILLOW1 names stage 1's compiler; it defaults to build/willow1, which make
# bootstrap builds.

set -u
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root" || exit 1
willow1=${WILLOW1:-$root/build/willow1}
case $willow1 in /*) ;; *) willow1=$PWD/$willow1 ;; esac
[ -x "$willow1" ] || {
    echo "stage2.sh: $willow1 not found; run make bootstrap" >&2
    exit 1
}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failed=0

# Stage 2's sources and the modules generated for them.
src=$work/src
bootstrap/prepare.sh compiler "$src" bootstrap/tests/lib || exit 1

# Builds stage 2's NAME.wlo.
build() {
    "$willow1" build "$src/$1.wlo" -o "$work/$1" && return 0
    echo "FAIL $1: does not compile"
    failed=1
    return 1
}

# Runs compiler/NAME.wlo, once built, with the remaining arguments.
run() {
    name=$1
    shift
    "$work/$name" "$@"
}

check_test() {
    build "$1" || return
    run "$1" || failed=1
}

# The .wlo files in tests/ and examples/.
files() {
    find tests examples -name '*.wlo' | sort
}

# The entry programs: the files above except the modules of tests/modules/*/
# other than main.wlo and the files of projects, whose imports need the
# project's roots; and the cases in bootstrap/tests/loader/ and
# bootstrap/tests/bind/.
entries() {
    projects=$(find tests examples -name willow.json | sed 's|willow.json$||')
    files | while IFS= read -r file; do
        case $file in
        tests/modules/*/main.wlo) ;;
        tests/modules/*) continue ;;
        esac
        for project in $projects; do
            case $file in "$project"*) continue 2 ;; esac
        done
        echo "$file"
    done
    find bootstrap/tests/loader bootstrap/tests/bind -name main.wlo | sort
}

# The entry programs with a main function, and test files, which have none;
# the other entries are modules that programs import.
programs() {
    entries | while IFS= read -r file; do
        case $file in
        */test_*) echo "$file" ;;
        *) grep -qE '^(async )?def main\(' "$file" && echo "$file" ;;
        esac
    done
}

# Runs driver NAME over the paths that command LIST writes; with "program" as
# KIND, each error line names its entry program first.
drive() {
    name=$1
    list=$2
    kind=$3
    build "$name" || return
    $list >"$work/files"
    # shellcheck disable=SC2046 # the paths have no spaces
    run "$name" $(cat "$work/files") >/dev/null 2>"$work/errors"
    status=$?
    if [ $status -gt 1 ]; then
        echo "FAIL $name: exit status $status"
        failed=1
    fi
    while IFS= read -r line; do
        path=${line%%:*}
        if [ "$kind" = program ]; then
            expected=${line#"$path: "}
        else
            expected=$(basename "$path")${line#"$path"}
        fi
        err=${path%.wlo}.err
        if [ ! -f "$err" ] || [ "$(head -n 1 "$err")" != "$expected" ]; then
            echo "FAIL $name $line"
            failed=1
        fi
    done <"$work/errors"
    echo "$name: $(wc -l <"$work/files" | tr -d ' ') ${kind}s, $(wc -l <"$work/errors" | tr -d ' ') with errors"
}

# The files above and core, whose `extern def` and `__type` only the parser
# checks here.
parsed_files() {
    files
    echo bootstrap/core/core.wlo
}

check_driver() {
    drive "$1" parsed_files file
}

check_program_driver() {
    drive "$1" entries program
}

# The programs in tests/ and examples/ whose first error comes from loading
# or binding.
bind_errors="tests/programs/unknown_escape.wlo tests/modules/missing_module/main.wlo"

check_bind_driver() {
    drive "$1" programs program
    for entry in $bind_errors bootstrap/tests/loader/*/main.wlo bootstrap/tests/bind/*/main.wlo; do
        err=${entry%.wlo}.err
        if ! grep -qxF "$entry: $(head -n 1 "$err")" "$work/errors"; then
            echo "FAIL $1 $entry: no error, expected $(head -n 1 "$err")"
            failed=1
        fi
    done
}

# The programs in tests/programs/ that stage 2 passes.
conformance() {
    for file in tests/programs/*.wlo; do
        grep -qxF "$(basename "$file" .wlo)" bootstrap/tests/pending || echo "$file"
    done
}

# Weak links and forced collection need callbacks outside ordinary Willow.
check_coroutines() {
    fixture=$root/bootstrap/tests/check/coroutine_runtime
    cp "$fixture/build.wlo" "$src/coroutine_fixture.wlo"
    if ! "$work/willow" build "$src/coroutine_fixture.wlo" -o "$work/coroutine-fixture" ||
        ! "$work/coroutine-fixture" "$fixture/callbacks.wlo" "$fixture/runtime.ssa" "$work/coroutine-runtime" ||
        ! "$work/coroutine-runtime"; then
        echo "FAIL coroutine runtime"
        failed=1
    fi
}

check_commands() {
    mkdir "$work/commands"
    for case in bootstrap/tests/commands/*/; do
        name=$(basename "$case")
        cp -R "$case" "$work/commands/$name"
        rm "$work/commands/$name/expected"
        (cd "$work/commands/$name" && WILLOW=$work/willow sh command >"$work/command.out" 2>&1)
        status=$?
        if [ $status -ne 0 ]; then
            echo "FAIL command $name: exit status $status"
            failed=1
        elif ! cmp -s "$case/expected" "$work/command.out"; then
            echo "FAIL command $name: output differs"
            diff "$case/expected" "$work/command.out" | sed 's/^/    /'
            failed=1
        fi
    done
}

check_willow() {
    build willow || return
    check_coroutines
    check_commands
    echo "willow2:"
    STAGE1=1 WILLOW0=$work/willow bootstrap/tests/run.sh bootstrap/tests/programs/*.wlo \
        bootstrap/tests/core/*.wlo bootstrap/tests/check/*.wlo bootstrap/tests/modules/*/main.wlo || failed=1
    echo "willow2 tests/programs:"
    # shellcheck disable=SC2046 # the paths have no spaces
    WILLOW=$root/willow WILLOW0=$work/willow bootstrap/tests/run.sh $(conformance) || failed=1
    if ! "$work/willow" build "$src/willow.wlo" -o "$work/willow-self"; then
        echo "FAIL willow2-self: does not compile"
        failed=1
        return
    fi
    if ! "$work/willow" compile "$src/willow.wlo" -o "$work/willow.ssa" ||
        ! "$work/willow-self" compile "$src/willow.wlo" -o "$work/willow-self.ssa"; then
        echo "FAIL fixpoint: does not compile"
        failed=1
        return
    fi
    if ! cmp -s "$work/willow.ssa" "$work/willow-self.ssa"; then
        echo "FAIL fixpoint: IL differs between willow2 and willow2-self"
        failed=1
    fi
}

check_test lexer_test
check_test parser_test
check_test types_test
check_test bind_test
check_driver parse_files
check_program_driver load_files
check_bind_driver bind_files
check_willow

exit $failed
