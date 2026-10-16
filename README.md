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
willow test examples/cart             # run tests
willow test --check examples/cart     # check tests without running
```

Compiled Lua files and executables take their own command-line arguments, for
example `luajit number.lua out.txt` or `./number out.txt`.

`willow test` accepts a test file or a directory of `test_*.wlo` files.

Error messages are written to stderr and program output to stdout. The exit
status is 0 on success and 1 for usage errors, source errors, output failures,
and runtime errors. A program can set its own status with `sys.exit`.

Programs that import `http` load the system libcurl when they make a request.
macOS includes libcurl. On Linux, install the `libcurl4` and `ca-certificates`
packages.

## Projects

A project is a directory containing a `willow.json` file. The file names the
entry module, the source root, any local dependency roots, and the test
directory. `examples/portcheck` is an example project. Its `willow.json` sets the
entry to `portcheck/main.wlo` under the source root `src`, and lists `vendor` as
a dependency root. The `textkit` modules in `vendor` are imported as
`textkit.table`.

In a project directory, the commands use `willow.json` when no source file is
given:

```sh
make
cd examples/portcheck
willow test
willow run -- 127.0.0.1:22
willow build -o portcheck
./portcheck --help
```

`willow test` runs every `test_*.wlo` file under `tests/`. Arguments after `--`
are passed to the program. `willow build` bundles all of the project's modules
into one executable.

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
