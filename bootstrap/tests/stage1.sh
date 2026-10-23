#!/bin/sh
# Runs stage 1's tests and drivers. By default each is compiled with willow0
# and run natively; with --lua each runs under the Lua implementation
# (./willow run, after make), which helps when a stage 0 bug is suspected.
#
# A test exits with status 1 on a failure. A file driver takes every .wlo
# file in tests/ and examples/ and writes the first error in each to stderr as
# PATH:LINE:COL: error: MESSAGE. A program driver takes every entry program
# and writes the first error in each as ENTRY: DIAGNOSTIC. A file or program
# may have an error only when its NAME.err starts with the same diagnostic,
# written with paths relative to the program's directory, as the test runner,
# which runs each program from its own directory, sees it.
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
# project's roots; and the loader's cases in bootstrap/tests/loader/.
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
    find bootstrap/tests/loader -name main.wlo | sort
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

check_test lexer_test
check_test parser_test
check_test types_test
check_test bind_test
check_driver parse_files
check_program_driver load_files

exit $failed
