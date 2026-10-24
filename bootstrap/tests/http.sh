#!/bin/sh
# Runs the native HTTP client against the Willow server, without LuaJIT.
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
willow=${WILLOW:-$root/build/willow2b}
willow1=${WILLOW1:-$root/build/willow1}
work=$(mktemp -d)
server_pid=
tls_pid=
cleanup() {
    if [ -n "$server_pid" ]; then kill "$server_pid" 2>/dev/null || :; wait "$server_pid" 2>/dev/null || :; fi
    if [ -n "$tls_pid" ]; then kill "$tls_pid" 2>/dev/null || :; wait "$tls_pid" 2>/dev/null || :; fi
    rm -rf "$work"
}
trap cleanup EXIT
"$willow" build tests/http/server.wlo -o "$work/server"
"$work/server" >"$work/port" 2>"$work/server.err" &
server_pid=$!
tries=0
while [ ! -s "$work/port" ]; do
    tries=$((tries + 1))
    if [ "$tries" -ge 100 ] || ! kill -0 "$server_pid" 2>/dev/null; then
        cat "$work/server.err" >&2
        echo "HTTP server did not start" >&2
        exit 1
    fi
    sleep 0.05
done
port=$(head -n 1 "$work/port")
mkdir "$work/downloads"
for name in client streams async; do
    "$willow" build "tests/http/$name.wlo" -o "$work/$name"
    "$work/$name" "http://127.0.0.1:$port" "$work/downloads" >"$work/$name.out"
    sed "s/$port/PORT/g" "$work/$name.out" >"$work/normalized"
    diff -u "tests/http/$name.out" "$work/normalized"
done

kill "$server_pid"
wait "$server_pid" 2>/dev/null || :
server_pid=
mkdir "$work/tls"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$work/tls/key.pem" -out "$work/tls/cert.pem" -days 1 -subj /CN=localhost -addext subjectAltName=DNS:localhost >"$work/certificate.log" 2>&1
printf 'secure hello\n' >"$work/tls/hello.txt"
: >"$work/tls/empty.pem"
(cd "$work/tls" && exec openssl s_server -quiet -accept "$port" -cert cert.pem -key key.pem -WWW) >"$work/tls/server.log" 2>&1 &
tls_pid=$!
"$willow" build tests/http/tls.wlo -o "$work/tls-client"
"$work/tls-client" "$port" "$work/tls" >"$work/tls.out"
diff -u tests/http/tls.out "$work/tls.out"

# Change only the embedded library name to exercise a real request-time load
# failure without modifying system libraries or adding a runtime override.
bootstrap/prepare.sh compiler "$work/missing-src"
sed -e 's/libcurl.so.4/libwillow-missing.so/g' -e 's,/usr/lib/libcurl.4.dylib,/usr/lib/libwillow-missing.dylib,g' "$work/missing-src/core_source.wlo" >"$work/core_source.wlo"
mv "$work/core_source.wlo" "$work/missing-src/core_source.wlo"
"$willow1" build "$work/missing-src/willow.wlo" -o "$work/missing-compiler"
"$work/missing-compiler" build tests/http/load_failure.wlo -o "$work/load-failure"
"$work/load-failure" >"$work/load-failure.out"
diff -u tests/http/load_failure.out "$work/load-failure.out"
printf 'def main():\n    print("without http")\n' >"$work/plain.wlo"
"$work/missing-compiler" build "$work/plain.wlo" -o "$work/plain"
[ "$("$work/plain")" = "without http" ]
echo "HTTP integration passed"
