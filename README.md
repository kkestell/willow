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
To build a standalone Willow compiler and copy it to `~/.local/bin/willow`, run
`make install`. Add `~/.local/bin` to your `PATH` if needed.

## Usage

```sh
willow init                           # scaffold a project in the current directory
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
Seconds of wall-clock time, best of 3 runs, on AMD EPYC 9V45 96-Core Processor, Linux. In
parentheses is how many times faster Willow is than Python.

| Benchmark (size) | C | LuaJIT | Python | Willow (vs Python) |
|---|---:|---:|---:|---:|
| n-body (5,000,000) | 0.22 | 0.47 | 13.77 | 0.74 (18.6x) |
| spectral-norm (2,000) | 0.15 | 0.16 | 16.06 | 0.58 (27.9x) |
| fannkuch-redux (10) | 0.19 | 0.37 | 3.67 | 0.49 (7.5x) |
| binary-trees (18) | 0.92 | 5.61 | 38.00 | 4.43 (8.6x) |
| fasta (2,500,000) | 0.30 | 0.68 | 2.96 | 2.43 (1.2x) |
| mandelbrot (2,500) | 0.30 | 0.33 | 10.54 | 0.47 (22.6x) |
| k-nucleotide (2,500,000) | 0.40 | 0.45 | 2.20 | 0.94 (2.4x) |
| reverse-complement (5,000,000) | 0.06 | 1.65 | 0.32 | 4.81 (0.1x) |
| recursive (9) | 0.05 | 0.19 | 6.95 | 0.23 (30.5x) |
| nsieve (11) | 0.07 | 0.39 | 3.98 | 0.43 (9.4x) |
| matrix (10,000) | 0.08 | 0.31 | 8.51 | 0.84 (10.1x) |
| methcall (50,000,000) | 0.21 | 0.38 | 5.21 | 0.75 (6.9x) |
| except (1,000,000) | 0.03 | 1.00 | 0.41 | 6.09 (0.1x) |
| heapsort (2,000,000) | 0.30 | 0.68 | 7.07 | 0.89 (7.9x) |
| hash2 (5,000) | 0.45 | 0.26 | 4.16 | 1.91 (2.2x) |
| sumcol (10,000,000) | 0.18 | 0.49 | 0.73 | 1.86 (0.4x) |
| raytracer (200) | 0.10 | 0.43 | 8.63 | 0.54 (15.9x) |
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
