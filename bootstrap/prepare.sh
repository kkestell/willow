#!/bin/sh
# Usage: bootstrap/prepare.sh [--current] SRC OUT [LIBDIR...]
#
# Prepares a compiler's sources for building: copies SRC/*.wlo into the new
# directory OUT and writes the modules the loader embeds there. core_source
# holds core's text, which is compiled into every program, and lib_source the
# text of each module in lib/ and in each LIBDIR, by name. Run from the
# repository root.
#
# Stage 1 is frozen and parses only the capitalized literals. Its embedded
# core and library text, and stage 2's source when stage 1 builds it, are
# rewritten to that spelling with bootstrap/legacy_literals.awk. --current
# copies SRC unchanged for stage 2 to build itself from the lowercase sources.

set -eu
current=0
if [ "${1:-}" = "--current" ]; then
    current=1
    shift
fi
[ $# -ge 2 ] || {
    echo "usage: bootstrap/prepare.sh [--current] SRC OUT [LIBDIR...]" >&2
    exit 2
}
src=$1
out=$2
shift 2

legacy_source=0
if [ "$src" = "compiler" ] && [ "$current" = 0 ]; then
    legacy_source=1
fi
legacy_embedded=0
if [ "$src" = "bootstrap/stage1" ]; then
    legacy_embedded=1
fi

# Writes FILE's text escaped for a string literal, on one line.
quote() {
    sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/$/\\n/' | tr -d '\n'
}

# Copies or rewrites the source module FILE to NAME.wlo in OUT.
source_file() {
    file=$1
    name=$(basename "$file" .wlo)
    if [ "$legacy_source" = 1 ]; then
        LC_ALL=C awk -f bootstrap/legacy_literals.awk "$file" >"$out/$name.wlo"
    else
        cp "$file" "$out/$name.wlo"
    fi
}

# Writes the quoted text of FILE, in legacy form when stage 1 embeds it.
embedded() {
    file=$1
    if [ "$legacy_embedded" = 1 ]; then
        LC_ALL=C awk -f bootstrap/legacy_literals.awk "$file" | quote
    else
        quote <"$file"
    fi
}

mkdir "$out"
for file in "$src"/*.wlo; do
    source_file "$file"
done

{
    printf 'def text() -> str:\n    return "'
    embedded bootstrap/core/core.wlo
    printf '"\n'
} >"$out/core_source.wlo"

{
    printf 'def text(name: str) -> str:\n'
    for dir in lib "$@"; do
        for file in "$dir"/*.wlo; do
            printf '    if name == "%s":\n        return "' "$(basename "$file" .wlo)"
            embedded "$file"
            printf '"\n'
        done
    done
    printf '    return ""\n'
} >"$out/lib_source.wlo"
