# Willow

Willow is a small, statically typed language with Python-like syntax. The
compiler translates Willow source files (`.wlo`) into readable Lua, which runs on
LuaJIT. The language is specified in [docs/spec.md](docs/spec.md).

## Setup

Willow builds on macOS and on Linux with glibc 2.33 or newer or with musl. To
build it, run:

```sh
make
```

This fetches and builds a pinned version of LuaJIT and the stub used for
standalone executables. To run the test suite:

```sh
make test
```

The tests pass on macOS 26 (arm64) and on Linux arm64 with glibc 2.36.

The `willow` command is the `willow` script at the root of the checkout. You can
run it as `./willow`, or put a symlink to it in a directory on your `PATH`.

## Usage

```sh
willow check hello.wlo                # check without running
willow run hello.wlo                  # check and run
willow run number.wlo out.txt         # pass arguments to sys.args()
willow compile hello.wlo -o hello.lua # compile to a single Lua file
luajit hello.lua                      # run with LuaJIT 2.1
willow build hello.wlo -o hello       # build a standalone executable
./hello                              # run the executable
willow test examples/testing          # run tests
willow test --check examples/testing  # check tests without running
```

Compiled Lua files and executables take their own command-line arguments, for
example `luajit number.lua out.txt` or `./number out.txt`.

`willow test` accepts a test file or a directory of `test_*.wlo` files.

`examples/` has one program for each language feature, named after the feature,
with its output in a matching `.out` file. `examples/rosettacode/` has
solutions to Rosetta Code tasks.

Error messages are written to stderr and program output to stdout. The exit
status is 0 on success and 1 for usage errors, source errors, output failures,
and runtime errors. A program can set its own status with `sys.exit`.

Programs that import `http` load the system libcurl when they make a request.
macOS includes libcurl. On Linux, install the `libcurl4` and `ca-certificates`
packages.

## Projects

A project is a directory containing a `willow.json` file. The file names the
entry module, the source root, any local dependency roots, and the test
directory. `examples/projects` is an example project. Its `willow.json` sets the
entry to `vowels/main.wlo` under the source root `src`, and lists `vendor` as a
dependency root. The `tabulate` module in `vendor` is imported as
`tabulate.table`.

In a project directory, the commands use `willow.json` when no source file is
given:

```sh
make
cd examples/projects
willow test
willow run -- banana kiwi
willow build -o vowels
./vowels banana kiwi
```

`willow test` runs every `test_*.wlo` file under `tests/`. Arguments after `--`
are passed to the program. `willow build` bundles all of the project's modules
into one executable.

## Benchmarks

`benchmarks/` has seventeen programs from the Computer Language Benchmarks
Game, written in Willow and, for comparison, in C, Lua for LuaJIT, and Python.
Each language uses the same single-threaded algorithm, and the problem sizes are
smaller than the official ones so that Python finishes in reasonable time. Two
programs differ from the official ones: mandelbrot prints a checksum of the
image instead of the image, and k-nucleotide generates its sequence instead of
reading one from a file. reverse-complement reads the output of fasta for its
size, and sumcol reads its size in lines of random integers; the runner writes
both inputs. Willow runs as the Lua it compiles to, on the same LuaJIT as the
hand-written Lua. To time the Willow programs, run:

```sh
make
python3 benchmarks/run.py
```

Name benchmarks, such as `n-body`, to run only those. `--all` also times the
other languages, and `--readme` times every language and updates the table
below. Both need `cc` on the `PATH`. The runner checks the SHA-256 digest of
each program's output against `benchmarks/expected`.

The table below comes from the Benchmarks workflow in `.github/workflows`,
which runs on a GitHub-hosted runner and commits the result. It runs when a
push to `main` changes the compiler, the runtime, or the benchmarks, and it can
be started by hand from the Actions tab.

<!-- benchmarks:start -->
Seconds of wall-clock time, best of 3 runs, on AMD EPYC 9V74 80-Core Processor, Linux. In
parentheses is how many times faster Willow is than Python.

| Benchmark (size) | C | LuaJIT | Python | Willow (vs Python) |
|---|---:|---:|---:|---:|
| n-body (5,000,000) | 0.29 | 0.66 | 20.90 | 1.08 (19.4x) |
| spectral-norm (2,000) | 0.20 | 0.21 | 23.64 | 0.88 (26.9x) |
| fannkuch-redux (10) | 0.20 | 0.45 | 5.58 | 0.61 (9.1x) |
| binary-trees (18) | 1.03 | 4.70 | 28.44 | 5.26 (5.4x) |
| fasta (2,500,000) | 0.37 | 0.91 | 4.31 | 3.35 (1.3x) |
| mandelbrot (2,500) | 0.39 | 0.42 | 17.72 | 0.61 (29.2x) |
| k-nucleotide (2,500,000) | 0.25 | 0.44 | 2.89 | 1.16 (2.5x) |
<!-- benchmarks:end -->

## Editor support

`editors/vscode` contains a VS Code extension for `.wlo` files. It provides
syntax highlighting, four-space indentation, and a `$willow` problem matcher. To
install it, link it into the VS Code extensions directory and restart VS Code:

```sh
ln -s "$PWD/editors/vscode" ~/.vscode/extensions/willow
```

To show Willow errors in the Problems panel, add these tasks to
`.vscode/tasks.json`. They check the entry file or test file that is open in the
editor. To check a library module, run a task on an entry or test file that
imports it.

```json
{
  "version": "2.0.0",
  "tasks": [
    {
      "label": "willow check",
      "type": "shell",
      "command": "willow check ${relativeFile}",
      "problemMatcher": "$willow"
    },
    {
      "label": "willow test --check",
      "type": "shell",
      "command": "willow test --check ${relativeFile}",
      "problemMatcher": "$willow"
    }
  ]
}
```
