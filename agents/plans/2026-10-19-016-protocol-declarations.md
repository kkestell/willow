# Protocol declarations and satisfaction

## Goal

Complete the first task of the structural protocols milestone in
`agents/todo.md` (spec §2 reserved words, §3 Protocols, §4 Assignability).

- `protocol P:` declares a protocol whose body holds method signatures with no
  bodies. Protocols may be generic and may name themselves in their
  signatures.
- Protocols are types in annotations, as `P`, `module.P`, and `P[T, ...]`.
- Classes, native types, and other protocols are assignable to a protocol when
  they provide each of its methods with a compatible signature, after type
  arguments are substituted.
- Protocols cannot be constructed or used in `isinstance`, and they have no
  fields.

Calls on protocol values and their run-time dispatch belong to the next task
("Protocol values"). Here, a method call on a protocol value reports an interim
error. Satisfaction by `str`, lists, and the other built-in values comes with
the iteration milestone. Protocol bounds on type parameters come with the
milestone's last task.

## Related code

- `compiler/lexer.lua`: the reserved words.
- `compiler/parser.lua`: `parse_enum`, `parse_function`, and the file-scope
  loop that collects declarations.
- `compiler/bind.lua`:
  - `resolve_named` and `type_text`;
  - `resolve_type`, both its union branch and its generic branch;
  - `declare`, `declared_value`, and the `Call` and module `MethodCall`
    branches ("cannot be called");
  - the `IsInstance` branch;
  - the record loop in `M.bind`, `resolve_signature`, and `check_default`.
- `compiler/types.lua`: `same`, `key`, `assignable`, `conflict`, `record_map`,
  and `substitute`.
- `compiler/check.lua`: `collect`, `field_type`, and `MethodCall`.

## Decisions

- Representation:
  - The parser makes a `Protocol` node, kept in a new `program.protocols`
    list, with `name`, `type_params`, and `methods`.
  - Bind gives each protocol declaration `type`. A generic protocol also gets
    `typevars` and `self_type`, as generic classes do.
  - The new type kind `"protocol"` is built by `types.protocol(decl, args)`.
    It has a `protocol` field, and `args` when it is a specialization. A
    separate kind keeps protocols out of the code paths for classes, such as
    construction, fields, class tables, and `__wlo_record` tests.
  - `types.generic_decl(t)` returns `t.args and (t.record or t.protocol)`.
    `same`, `conflict`, and `collect` compare generic declarations through
    it. Comparing `record` fields alone would let two protocols match on `nil`.
  - `record_map` uses `t.record or t.protocol`, and `substitute` rebuilds
    protocol specializations.
- Parsing:
  - `protocol` is reserved and begins a file-level declaration,
    `protocol Name[T, ...]:`, parsed like `enum`.
  - A protocol body holds only `def` methods. Anything else reports "protocols
    hold only method signatures".
  - `parse_function(true, true)` parses a signature: it ends at the return
    type, and a `:` after it reports "protocol methods have no bodies".
  - A method with type parameters reports "protocol methods cannot be
    generic". This keeps signature matching free of method-level type
    parameters.
  - The file-scope error lists protocols: "only function, class, protocol,
    enum, and type declarations are allowed at file scope".
- Binding:
  - `resolve_named` accepts `Protocol` declarations.
  - `type_text` and the generic branch of `resolve_type` treat protocols like
    generic classes, but build `types.protocol`.
  - Protocol methods go through `check_unique` and `resolve_signature`, with
    `method.class` set to the protocol so that `self` takes its `self_type`.
    They are not in `bind.functions`, so they are never checked, lowered, or
    emitted. Their defaults get `check_default`.
  - Calls, including module-qualified ones, report "protocol 'P' cannot be
    called". A protocol used as a value reports "protocol 'P' cannot be used
    as a value", from the existing message. `isinstance` reports "protocol 'P'
    cannot be used in isinstance".
  - Duplicate names report "duplicate protocol 'P'".
- Union overlap checks with a protocol member need resolved method signatures,
  but aliases and field types resolve before signatures do.
  - The union branch of `resolve_type` first collects and deduplicates the
    members, then checks pairs with `types.conflict`. This is equivalent to
    the current incremental check.
  - Until a module-level `ready` flag is set, a union with a protocol member
    queues that check instead of running it.
  - `M.bind` sets `ready` after the first `force_pending`, once signatures are
    resolved, and runs the queued checks. `M.bind` resets `ready` on entry.
