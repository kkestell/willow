# Willow

Willow is a small, statically typed language with Python-like syntax. The
self-hosting compiler translates Willow source files (`.wlo`) into native code
through QBE. The language is specified in [docs/spec.md](docs/spec.md).

## Setup

Willow builds on macOS and on Linux. Building it needs a Rust toolchain
(`cargo`), and building programs with it needs QBE 1.3, a C compiler (`cc`),
and libgc (bdw-gc), found through `pkg-config` when it is available. To build
the compiler as `build/willow`, run:

```sh
make
```

To run the test suite:

```sh
make test
```

To copy the compiler to `~/.local/bin/willow`, run `make install`. Add
`~/.local/bin` to your `PATH` if needed.

## Usage

```sh
willow init                           # scaffold a project in the current directory
willow check hello.wlo                # check without running
willow run hello.wlo                  # check and run
willow run number.wlo out.txt         # pass arguments to sys.args()
willow compile hello.wlo -o hello.ssa  # emit QBE intermediate language
willow build hello.wlo -o hello       # build a standalone executable
./hello                              # run the executable
willow test examples/testing          # run tests
willow test --check examples/testing  # check tests without running
```

Built executables take their own command-line arguments, for example
`./number out.txt`.

`willow test` accepts a test file or a directory of `test_*.wlo` files.

`examples/` has one program for each language feature, named after the feature,
with its output in a matching `.out` file. `examples/tour.wlo` is one short
program that uses most of the language. `examples/rosettacode/` has solutions to
Rosetta Code tasks.

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

`willow init` creates a project in the current directory: `willow.json`,
`src/main.wlo`, `tests/test_main.wlo`, an `AGENTS.md` that introduces the
language and the commands, a `.gitignore`, and a git repository. It leaves
existing files alone.

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
both inputs. Willow runs as native executables. The hand-written Lua programs
are independent comparisons. To time the Willow programs, run:

```sh
make
python3 benchmarks/run.py
```

Name benchmarks, such as `n-body`, to run only those. `--all` also times the
other languages, and `--readme` times every language and updates the table
below. Both need `cc` and an independently installed `luajit` on the `PATH`;
the default Willow benchmarks need no LuaJIT. The runner checks the SHA-256
digest of each program's output against `benchmarks/expected`.

Run benchmarks locally on your Mac. To refresh the table below with results
from your machine, run:

```sh
python3 benchmarks/run.py --readme
```

<!-- benchmarks:start -->
Seconds of wall-clock time, best of 3 runs, on Apple M4, Darwin. Willow
(LuaJIT) is the earlier implementation, which compiled to Lua, recorded on an
Apple M4 on 2026-10-21.

| Benchmark (size) | C | LuaJIT | Python | Willow (LuaJIT) | Willow (Native) |
|---|---:|---:|---:|---:|---:|
| n-body (5,000,000) | 0.15 | 0.31 | 12.09 | 0.36 | 0.95 |
| spectral-norm (2,000) | 0.12 | 0.12 | 12.29 | 0.51 | 0.98 |
| fannkuch-redux (10) | 0.13 | 0.21 | 2.64 | 0.30 | 1.33 |
| binary-trees (18) | 0.84 | 2.81 | 11.17 | 2.20 | 0.82 |
| fasta (2,500,000) | 0.22 | 0.48 | 2.51 | 1.98 | 1.48 |
| mandelbrot (2,500) | 0.18 | 0.32 | 8.32 | 0.40 | 1.26 |
| k-nucleotide (2,500,000) | 0.20 | 0.28 | 1.58 | 0.59 | 1.94 |
| reverse-complement (5,000,000) | 0.10 | 1.32 | 0.27 | 3.22 | 3.47 |
| recursive (9) | 0.16 | 0.13 | 2.71 | 0.16 | 0.25 |
| nsieve (11) | 0.09 | 0.40 | 2.74 | 0.42 | 0.92 |
| matrix (10,000) | 0.06 | 0.32 | 6.08 | 0.67 | 2.71 |
| methcall (50,000,000) | 0.18 | 0.30 | 4.18 | 0.57 | 0.99 |
| except (1,000,000) | 0.56 | 0.07 | 0.31 | 3.87 | 0.98 |
| heapsort (2,000,000) | 0.19 | 0.43 | 3.43 | 0.47 | 0.90 |
| hash2 (5,000) | 0.54 | 0.20 | 4.02 | 1.07 | 3.23 |
| sumcol (10,000,000) | 0.30 | 0.88 | 0.62 | 1.86 | 0.54 |
| raytracer (200) | 0.05 | 0.29 | 7.56 | 0.38 | 0.71 |
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
