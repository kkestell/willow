# Async editor syntax

## Plan

`agents/plans/2026-10-20-013-async-editor-syntax.md`

## Summary

The VS Code grammar highlights the §15 async syntax. `async def` marks `async`
as `storage.modifier.async.willow` and the function name as before, `async`
before `with` and `await` are keywords instead of reserved words, and
`Coroutine` is a built-in type. `aio.Task` is a module class, so bare `Task`
stays an ordinary name. No other file changed; `agents/todo.md` has no
editor-syntax item to tick.

## Checks run

- `python3 -m json.tool editors/vscode/syntaxes/willow.tmLanguage.json`: parses.
- Pattern spot-check on §15 lines: `async def square(...)` gives
  `storage.modifier.async.willow` + `storage.type.function.willow` +
  `entity.name.function.willow`; `async with` gives the modifier plus
  `keyword.control.willow`; `await first` is `keyword.control.willow`;
  `Coroutine[int]` gives `support.type.willow`.
- `make test` not run: editor grammar change.
