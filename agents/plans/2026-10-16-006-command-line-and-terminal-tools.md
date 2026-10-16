# Command-line and terminal tools

## Goal

Implement `docs/spec.md` §21: the `cli` module (a native `Parser` with typed
option, flag, positional, and rest declarations, generated help, and a native
`Args` result with typed getters; `cli.UsageError` and `cli.HelpRequested`) and
the `terminal` module (`isatty`, `color_enabled`, `style`, `progress`,
`finish_progress`). Deliver a report CLI with help, typed options, styled
terminal output, progress, and clean piped output, and fold §21 into the
baseline spec.

## Related code

- `compiler/bind.lua` — `provided`, the native `file` and `process`
  declarations, `helper` names on provided builtins, and the built-in
  exception records.
- `compiler/check.lua` — `builtins` and native `methods` with `names` and
  `defaults`.
- `runtime/host.lua` — `__wlo_fd` and the `ffi` declarations.
- `runtime/core.lua` — `__wlo_parse_int`, `__wlo_parse_float`,
  `__wlo_format_float`, `__wlo_list`, `__wlo_fail`.
- `compiler/emit.lua` — `optional_runtimes`; `except` clauses match
  `__wlo_class` against the record's `type_name`.

## Decisions

- **Declarations.** `M.modules.cli` provides `parser` (helper
  `cli_parser_new`), the native `Parser` (prefix `cli_parser`) and `Args`
  (prefix `cli_args`) with the §21 methods, names, and defaults, and the
  exception records `UsageError` and `HelpRequested` (type names
  `cli.UsageError` and `cli.HelpRequested`, field `message` only), built like
  the built-in exceptions. `M.modules.terminal` provides `isatty`,
  `color_enabled`, `style`, `progress`, and `finish_progress`.
- **Runtime placement.** The parser is plain Lua in a new optional runtime
  `runtime/cli.lua`; it raises `cli.UsageError` and `cli.HelpRequested` through
  `__wlo_fail` with those class names. The terminal functions need `isatty` and
  `__wlo_fd`, so they join `runtime/host.lua`.
- **Schema.** A parser keeps its entries in declaration order:
  `{ name, kind = "str" | "int" | "float" | "flag" | "positional" | "rest",
  default, help, short, required }`. `ValueError` messages:
  `invalid name '<name>'` (pattern `^%a[%w]*(-[%w]+)*$`),
  `invalid short option '<short>'`, `duplicate name '<name>'`,
  `duplicate short option '-<x>'`, `'help' and 'h' are reserved`,
  `only one rest argument is allowed`, and
  `positional '<name>' follows the rest argument`.
- **Parsing.** Arguments are scanned once. After `--` everything is positional.
  `--help` or `-h` in option position raises `HelpRequested` with the help text.
  `--name=value` splits at the first `=`; `--name` and `-x` take the next
  argument as the value. Any other argument beginning with `-` and longer than
  `-` is an option. Values convert with `__wlo_parse_int` and
  `__wlo_parse_float` under `pcall`. A `UsageError` message is the usage line,
  a newline, and `<prog>: error: <problem>`, where the problem is one of
  `unknown option '<arg>'`, `option '--<name>' needs a value`,
  `option '--<name>' takes no value`,
  `option '--<name>' expects an integer, received '<value>'` (or `a number`),
  `option '--<name>' is required`, `missing argument '<name>'`, and
  `unexpected argument '<arg>'`.
- **Help.** `help()` returns, each line ending in `\n`:
  `usage: <prog> [options] <positional>... [<rest> ...]`, a blank line and the
  description when there is one, then `arguments:` (when there are positionals)
  and `options:` sections whose left column is padded to the longest entry plus
  two spaces. `-h, --help` comes first with `show this help and exit`. A value
  option's entry is `-x, --name METAVAR` (or `--name METAVAR`), with the
  upper-case name, hyphens as underscores, as the metavar; its help is followed
  by `(required)` or, for a non-empty default, `(default: <value>)`, with
  floats written as `str` writes them.
- **Args.** `parse` returns `{ __wlo_record = "cli.Args", values, kinds }`, a
  snapshot. A getter whose name is unknown raises `ValueError`
  `no argument named '<name>'`; one of the wrong kind raises
  `'<name>' is not a str argument` (`an int`, `a float`, `a bool`, `a list`). Positionals are read
  with `get_str`; `get_list` returns a new list.
- **Terminal.** `isatty` uses C `isatty` on the handle's descriptor and
  `color_enabled` adds `TERM ~= "dumb"` and an unset `NO_COLOR`. `style`
  validates the color first (`unknown color '<color>'`), then returns the text
  unchanged when disabled or when there is nothing to apply, and otherwise
  wraps it in `ESC[<codes>m` and `ESC[0m` with `1` for bold and 30–37 for the
  colors. `progress` rejects CR and LF
  (`progress message cannot contain a line break`) and, when stderr is a
  terminal and `TERM` is not `dumb`, writes `\r ESC[K <message>` to
  `io.stderr` and flushes. `finish_progress` writes `\r ESC[K` on such a
  terminal, then the message and a newline when it is not empty, and flushes.

## Test plan

- `tests/unit/check_test.lua`: getters typed `str`, `int`, `float`, `bool`,
  `list[str]`; `parser.add_int("n", "x")` rejected; `cli.Parser()` rejected;
  `except cli.UsageError as e` gives `e.message`; `terminal.style("x",
  color="red", bold=True, enabled=False)` typed `str`.
- `tests/programs/cli_parsing.wlo` and `.out`: each option form, repeated
  values and flags, `--` before a dash value, a value starting with `-`,
  options among positionals, rest collection, typed getters, required options,
  defaults, the help text exactly, `HelpRequested` from `-h` and `--help`, each
  `UsageError` message, schema `ValueError`s, wrong getter name and type, and
  that `get_list` returns a copy.
- `tests/programs/terminal_styles.wlo` and `.out`: `style` with each color,
  bold, default, disabled, and an unknown color; `isatty` and `color_enabled`
  false for redirected streams; `progress` writes nothing when stderr is not a
  terminal; `finish_progress` writes only its message; a message with a line
  break raises.
- `tests/unit/cli_test.lua` `report_example`: help with `--help` (status 0),
  a usage error (status 2), a piped run over a sample log (no escape sequences
  on stdout, nothing on stderr but the final message), and, where `script`
  can give the program a terminal, a run whose output contains the color and
  progress sequences.

## Implementation plan

1. `compiler/bind.lua`, `compiler/check.lua`: the `cli` and `terminal`
   declarations and signatures.
2. `runtime/cli.lua`; terminal helpers in `runtime/host.lua`; add `cli.lua` to
   `optional_runtimes`.
3. Tests above.
4. `examples/report.wlo`: `report [options] [file]` reads a log (stdin when no
   file is given), counts lines per level (the first word), and prints a table of
   the `--limit/-n` (default 10) most frequent levels, styled when
   `--color=auto|always|never` (default `auto`) allows, with `--sort=count|name`
   and a `--quiet/-q` flag that suppresses progress; progress goes to stderr
   every 1000 lines.
5. Fold §21 into `docs/spec.md` (§14 gains `### cli` and `### terminal`) and
   check off the milestone in `agents/todo.md`.

## Documentation updates

- `docs/spec.md`: `### cli` and `### terminal` in §14 with the declarations,
  parsing and help rules, and messages; the §21 heading keeps one sentence
  saying where its rules live; the top pointer and milestones introduction say
  sections 22–24 are unimplemented.
- `agents/todo.md`: check off §21.
