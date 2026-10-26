# Compilation model

The compiler in [`compiler/`](../compiler/) compiles an entry module and its
transitive imports into one native executable:

```text
.wlo sources -> checked syntax trees -> QBE IL -> assembly -> executable
```

[`willow.wlo`](../compiler/willow.wlo) drives this pipeline. The commands
choose how far it runs:

| Command | Result |
| --- | --- |
| `willow check main.wlo` | Load, parse, bind, and type-check the program. |
| `willow compile main.wlo -o main.ssa` | Also emit textual QBE IL. |
| `willow build main.wlo -o main` | Also assemble and link a native executable. |
| `willow run main.wlo` | Build a temporary executable, run it, and remove it. |

## One compilation unit

[`loader.wlo`](../compiler/loader.wlo) reads UTF-8 source and follows imports
recursively. With an explicit source filename, the entry file's directory
is the root for program modules. With a project command, the entry and
module roots come from `willow.json`. The language's module-resolution
rules are specified in [Modules](spec.md#12-modules).

Core is included in every compilation. The compiler loads its source and
the sources of imported standard library modules from text embedded in the
compiler executable. Program modules and library modules retain separate
identities, so a local module can shadow a library module without changing
that library's own imports.

The loaded modules are checked together and emitted into a single IL file.
Each build compiles their Willow code together, including core and the
imported library code.

## Front end

The front end builds and annotates the syntax trees defined in
[`ast.wlo`](../compiler/ast.wlo):

| Pass | Implementation | Work |
| --- | --- | --- |
| Lexing and parsing | [`lexer.wlo`](../compiler/lexer.wlo), [`parser.wlo`](../compiler/parser.wlo) | Turn source into tokens, including indentation, and then syntax trees with source positions. |
| Binding | [`bind.wlo`](../compiler/bind.wlo) | Resolve declarations, imports, type names, signatures, locals, and captured bindings; identify what each name and call refers to. |
| Checking | [`check.wlo`](../compiler/check.wlo), [`types.wlo`](../compiler/types.wlo) | Check function bodies, argument and result types, definite assignment, and control-flow narrowing. |

Binding rewrites some syntax nodes to distinguish resolved operations, such
as a direct function call and a call through a function value. Checking
records each expression's actual and expected types so emission can insert
representation conversions. A front-end error stops compilation before
code generation.

## Code generation

[`emit.wlo`](../compiler/emit.wlo) walks the checked trees and writes QBE IL
directly. It emits functions, branches, calls, data objects, and a native
entry point. Non-generic functions and methods in the loaded modules are
emitted; generic functions and methods are specialized for the concrete
type arguments used by the program.

Program symbols start with `$P.<module>.`, while core and library symbols
start with `$W.<module>.`. The emitter also creates symbols for generated
specializations, closures, adapters, strings, and type descriptors.

### Values and calls

Willow function parameters, returned values, and ordinary storage slots use
QBE's 64-bit `l` type. Integers, booleans, and enum ordinals occupy slots
directly. Floats travel as their 64-bit bit patterns; floating-point
operations reinterpret those bits as QBE doubles. Strings, collections,
class instances, and function values occupy slots as pointers.

Heap objects carry type descriptors. Union values use object pointers,
boxing scalar members when needed, with zero representing `none`. The
emitter inserts boxing, unboxing, and other conversions according to the
checked types. Ordinary locals start as stack slots, which QBE can promote
to registers.

Direct calls name the emitted function. Foreign calls use the C ABI,
including 32-bit `cint` and double-precision float arguments and results;
the emitter converts between those and Willow's slot representation.

### Language features

- **Closures:** Nested functions and lambdas become generated functions
  with an environment parameter. Function values hold a code pointer and
  environment; captured bindings live in shared heap cells.
- **Protocols:** Conversion to a protocol creates a wrapper holding the
  receiver and a descriptor with generated method adapters. Protocol calls
  dispatch indirectly through those adapters.
- **Exceptions:** Generated code records a pending exception in
  `$W.pending` and checks it after calls that can raise. Branches implement
  handlers, propagation, and cleanup. The compiler supplies the bodies of
  core failure helpers such as `fail` and `fail_at` to set that state.
- **Generators and async functions:** Generated factory and body functions
  work with core's coroutine runtime. Generators preserve execution state
  on separate stacks; direct async awaits execute on the current task's
  stack, and scheduled tasks have their own contexts.

## Runtime and entry point

[`core.wlo`](../bootstrap/core/core.wlo) supplies allocation, collection
operations, I/O, exception reporting, and coroutine support. Generated code
uses runtime calls and inline instructions for language operations,
including checks for failures such as overflow and invalid indexing.
Allocation uses libgc's garbage collector.

The emitted native `main` initializes libgc, saves the process arguments,
initializes core, and calls the entry module's `main`. For an async entry,
it passes the resulting coroutine to core's event loop. After the entry
returns, an uncaught pending exception is reported with exit status 1;
normal completion returns 0.

## Native backend and linking

The driver writes the IL into a temporary directory and selects a QBE
target from the host operating system and architecture:

| Host | AArch64 | x86-64 |
| --- | --- | --- |
| Linux | `arm64` | `amd64_sysv` |
| macOS | `arm64_apple` | `amd64_apple` |

It then:

1. Runs `qbe -t TARGET -o program.s program.ssa` to produce assembly.
2. Appends the target-specific coroutine assembly from
   [`coroutine.wlo`](../compiler/coroutine.wlo).
3. Invokes `cc` to assemble and link the result with libgc and the math
   library. It obtains libgc flags from `pkg-config --cflags --libs bdw-gc`,
   falling back to `-lgc`, and adds `-lm`.
4. Renames the linked output from a sibling `.tmp` file to the requested
   destination and removes the temporary intermediate files.

The current coroutine stack-switch assembly is implemented for AArch64.
The x86-64 assembly reports coroutines unavailable.

The executable contains the emitted program, library, and core code, with
foreign symbols resolved through the native linker. Running that
executable executes native code directly. `willow run` uses this same build
path before starting its temporary executable.
