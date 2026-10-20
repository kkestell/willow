# Protocol values

## Goal

Method calls on protocol values work (spec §3 Protocols). A protocol value is
the underlying class or native value, unchanged by conversion. Each call
dispatches on the value's run-time type through a generated converter for that
type and protocol. The converter supplies the implementation's defaults for
omitted arguments and for extra optional parameters, matches keyword-only
parameters by name, and converts arguments and results between the protocol's
and the implementation's representations. Only the protocol's declared methods
can be called. The interim "method calls on protocol values are not supported
yet" error goes away.

Built-in values satisfy no protocol until the iteration milestone, so no new
run-time tags are needed now. Class values carry `__wlo_record`, exception
values `__wlo_class`, and every native value already carries `__wlo_record`
with its type name. Protocol bounds and the standard protocols belong to the
next task. Bound-method values read from protocol values (`f = shape.area`) stay
outside this task and keep the existing field error.

## Related code

- `compiler/types.lua`: `method` (substituted signature of a class, native, or
  protocol method), `compatible`, and `satisfies` decide protocol
  assignability.
- `compiler/check.lua`: the `MethodCall` branch (interim error), `bind_args`
  (fills omitted arguments with default copies and records `node.order`).
- `compiler/lower.lua`: `conversion`, `convert`, `lower_default`, `adapter`,
  the `MethodCall` branch, `lower_function`, and `M.lower`.
- `compiler/emit.lua`: class tables, `function_name`, `expr` kinds such as
  `Function`, `AdapterParam`, and `Helper`, and the chunk layout (locals, then
  function definitions).
- `runtime/core.lua`: `__wlo_box`, `__wlo_unbox`, `__wlo_convert`.
- `compiler/stdlib.lua`: native method tables. Native defaults are untyped
  literal nodes (`{ kind = "None" }`, `{ kind = "String", value = "" }`).
- `tests/programs/protocols.wlo`: the existing protocol program.

## Decisions

- **Dispatch.** Each protocol declaration that is the receiver of at least one
  call gets a table `__wlo_protocol_<escaped type_name>`, keyed by run-time type
  name (`value.__wlo_record or value.__wlo_class`). Each entry maps the
  protocol's method names to converters. A call `p.m(a, b)` emits
  `__wlo_protocol_P[p.__wlo_record or p.__wlo_class].m(p, a, b, site)`, with
  the arguments in the protocol's parameter order and the call's site index
  last, so native helpers report errors at the protocol call.
- **Entries.** For each called protocol, entries are generated for every class
  in the program and every native type of an imported library module that has
  a non-generic method of each declared name whose parameters match by
  position, name, keyword-only status, and defaults (the matching
  `compatible` already does). Types that never reach the protocol get unused
  entries; this avoids tracking which conversions happen where, including
  through generic functions and protocol-to-protocol assignment.
- **Converters work at the declaration level.** A converter is built from the
  protocol's and the implementation's declared signatures (types.method on
  `self_type or type`), so one converter serves every specialization. For each
  implementation parameter:
  - matched to protocol parameter `i`: `__wlo_p<i>`; if the protocol parameter
    has a default, `__wlo_given(__wlo_p<i>, <implementation default>)`
    replaces the omitted-argument marker; then a representation conversion
    from the protocol's to the implementation's declared type;
  - unmatched (an extra optional parameter): the implementation's default.
  The result converts from the implementation's to the protocol's declared
  type. Positions where either declared type mentions a type parameter pass
  through unconverted.
  When nothing changes, the entry is the method or native helper itself.
- **Omitted arguments.** A protocol call passes `__wlo_omitted`, a unique table
  in `runtime/core.lua`, for each argument it leaves to a default, so the
  implementation's default applies and an explicit `None` stays `None`.
  `__wlo_given(value, default)` returns `default` when `value` is the marker.
- **Representation restriction.** Floats are raw or boxed depending on the
  static type, and type-parameter positions hold whatever their specialization
  uses, which the underlying value does not record. A declaration-level
  converter therefore cannot convert at those positions. To keep dispatch
  sound, `compatible` additionally requires:
  1. at a position where either declared type mentions a type parameter, no
     representation conversion between the substituted types;
  2. for a protocol source (protocol-to-protocol), no conversion at any
     position, and at a position generic in the target but not in the source,
     a source type without floats in unions, tuples, or callables.
  So `Circle` with `get(self) -> float` satisfies `Source[float]` and a
  protocol declaring `get(self) -> int | float`, but not `Source[int | float]`;
  `Box[float]` does not satisfy `Source[int | float]`. These programs are
  allowed by the spec and are now rejected with the usual "expected P,
  received C" error. This is the one departure from the spec; it is reported
  to the user rather than written into the spec.
