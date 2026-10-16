# Compiler simplification audit

## Scope and coverage

Reviewed all 15 Lua files in `compiler/` for chances to simplify the code, make
it cheaper to change, or make it easier to follow. Covered lexing, parsing,
binding, types, checking, lowering, emission, runtime assembly, module loading,
manifests, the CLI, and the test runner. Behavior was traced against
`docs/spec.md`. Runtime files were read only where compiler code depends on
them. No code was changed.

Gaps:

- `runtime/*.lua` was not reviewed beyond how the compiler names and selects
  helpers.
- Tests were read only to see which node kinds they depend on.
- This is a simplicity audit. It did not hunt for correctness bugs beyond what
  the traced code exposed, and none turned up.

## Summary

| ID | Severity | Category     | Fix            | Title                                                                  |
| -- | -------- | ------------ | -------------- | ---------------------------------------------------------------------- |
| F1 | Medium   | Architecture | Needs plan     | Callable signatures come in five shapes, each with its own check path   |
| F2 | Low      | Architecture | Trivial        | The standard-library catalog fills almost half of the binder            |
| F3 | Low      | Naming       | Needs decision | "Class" and "record" each name several different things                 |
| F4 | Low      | API design   | Needs decision | Runtime helper names default to the bare function name                  |
| F5 | Low      | Simplicity   | Trivial        | Each native type repeats the same declaration boilerplate               |
| F6 | Low      | Simplicity   | Trivial        | Two passes each walk statements to collect assigned names               |
| F7 | Low      | Simplicity   | Trivial        | Lowering swaps the output buffer by hand in five places                 |
| F8 | Low      | Comments     | Trivial        | The comment on `subprocess.run` describes a collision that can no longer happen |
| F9 | Low      | Simplicity   | Trivial        | ENOENT is defined twice, once as a bare `2`                             |

## F1. Callable signatures come in five shapes, each with its own check path

Medium · Architecture · Needs plan · `compiler/check.lua:94`

Parameters are described five different ways depending on what is being
called:

- User functions, methods, and record constructors use `Param` and `FieldDecl`
  nodes with `name`, `type`, and `default` (`compiler/parser.lua:588`).
- Built-in functions and native methods use parallel `params`, `names`, and
  `defaults` arrays. `defaults` is keyed by parameter index, and `"any"` marks
  an unchecked parameter (`compiler/bind.lua:26`). `builtin_params` turns them
  into a third form, `{ name, default }`, for `bind_args`
  (`compiler/check.lua:275`).
- String methods use `{ { params }, result }` pairs (`compiler/check.lua:72`).
- List, dict, and bytes methods are an `if` chain in `method_signature`
  (`compiler/check.lua:102`).
- `list.sort` has its own `SORT_PARAMS` (`compiler/check.lua:283`, `:577`), and
  `range` repeats its arity and keyword checks by hand
  (`compiler/check.lua:820`).

Because of this, the `Call` branch of `check_expression`
(`compiler/check.lua:450`–`498`) runs two argument-binding and
argument-checking paths side by side and repeats `builtin and` eight times. It
also recognizes built-ins by their short name (`print`, `eprint`, `str`, `len`,
`sorted`, and `exit` at `:757`). Any provided-module function with one of those
names would silently get that special handling. `MethodCall`
(`:559`–`588`) has the same split. Adding a library function or method means
learning whichever shape it falls under. Index-keyed `defaults` sitting beside
a separate `names` array is easy to misalign.

### Fix

Describe every callable's parameters as `{ name, type, default }`, with no
`type` for an unchecked parameter. Built-in and native-method tables, string
and collection methods, and `sort` would all use this shape. Then
`bind_args` and the argument loop can serve every callee. `builtin_params`,
`SORT_PARAMS`, and the `"any"` sentinel can go. Built-in-specific checks can
key on the target object instead of its name. This needs a plan because it
rewrites the roughly 400-line signature catalog in `bind.lua` together with
`check.lua` and the parts of `lower.lua` that read `target.params`. Lowering
and diagnostics must stay unchanged.

## F2. The standard-library catalog fills almost half of the binder

Low · Architecture · Trivial · `compiler/bind.lua:21`

Lines 21–464 of `bind.lua`'s 1021 hold built-in functions, built-in
exceptions, and the signatures of the ten provided modules. That is data, not
name resolution. A reader looking for binding logic has to scroll past it, and
every library addition edits the binder. `check.lua` and `loader.lua` already
treat it as a separate catalog through `bind.exceptions` and `bind.modules`.

