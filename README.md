# Willow

Willow is a small, statically typed language with Python-like syntax that
compiles to readable Lua and runs on LuaJIT. Source files use `.wlo`.
[willow.md](willow.md) describes the language.

## Setup

Willow builds on macOS and Linux.

```sh
make        # fetches and builds the pinned LuaJIT in vendor/luajit
make test   # runs the tests
```
