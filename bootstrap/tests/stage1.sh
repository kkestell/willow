#!/bin/sh
# Runs stage 1's tests and drivers. By default each is compiled with willow0
# and run natively; with --lua each runs under the Lua implementation
# (./willow run, after make), which helps when a stage 0 bug is suspected.
# Native runs also check that willow1 and a self-built willow1 emit identical
# IL for their own source.
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

# Builds bootstrap/stage1/NAME.wlo when native.
build() {
    [ $lua -eq 1 ] && return 0
    "$willow0" build "bootstrap/stage1/$1.wlo" -o "$work/$1" && return 0
    echo "FAIL $1: does not compile"
    failed=1
    return 1
}

# Runs bootstrap/stage1/NAME.wlo, once built, with the remaining arguments.
run() {
    name=$1
    shift
    if [ $lua -eq 1 ]; then
        ./willow run "bootstrap/stage1/$name.wlo" "$@"
    else
        "$work/$name" "$@"
    fi
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

# Writes the module core_source to DIR/core_source.wlo: core's text as one
# string, which willow1 compiles into every program.
core_source() {
    {
        printf 'def text() -> str:\n    return "'
        sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/$/\\n/' bootstrap/core/core.wlo | tr -d '\n'
        printf '"\n'
    } >"$1/core_source.wlo"
}

# Builds willow1 from stage 1's sources and core_source and runs all top-level
# programs in bootstrap/tests/programs/, core/, and check/ through run.sh, then
# the programs in tests/programs/ except those named in
# bootstrap/tests/stage1-pending, which stage 1 does not pass yet.
# Under --lua there is no willow1, since the Lua implementation has no core
# module for willow1 to import.
# The programs in tests/programs/ that stage 1 passes.
conformance() {
    for file in tests/programs/*.wlo; do
        grep -qxF "$(basename "$file" .wlo)" bootstrap/tests/stage1-pending || echo "$file"
    done
}

check_willow1() {
    [ $lua -eq 1 ] && return
    mkdir "$work/willow1-src"
    cp bootstrap/stage1/*.wlo "$work/willow1-src/"
    core_source "$work/willow1-src"
    if ! "$willow0" build "$work/willow1-src/willow1.wlo" -o "$work/willow1"; then
        echo "FAIL willow1: does not compile"
        failed=1
        return
    fi
    echo "willow1:"
    WILLOW0=$work/willow1 bootstrap/tests/run.sh bootstrap/tests/programs/*.wlo \
        bootstrap/tests/core/*.wlo bootstrap/tests/check/*.wlo || failed=1
    echo "willow1 tests/programs:"
    # shellcheck disable=SC2046 # the paths have no spaces
    WILLOW0=$work/willow1 bootstrap/tests/run.sh $(conformance) || failed=1
    if ! "$work/willow1" build "$work/willow1-src/willow1.wlo" -o "$work/willow1-self"; then
        echo "FAIL willow1-self: does not compile"
        failed=1
        return
    fi
    if ! "$work/willow1" compile "$work/willow1-src/willow1.wlo" -o "$work/willow1.ssa" ||
        ! "$work/willow1-self" compile "$work/willow1-src/willow1.wlo" -o "$work/willow1-self.ssa"; then
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
check_driver parse_files
check_program_driver load_files
check_bind_driver bind_files
check_willow1

exit $failed
