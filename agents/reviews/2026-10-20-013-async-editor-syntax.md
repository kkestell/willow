# Async editor syntax

## Scope and coverage

The staged changes for `agents/plans/2026-10-20-013-async-editor-syntax.md`:
the `async def` declaration pattern, the `async with` modifier, the `await`
keyword, and the `Coroutine` built-in type in
`editors/vscode/syntaxes/willow.tmLanguage.json`. The review read them against
spec §1 (reserved words), §8 (statements), §14 `aio`, and §15, and compared
them with how the grammar scopes `def`, `lambda`, the control keywords, the
reserved words, and the other built-in types.

Gaps:

- The grammar was not loaded in VS Code. Patterns were checked with a small
  single-line TextMate tokenizer script, not with `vscode-textmate`.

## Summary

| ID | Severity | Category    | Fix   | Title                                                     |
| -- | -------- | ----------- | ----- | --------------------------------------------------------- |
| F1 | Low      | Correctness | Fixed | A stray `async` is colored as a control keyword           |
| F2 | Low      | Correctness | Fixed | The `async with` modifier scope includes trailing space   |

## F1. A stray `async` is colored as a control keyword

Low · Correctness · Fixed · `editors/vscode/syntaxes/willow.tmLanguage.json:128`

The change moved `async` from the reserved list into the `keyword.control`
list, though the plan adds only `await` there. Both valid forms, `async def`
and `async with`, are matched by earlier patterns, so the control-list entry
only ever colors an `async` that begins no construct, such as `async for`,
which §15 excludes. §1 makes such a use an error, and the grammar gives every
other reserved word without a construct the `keyword.other.reserved.willow`
scope.

### Evidence

The tokenizer gave `async for x in y:` the scope `keyword.control.willow` for
`async`.

### Fix

`async` is removed from the control list and returned to the reserved list.
The `async def` and `async with` patterns still match first, so valid uses
keep `storage.modifier.async.willow`, and `async for` now gets
`keyword.other.reserved.willow`.

## F2. The `async with` modifier scope includes trailing space

Low · Correctness · Fixed · `editors/vscode/syntaxes/willow.tmLanguage.json:125`

The pattern `\b(async)\s+(?=with\b)` consumed the whitespace after `async`, so
the `storage.modifier.async.willow` scope covered `async ` rather than the
keyword. Themes that underline or set a background for the scope show it on
the space, and the `async def` pattern scopes only the word.

### Evidence

The tokenizer reported the token `'async '` for
`async with aio.task_group() as group:`.

### Fix

The pattern is `\basync(?=\s+with\b)`, which scopes only `async`.

## Checks run

- `python3 -m json.tool` on the grammar: parses, before and after the fixes.
- The tokenizer on §15 and §14 sample lines: `async def square(...)`, an
  `async def` protocol method, `async with aio.task_group() as group:`,
  `with await listener.accept(...) as connection:`, `await (await c)`,
  `Coroutine[int]` and `aio.Task[int]` annotations, and `async_value`,
  `awaiting`, and `asyncio` identifiers. Each produced the scopes in the plan;
  `Task` stays unscoped and identifiers containing `async` or `await` are not
  matched.
- `make test` after the fixes: 336 passed, 0 failed.

## Verdict

The grammar highlights `async def`, `async with`, `await`, and `Coroutine` as
the plan specifies, consistently with `def` and the existing built-in types.
F1 and F2 were small scope mistakes for `async`; both are fixed.
