#!/bin/sh
# Usage: bootstrap/prepare.sh SRC OUT [LIBDIR...]
#
# Prepares a compiler's sources for building: copies SRC/*.wlo into the new
# directory OUT and writes the modules the loader embeds there. core_source
# holds core's text, which is compiled into every program, and lib_source the
# text of each module in lib/ and in each LIBDIR, by name. Run from the
# repository root.

set -eu
[ $# -ge 2 ] || {
    echo "usage: bootstrap/prepare.sh SRC OUT [LIBDIR...]" >&2
    exit 2
}
src=$1
out=$2
shift 2

# Writes FILE's text escaped for a string literal, on one line.
quote() {
    sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/$/\\n/' "$1" | tr -d '\n'
}

mkdir "$out"
cp "$src"/*.wlo "$out/"
{
    printf 'def text() -> str:\n    return "'
    quote bootstrap/core/core.wlo
    printf '"\n'
} >"$out/core_source.wlo"
{
    printf 'def text(name: str) -> str:\n'
    for dir in lib "$@"; do
        for file in "$dir"/*.wlo; do
            printf '    if name == "%s":\n        return "' "$(basename "$file" .wlo)"
            quote "$file"
            printf '"\n'
        done
    done
    printf '    return ""\n'
} >"$out/lib_source.wlo"