- Satisfaction, in `types.lua`:
  - `types.method(t, name)` returns `{ params, result }` for a class, native
    type, or protocol `t`. `params` lists the parameters after `self` as
    `{ name, type, default, keyword_only }`, with `t`'s type arguments
    substituted.
  - Native methods take their names and defaults from `names` and `defaults`.
    A native method without `names` has no parameter names, so its
    parameters are positional-only.
  - Generic methods return nil, so they never satisfy a protocol method.
  - `assignable` accepts a source of kind record or protocol for a protocol
    target when `satisfies(target, source)`. Every protocol method must be
    `compatible` with the source's method of the same name:
    - A positional protocol parameter at index `i` matches the implementation
      parameter at index `i`. That parameter must not be keyword-only, and its
      name must match.
    - A keyword-only protocol parameter matches the implementation parameter
      of the same name.
    - Each matched implementation parameter's type accepts the protocol's
      parameter type.
    - Where the protocol parameter has a default, the implementation's has one
      too.
    - Every unmatched implementation parameter has a default.
    - The protocol's result type accepts the implementation's.
  - A module-level `assuming` set marks the target and source pairs being
    checked, so self-referential protocols terminate. Each pair is assumed to
    hold while its check runs. Pairs are keyed by type name, because
    substitution builds fresh type objects for the same specialization.
  - Failures use the existing "expected P, received C" message.
- Inference: `collect` gets a branch for a protocol parameter whose argument is
  a different class, native type, or protocol. For each protocol method, it
  matches the argument's method parameters by name, and then the results. So
  `def take[T](s: Source[T]) -> T` infers `T = int` from a class whose
  `get() -> int`.
- Check:
  - `field_type` already rejects non-record types, reporting "type P has no
    field 'x'".
  - A `MethodCall` on a protocol value reports "method calls on protocol values
    are not supported yet". The next task replaces this.

## Test plan

- `tests/unit/parser_test.lua`:
  - a generic protocol with two signatures parses into `program.protocols`;
  - errors for a field, a method body, and a generic method;
  - the file-scope message names protocols.
- `tests/unit/bind_test.lua`:
  - `P()` reports "protocol 'P' cannot be called";
  - `isinstance(x, P)` reports the isinstance error;
  - `x = P` reports "protocol 'P' cannot be used as a value";
  - a second `P` reports "duplicate protocol 'P'";
  - a parameter annotated `C | P`, where `C` satisfies `P`, reports "union
    members C and P overlap". This exercises the queued check.
- `tests/unit/check_test.lua`, with `Reader` declaring
  `read(self, size: int) -> bytes | None`:
  - a class lacking `read` is rejected with "expected Reader, received C";
  - a renamed parameter, a narrower parameter type, an extra required
    parameter, and a missing default the protocol has are each rejected;
  - a broader parameter type, a narrower result, and an extra defaulted
    parameter are accepted;
  - a keyword-only protocol parameter matches by name;
  - `io.File` satisfies a protocol with `write_text(self, text: str) -> None`,
    but not one naming the parameter `data`;
  - a protocol with a superset of methods is assignable to a smaller protocol,
    but not the other way around;
  - a class with `get() -> int` satisfies `Source[int]` but not `Source[str]`;
  - a generic function call infers `T` through `Source[T]`;
  - a self-referential `Node` protocol, with `next(self) -> Node | None`, is
    satisfied by a class whose `next` returns its own type or `None`;
  - field access on a protocol value is rejected;
  - a method call on a protocol value reports the interim error.
- `tests/programs/protocols.wlo` and `.out`:
  - `Rect` and `Circle` values are stored in a `list[Shape]` and passed
    through a `Shape` parameter;
  - `io.stdout()` is passed where a `Writer` protocol is expected;
  - a generic call infers its type argument through `Source[T]`;
  - the program prints the results that show these values flowed through.

## Implementation plan

1. `compiler/types.lua`: `protocol`, `generic_decl`, `method`, `satisfies`,
   and `compatible`; protocol cases in `same`, `key`, `conflict`,
   `record_map`, `substitute`, and `assignable`.
2. `compiler/lexer.lua` and `compiler/parser.lua`: the `protocol` keyword,
   protocol parsing, signatures, and the `protocols` list.
3. `compiler/bind.lua`:
   - protocol declarations and signatures;
   - name resolution, the call, value, and isinstance errors;
   - the queued union checks.
4. `compiler/check.lua`: the protocol branch in `collect`, `generic_decl` in
   its same-declaration branch, and the interim `MethodCall` error.
5. Add the tests listed above, then check off the task in `agents/todo.md`.
6. `docs/spec.md` specifies the language this milestone builds toward:
   - `protocol` declarations, and built-in standard protocols in a new §3
     section that replaces the §14 `typing` section;
   - `(A, B) -> R` callable types;
   - the naming rule for built-in types.

   `agents/todo.md` adds a callable type syntax task, which also removes the
   `typing` module, after this one.
