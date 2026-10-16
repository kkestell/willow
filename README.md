# Willow

Willow is a small, statically typed language with Python-like syntax that
compiles to readable Lua and runs on LuaJIT. Source files use `.wlo`.
[docs/spec.md](docs/spec.md) specifies the language.

## Setup

Willow builds on macOS and on Linux with glibc 2.33 or newer, or musl.

```sh
make        # fetches and builds the pinned LuaJIT and the executable stub
make test   # runs the tests
```

`make test` passes on macOS 26 (arm64) and on Linux arm64 with glibc 2.36.

## Usage

Run `./willow` from the checkout, or link it onto your `PATH`; the launcher
follows symlinks to find its installation.

```sh
willow check hello.wlo                 # check the program without running it
willow run hello.wlo                   # check, then run on the bundled LuaJIT
willow run number.wlo out.txt          # arguments after the source go to sys.args()
willow compile hello.wlo -o hello.lua  # check, then write a standalone Lua file
luajit hello.lua                       # a compiled file needs only LuaJIT 2.1
willow build hello.wlo -o hello        # check, then write an executable
./hello                                # an executable needs nothing else
willow test examples/cart              # run the test_* functions of test_*.wlo files
willow test --check examples/cart      # check the tests without running them
```

Compiled Lua and built executables receive their own command-line arguments, as
in `luajit number.lua out.txt` or `./number out.txt`.

Programs that import `http` load the system libcurl when they make a request.
macOS includes it; on Linux, install `libcurl4` and `ca-certificates`. Programs
that do not import `http` have no extra dependencies.

Diagnostics go to stderr and program output to stdout. The exit status is 0 on
success and 1 for invalid usage, source errors, failed output, and runtime
errors, unless the program chooses its own with `sys.exit`.

## Editor support

`editors/vscode` is a VS Code extension for `.wlo` files with syntax
highlighting, four-space indentation, and a `$willow` problem matcher. Install it
by linking it into the extensions directory and restarting VS Code:

```sh
ln -s "$PWD/editors/vscode" ~/.vscode/extensions/willow
```

These tasks in `.vscode/tasks.json` check the program entry or test file open in
the editor and list its errors in the Problems panel. Library modules are checked
through an entry or test file that imports them.

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
