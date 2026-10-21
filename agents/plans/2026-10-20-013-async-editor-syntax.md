# Async editor syntax

## Goal

Highlight the async syntax specified in §15 and §14 `aio` in the VS Code
grammar: `async` and `await` as keywords, `async def` and `async with`, and the
`Coroutine` type.

## Related code

- `editors/vscode/syntaxes/willow.tmLanguage.json`: `declaration` matches `def`,
  `class`/`enum`/`protocol`, and `type`; `keyword` lists control keywords and
  holds `async|await` in `keyword.other.reserved`; `builtin` lists built-in
  types.
- `docs/spec.md` §15: `async def`, `async with`, `await`, and `Coroutine[T]`
  as a reserved opaque nominal type. §14 `aio` declares `Task`, `TaskGroup`,
  and `task_group()` as module classes and a function.

## Decisions

- `async def` gets its own `declaration` pattern, so `async` is
  `storage.modifier.async.willow` and the name is still
  `entity.name.function.willow`. The plain `def` pattern follows it unchanged.
- `async` before `with` is a `storage.modifier.async.willow`, matching the
  `async def` form, and `await` joins the `keyword.control` list. Neither is a
  reserved word.
- `Coroutine` joins the built-in type list: §1 lists it with the reserved type
  names. §14 declares `Task` as `aio.Task`, so a bare `Task` is an ordinary
  name and highlighting it would mis-color a user class.

## Checks

- `python3 -m json.tool editors/vscode/syntaxes/willow.tmLanguage.json` parses.
- Spot-check the patterns against §15 sample lines: `async def`, `async with`,
  `await`, and a `Coroutine[int]` annotation.
- No `make test`: this is an editor grammar change.