- `types.converts(from, to)` reports whether a value changes representation,
  mirroring `lower.conversion`: float boxing, tuple positions, and callable
  parameters and results. `types.method` marks each parameter and the result
  `generic` when its declared type mentions a type parameter.
  `types.match(want, have)` returns the implementation parameter index for
  each protocol parameter, or nil, and `compatible` uses it.
- **Check.** A `MethodCall` on a protocol value binds arguments against
  `types.method(object, name)` (names, defaults, keyword-only), types the result
  from it, and sets `node.protocol` to the protocol declaration. An undeclared
  method reports the existing "type P has no method 'm'".
- **Lowering.** The call lowers to a `Call` whose callee is a `Dispatch` node,
  so evaluation order and spilling follow other calls. Converters for natives
  mark their helpers used so the optional runtime is included. Native defaults
  get their type from their literal kind.
- **Emission.** Protocol tables are declared as locals with the class tables,
  before function definitions, and filled after them, since entries refer to
  methods. A converter is
  `function(__wlo_p0, __wlo_p1, ..., __wlo_site) return ... end`, with
  `__wlo_p0` the receiver.

## Test plan

- `tests/programs/protocols.wlo` and `.out` (extend the existing program),
  printing each result:
  - `Shape.area()` and `scaled(2.0).area()` through a `list[Shape]` holding
    `Rect` and `Circle`; `Rect.scaled` has an extra keyword-only defaulted
    parameter, which the converter supplies.
  - A protocol method with a defaulted parameter whose implementation default
    differs: an omitted argument uses the implementation's default; an
    explicit `None` arrives as `None`.
  - A keyword-only protocol parameter matched to an implementation parameter
    at a different position, called by keyword.
  - Result conversion: a protocol method declared `-> int | float` served by a
    method returning `float` prints `2.5` and passes `isinstance(r, float)`;
    one served by a method returning `int` prints `3`.
  - Argument conversion: a protocol parameter `float` served by an
    implementation parameter `int | float` receives a float it can test with
    `isinstance`.
  - The native `io.stdout()` through `Writer.write_text(text=...)`.
  - Protocol to protocol: a `Shape` value assigned to a smaller `Area`
    protocol and called.
  - A generic body calling through `Source[T]`, with `Box[int]` and a class
    whose `get` returns `float` as `Source[float]`.
  - An exception class with a method, called through a protocol.
- `tests/unit/check_test.lua`:
  - replace the interim-error case with "type Shape has no method 'perimeter'";
  - argument and keyword errors through a protocol call (missing argument,
    unknown keyword) use the protocol's parameter names;
  - the restriction: `Box[float]` is not assignable to `Source[int | float]`
    and a class whose `get` returns `float` is not assignable to
    `Source[int | float]`, while the same class is assignable to a
    non-generic protocol declaring `get(self) -> int | float`; a protocol
    declaring `get(self) -> int | float` is not assignable to
    `Source[int | float]` (rule 2).
- A native helper failure through a protocol reports the protocol call's line:
  writing to a closed `io.File` through `Writer` raises `ValueError` whose
  traceback names that line (a program test with `.err`).
- `make test` passes.

## Implementation plan

1. `compiler/types.lua`: `match`, `converts`, `generic` flags in `method`, and
   the two rules in `compatible`/`satisfies`.
2. `compiler/check.lua`: protocol branch in `MethodCall`; drop the interim
   error. Update `check_test.lua`.
3. `runtime/core.lua`: `__wlo_omitted` and `__wlo_given`.
4. `compiler/lower.lua`: lower protocol calls to `Call` with a `Dispatch`
   callee and `Omitted` arguments; record called protocols; after lowering
   functions, build `lowered.protocols` with entries and converters; give
   native defaults a type.
5. `compiler/emit.lua`: declare and fill protocol tables; emit `Dispatch`,
   `Omitted`, converters, the receiver parameter, and the site parameter.
6. Extend `tests/programs/protocols.wlo`, add the native failure program, and
   run `make test`.
7. `agents/todo.md`: check off the protocol values item.