### Fix

Move lines 21–464 (`optional_*`, `builtins_of`, `builtins`, `exception`,
`exceptions`, `provided_record`, `provided`, every provided module and native
record, and the modules table) into a new `compiler/stdlib.lua`. It should
return `{ builtins = builtins, exceptions = exceptions, modules = modules }`.
In `bind.lua`, add `local stdlib = require("compiler.stdlib")` and
`local builtins, exceptions = stdlib.builtins, stdlib.exceptions`, and delete
`M.exceptions` and `M.modules`. Point `check.lua:657` at
`stdlib.exceptions.Exception` and `loader.lua:87` and `bind.lua:894` at
`stdlib.modules`.

## F3. "Class" and "record" each name several different things

Low · Naming · Needs decision · `compiler/parser.lua:604`

The spec says "class" 53 times and never says "record". The compiler calls a
class a `Record` node, a `record` type kind, and `type.record`. Meanwhile
"class" means four other things:

- The `Record` a method belongs to: `fn.class` (`compiler/bind.lua:964`).
- An unresolved type reference in `isinstance` and `except`: `node.class` and
  `handler.class` (`compiler/parser.lua:212`, `:393`). Its resolved
  declaration is then `class.record` (`compiler/bind.lua:720`).
- A type-name string in lowered `Construct` and handler nodes
  (`compiler/lower.lua:304`, `:529`).
- The generated `__wlo_class` field, which only exceptions carry.

Lines like `class.record and m == class.record.type`
(`compiler/check.lua:503`) take careful reading to decode.

### Fix

Give each concept one word. A suggestion: use the spec's "class" for the
declaration and its type kind, `ref` for unresolved references, and
`type_name` for lowered strings. This needs a decision on the vocabulary and on
whether the generated `__wlo_record` and `__wlo_class` field names change with
it. The rename touches every compiler pass, the runtime's `isinstance`, and
tests that match node kinds (`tests/unit/parser_test.lua:90`).

## F4. Runtime helper names default to the bare function name

Low · API design · Needs decision · `compiler/lower.lua:308`

A provided function lowers to the helper named by its `helper` field, or
otherwise to its short name. So `fs.join` becomes `__wlo_join`, `io.open`
becomes `__wlo_open`, and `sys.args` becomes `__wlo_args`. Eleven of the 42
provided functions override this by hand, with inconsistent conventions:
`process_run` for `subprocess.run`, `cli_parser_new` for `cli.parser`, and
`http_request` for `http.request`.

All helpers share one flat namespace. `runtime.reference` sends a name to
`__wlo_runtime.<name>` whenever any optional library defines it, and when two
libraries export the same name, the later one wins
(`compiler/runtime.lua:24`, `:44`). Adding a plausible function such as
`fs.open` or `net.join` would silently route calls to another module's
helper. Avoiding that today depends on someone noticing the overlap by hand.

### Fix

Have `provided` record each function's module name and default its helper to
`<module>_<name>`. Rename the 31 runtime functions that use bare names, and
drop the matching `helper` overrides. This needs a decision because it changes
helper names in generated Lua and in runtime files outside this review's
scope.

## F5. Each native type repeats the same declaration boilerplate

Low · Simplicity · Trivial · `compiler/bind.lua:102`

`File`, `Process`, `Args`, `Parser`, `Connection`, and `Listener` each spell
out `kind`, `name`, `type_name`, `fields = {}`, `native`, `prefix`, and
`native_methods`, then set `.type = types.record(...)` separately
(`compiler/bind.lua:102`, `:201`, `:265`, `:288`, `:393`, `:417`). Ordinary
provided records already have `provided_record` for this.

### Fix

Next to `provided_record`, add:

```lua
-- A native type: a provided record with no fields that only its module's
-- functions create. Its methods lower to helpers named after `prefix`.
local function native_record(module, name, prefix, methods)
  local record = {
    kind = "Record", name = name, type_name = module .. "." .. name, fields = {},
    native = true, prefix = prefix, native_methods = methods,
  }
  record.type = types.record(record)
  return record
end
```

Replace each of the six tables with a call such as
`local file = native_record("io", "File", "file", { read = ..., ... })`. Delete
the six `.type = types.record(...)` lines and the comment at lines 100–101.

## F6. Two passes each walk statements to collect assigned names

Low · Simplicity · Trivial · `compiler/check.lua:208`

