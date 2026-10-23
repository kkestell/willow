#!/bin/sh
# Runs the stage 1 lexer under the Lua implementation (./willow run, after
# make): its own tests, then every .wlo file in tests/ and examples/. A file
# may fail to lex only when its NAME.err starts with the same diagnostic,
# written with the bare file name as the test runner, which runs each program
# from its own directory, sees it.

set -u
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root" || exit 1
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

failed=0
./willow run bootstrap/stage1/lexer_test.wlo || failed=1
find tests examples -name '*.wlo' | sort >"$work/files"
# shellcheck disable=SC2046 # the paths have no spaces
./willow run bootstrap/stage1/lex_files.wlo $(cat "$work/files") 2>"$work/errors"
while IFS= read -r line; do
    path=${line%%:*}
    expected=$(basename "$path")${line#"$path"}
    err=${path%.wlo}.err
    if [ ! -f "$err" ] || [ "$(head -n 1 "$err")" != "$expected" ]; then
        echo "FAIL $line"
        failed=1
    fi
done <"$work/errors"
echo "$(wc -l <"$work/files" | tr -d ' ') files lexed, $(wc -l <"$work/errors" | tr -d ' ') with errors"
exit $failed
