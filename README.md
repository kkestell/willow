# Willow

Willow is a small, statically typed language with Python-like syntax that
compiles to readable Lua and runs on LuaJIT. Source files use `.wlo`.
[willow.md](willow.md) describes the language.

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
willow compile hello.wlo -o hello.lua  # check, then write a standalone Lua file
luajit hello.lua                       # a compiled file needs only LuaJIT 2.1
willow build hello.wlo -o hello        # check, then write an executable
./hello                                # an executable needs nothing else
```

Diagnostics go to stderr and program output to stdout. The exit status is 0 on
success and 1 for invalid usage, source errors, failed output, and runtime
errors.