`collect_symbols`'s inner `walk` (`compiler/bind.lua:476`) and
`assigned_symbols` (`compiler/check.lua:208`) recurse through the same
`If`/`While`/`For`/`Try` structure to find every `Assign`, `For` name, and
named `except` handler. One records first assignments, and the other collects
symbols. If a new statement kind that assigns or nests is added, both walkers
must be updated in step.

### Fix

Add to `compiler/ast.lua`:

```lua
-- Calls `visit(node)` for each Assign, For, and named except handler in
-- `body` and its nested blocks, outer before inner; `node.name` is the name
-- it assigns.
function M.assignments(body, visit)
  for _, statement in ipairs(body) do
    local kind = statement.kind
    if kind == "Assign" or kind == "For" then
      visit(statement)
    end
    if kind == "If" then
      M.assignments(statement.body, visit)
      if statement.else_body then
        M.assignments(statement.else_body, visit)
      end
    elseif kind == "While" or kind == "For" then
      M.assignments(statement.body, visit)
    elseif kind == "Try" then
      M.assignments(statement.body, visit)
      for _, handler in ipairs(statement.handlers) do
        if handler.name then
          visit(handler)
        end
        M.assignments(handler.body, visit)
      end
      if statement.finally_body then
        M.assignments(statement.finally_body, visit)
      end
    end
  end
end
```

In `collect_symbols`, replace `walk` with an `ast.assignments(fn.body, ...)`
call whose visitor adds `{ name = node.name, span = node.span }` when
`scope[node.name]` is unset. In `check.lua`, define `assigned_symbols(body,
result)` as `ast.assignments(body, function(node) result[node.symbol] = true
end)` followed by `return result`.

## F7. Lowering swaps the output buffer by hand in five places

Low · Simplicity · Trivial · `compiler/lower.lua:215`

`lower_short_circuit` (`:215`), `While` (`:463`), `Assert` (`:504`), the `Try`
resume block (`:536`), and `lower_block` (`:555`) each save `out`, set it to
`{}`, emit, take the result, and restore `out`. Each copy has to restore in the
right order, and the save and restore are separated by the code that matters.

### Fix

In `lower_function`, after `emit`, add:

```lua
-- Runs `f`, returning the statements it emits and its result.
local function capture(f)
  local outer = out
  out = {}
  local value = f()
  local body = out
  out = outer
  return body, value
end
```

Rewrite the five sites with it. For example,
`node.setup, node.condition = capture(function() return lower_operand(statement.condition) end)`,
and `lower_block` becomes `return (capture(function() for _, s in ipairs(body) do lower_statement(s) end end))`.

## F8. The comment on `subprocess.run` describes a collision that can no longer happen

Low · Comments · Trivial · `compiler/bind.lua:223`

The comment says a runtime helper named `run` would replace the one that runs
`main`. Since optional runtimes became scoped blocks exported through
`__wlo_runtime`, it no longer would. The emitter calls the core `__wlo_run`
directly (`compiler/emit.lua:414`, `:418`).

### Evidence

Temporarily renamed `__wlo_process_run` to `__wlo_run` in `runtime/host.lua`
and removed the `helper = "process_run"` override. A program calling
`subprocess.run(["echo", "hi"], capture_output=True)` and printing the return
code printed `0` and exited 0. The edit was reverted.

### Fix

Delete `compiler/bind.lua:223`.

## F9. ENOENT is defined twice, once as a bare `2`

Low · Simplicity · Trivial · `compiler/manifest.lua:44`

`loader.lua:23` declares `local ENOENT = 2`. `manifest.lua:44` tests
`code == 2 -- ENOENT` against the result of the same `loader.read`.

### Fix

In `loader.lua`, replace `local ENOENT = 2` with `M.ENOENT = 2` and use
`M.ENOENT` at lines 67 and 79. In `manifest.lua:44`,
write `if code == loader.ENOENT then`.

## Checks run

- A script loaded `compiler.bind` and mapped every provided-module function and
  native method to its runtime helper. All 42 functions and every native method
  resolve to a defined helper, 11 functions use a `helper` override, and no
  helper name is defined in more than one runtime file.
- The F8 experiment described above, run with `./willow run` and then
  reverted. `git status` was clean afterward.
- `make test` was not run because no code changed.

## Verdict

The compiler is small and mostly direct. No correctness defects turned up. The
change most worth making is F1: a single parameter shape for every callable
would remove the duplicated paths in call and method checking. F2 and F5–F9 are
mechanical cleanups. F3 and F4 need a naming decision before anyone acts on
them.
