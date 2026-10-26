# Willow Language Specification

Willow is a small, statically typed language with Python-like syntax. It compiles
to native code through QBE. Source files use the `.wlo` extension.

Supported hosts are Linux on AArch64 or x86-64 (amd64), and macOS on
AArch64 (Apple Silicon). Intel macOS is not supported.

## 1. Programs

```python
def sum_to(limit: int) -> int:
    var total = 0
    var current = 1
    while current <= limit:
        total = total + current
        current = current + 1
    return total

def greeting(name: str) -> str:
    return "Hello, " + name

def main():
    print(greeting("Willow"))
    print(sum_to(10))
```

This program prints:

```text
Hello, Willow
55
```

A program consists of an entry file and the modules it imports (§12). A program
can also be organized as a project with a `willow.json` file (§12). A file
contains `import` statements followed by `def`, `async def`, `class`, `enum`,
and `type` declarations in any order. No other statements may appear at file
scope.

The entry file must define exactly one `main` function, with the signature
`def main():` or `async def main():`. In other modules, `main`
is an ordinary function name. The program reads its command-line arguments with
`sys.args()` (§14).

Test files (§12) are entry files that have no `main` function. `willow test` runs
the test functions they define.

The whole program is checked before any of it runs, and an error in any module
prevents the program from running. When the program runs, it calls `main` once.
For an async `main`, the runtime drives its coroutine as the root task (§15).
User code may also call `main`, and such a call behaves like any other function
call, including producing a coroutine when `main` is async.

The exit status is 0 when `main`'s body completes and 1 when an exception
propagates out of it or the program reports another failure (§10). When the
program calls `sys.exit` (§14), the exit status is the status passed to it.

## 2. Lexical structure

Source text is UTF-8. Lines end with LF or CRLF. A carriage return that is not
followed by LF is an error anywhere in the file, including in comments and
strings. The final line does not need to end with a newline.

A comment starts with `#` and continues to the end of the line.

### Indentation

A block is a colon followed by an indented suite of statements. Each level of
indentation is four spaces. Tabs are errors everywhere except inside string
literals and comments, and this includes blank lines. Blank lines and lines that
contain only a comment do not affect indentation, and their indentation does not
need to match the surrounding code.

A newline ends a statement. Newlines inside parentheses, brackets, and braces do
not end a statement and do not affect indentation. Willow has no backslash line
continuation, no semicolon statement separator, and no one-line blocks.

### Identifiers and reserved words

Identifiers consist of ASCII letters, digits, and underscores, and cannot begin
with a digit. They are case-sensitive. These words are reserved:

```text
and as assert async await break case class continue def else enum
except false finally for if import in is match none not or pass protocol
raise return self true try type var while with yield
```

`match` and `case` are reserved for future use.

The type names `int`, `float`, `bool`, `str`, `bytes`, `list`, `dict`, `tuple`,
`Iterable`, `Iterator`, `ContextManager`, `Generator`, and `Coroutine` are also
reserved. Using a reserved word that does not begin one of the
constructs in this specification is an error.

### Numeric literals

An integer literal is a sequence of decimal digits with no leading zeros, except
for `0` itself, or a lowercase prefix `0x`, `0o`, or `0b` followed by one or
more hexadecimal, octal, or binary digits. Hexadecimal digits may be uppercase
or lowercase; prefixed digits may have leading zeros. Underscores are not
supported. A minus sign before a literal is the unary minus operator, not
part of the literal. An integer literal outside the `int` range (§4) is an error.

A float literal has a fractional part, an exponent, or both, as in `1.0`, `0.25`,
`1e9`, and `2.5e-3`. A decimal point must have digits on both sides, and the
integer part follows the same leading-zero rule as integer literals. A float
literal that rounds to infinity is an error.

### String literals

A string literal is enclosed in single or double quotes and cannot contain an
unescaped newline. Triple-quoted strings (`"""..."""` and `'''...'''`) may span
multiple lines. Each line break in a triple-quoted string becomes `\n`, and
indentation is preserved. Raw strings are not supported.

The escape sequences are `\\`, `\'`, `\"`, `\n`, `\r`, `\t`, `\xhh`, `\uhhhh`,
and `\Uhhhhhhhh`. The last three denote the code point with the given hexadecimal
value. An unknown escape sequence is an error, as is an escape that denotes a
surrogate (U+D800 through U+DFFF) or a value above U+10FFFF.

An f-string (`f"..."`, `f'...'`, or a triple-quoted form) inserts the values of
expressions written in braces:

```python
f"{name} has {len(name)} letters"
```

Each field contains one expression of a printable type (§4). The field produces
the same text as `str(...)` would, formatted by an optional format specification
(§7). Fields are evaluated from left to right. `{{` and `}}` produce literal
braces. A field cannot be empty and cannot contain a backslash, a `#`, or the
quote character that delimits the f-string. A `}` without a matching `{` is an
error. Conversions such as `!r` are not supported.

## 3. Declarations

### Functions

```python
def function_name(parameter: Type, other: Type) -> Type:
    statements
```

Every parameter must have a type annotation. A function without a return
annotation returns `none`, as if annotated `-> none`. A parameter may have a
default value after its annotation, as in `prefix: str = "Hello"`. A
default value must be `none`, `true`, `false`, a string literal, an enum member,
an integer or float literal with an optional `+` or `-` sign, or a tuple of such
defaults, and it must be assignable to the parameter's type. Among positional
parameters, a parameter without a default cannot follow one that has a default.
A bare `*` introduces keyword-only parameters; these must be supplied by name
and may be required or have defaults, in any order:

```python
def report(path: str, *, limit: int = 100, verbose: bool = false):
    pass
```

Variadic parameters are not supported. Functions may contain nested `def`
statements and lambda expressions (§5). Nested functions have annotated
parameters and returns, just like file-level functions. Classes, enums, and
aliases are declared only at file scope.
Parameter lists and argument lists may end with a trailing comma. A function may
call functions declared later in the file, and functions may be directly or
mutually recursive.

An async function is declared with `async def`. Its parameters, type parameters,
defaults, and body return values follow the same rules. Functions and methods
may be async, including nested functions. An async function annotated `-> T`
produces a `Coroutine[T]` when called; §15 defines when its body runs.

### Classes

A `class` declaration defines a class. The body of the declaration contains
field declarations followed by method declarations, and nothing else. It must
contain at least one of either:

```python
class Node:
    value: int
    next: Node | none
```

Field names must be unique within a class. A field's type may name any class,
including the class being declared and classes declared later. Classes are
nominal, so two classes with the same fields are different types.

Calling a class by name constructs a new value. The constructor takes one
argument for each field. Arguments are bound the same way as function arguments
(§5), with the field names as the parameter names, and each argument must be
assignable to its field's type. A field may have a default value, following the
rules for parameter defaults. An omitted argument takes the field's default:

```python
class Options:
    output: str = "-"
    verbose: bool = false

var options = Options(verbose=true)
```

`p.x` reads the field `x`, and `p.x = v` replaces its value. The new value `v`
must be assignable to the field's type. Referring to a field that the class does
not have is an error.

A method is a function declared in a class body. Its receiver is the reserved
name `self`, which has the class's type and is not written in the parameter
list. `self` is available throughout the method body, including nested
functions and lambdas, and cannot be assigned or used outside a method. Field
access uses an explicit receiver, as in `self.count`. Parameters and the return
type follow the rules for functions:

```python
class Counter:
    count: int = 0

    def add(amount: int = 1) -> int:
        self.count = self.count + amount
        return self.count

def main():
    var counter = Counter()
    counter.add()
    print(counter.add(amount=5))    # 6
```

`v.m(arguments)` calls the method `m` of the class of `v`, binding `v` to `self`
and the arguments to the declared parameters as in a function call (§5). The
value `v` is evaluated before the arguments. Method names must be unique within
a class and cannot be the same as a field name. Like functions, methods may be
recursive and may refer to classes declared later.

Exception classes (§10) are classes declared with the base class `Exception`.
Their first field is `message`, which has no default.

### Type parameters

Functions, methods, classes, protocols, and aliases may declare type parameters:

```python
def first[T](items: list[T]) -> T:
    return items[0]

class Box[T]:
    value: T

type Pair[K, V] = tuple[K, V]
```

Each parameter names one type, and is in scope throughout its declaration,
including nested function bodies and class methods. Parameter names must be
unique and cannot hide another type parameter in scope. A type parameter may
have one upper bound, as in `T: ByteReader`, where the bound is a class, native
type, or protocol. Type parameters can be used in annotations and type
arguments, but are not runtime values. A
value of `T` supports only operations guaranteed by its bound; without a bound
it may be stored, passed, and returned, but does not acquire numeric, ordering,
or member operations from particular callers. Generic bodies must type-check
under these rules for every permitted type argument.

Generic class and alias annotations supply all type arguments, as in `Box[int]`.
Generic calls infer type arguments from their arguments and the expected result,
or supply all arguments explicitly, as in `first[int](numbers)` and
`Box[str]("hello")`. Inference must produce a unique substitution consistent
with assignability and bounds; it does not invent a union to reconcile different
argument types. A call that leaves a parameter undetermined is an error.

A generic function can become a function value when explicit type arguments or
an expected callable type determine its specialization. Values do not retain
unspecialized type parameters. Generic class specializations are invariant and
nominal: `Box[int]` is not assignable to `Box[int | none]`. Tuple and protocol
assignability follow their own rules (§4). Exception classes cannot be generic.

### Protocols

A protocol names a structural interface. It is declared with `protocol` and
contains method signatures, which have no bodies and omit the receiver:

```python
protocol ByteReader:
    def read(size: int) -> bytes

def read_prefix(source: ByteReader) -> bytes:
    return source.read(16)
```

A class or native type satisfies a protocol when it provides all the declared
methods with compatible signatures. No inheritance or implementation declaration
is required. Compatibility preserves every call the protocol permits: argument
types may be broader, return types may be narrower, parameter names must match
wherever the protocol permits keyword calls, and the implementation cannot
require additional arguments. Defaults need not have the same values. Extra
methods are allowed. Method matching uses the signatures after substituting type
arguments, including when one protocol satisfies another.

A protocol method may be declared `async def`. A signature
`async def m() -> T` means exactly `def m() -> Coroutine[T]`, so either
form satisfies the other (§15).

Protocols may have type parameters, as in `protocol Source[T]:`, and may refer to
themselves in signatures. Their methods have no type parameters of their own.
Protocols declare no fields or constructors and cannot be instantiated. A
protocol value exposes only its declared methods. Protocol membership is checked
statically. Ordinary classes have no inheritance beyond exception classes.

### Standard protocols

These protocols are built in:

| Protocol | Contract |
| --- | --- |
| `Iterable[T]` | Provides `iter() -> Iterator[T]` |
| `Iterator[T]` | Provides `iter() -> Iterator[T]` and `next() -> T` |
| `ContextManager[T]` | Provides `enter() -> T` and `exit(error: Exception \| none) -> none` |
| `Generator[T]` | Provides the iterator methods, `close() -> none`, `enter() -> Generator[T]`, and `exit(error: Exception \| none) -> none` |

`iter(value)` calls `value.iter()` and returns its iterator. An iterator's `iter`
method returns itself, so an iterator is also iterable. `next(iterator)` calls
its `next` method. Exhaustion raises `StopIteration` with an empty message;
after exhaustion an iterator remains exhausted. Neither built-in accepts a
default value or other arguments.

Lists, dictionaries, strings, bytes, tuples, and range values provide `iter`
methods and satisfy the corresponding iterable protocols. Each call returns a
fresh iterator, with the element types and mutation rules given in §7 and §8.
Dictionary iteration yields keys. `io.File` provides line iteration as specified
in its module. User-defined iterators and managers participate through the same
method matching, without registration or special inheritance.

An iterable argument is borrowed: consuming it does not close either the
iterable or its iterator. This also applies to `sorted`. Resource ownership is
expressed separately by `with` or explicit closing. A generator annotated as
`Iterator[T]` or `Iterable[T]` exposes only those protocols' methods; annotate it
as `Generator[T]` when callers need scoped or explicit closing.

### Enums

An enum is a nominal type with a nonempty, closed set of named values:

```python
enum ColorMode:
    AUTO
    ALWAYS
    NEVER

def use_color(mode: ColorMode = ColorMode.AUTO) -> bool:
    return mode == ColorMode.ALWAYS
```

Members are unique identifiers with no assigned values or payloads. `E.MEMBER`
is an immutable value of `E`; enum types cannot be called. Enum members support
equality with the same enum type, dictionary keys, and the existing union rules
for equality and narrowing. They have no numeric conversion or ordering.
`str(ColorMode.AUTO)` and printing that value produce `ColorMode.AUTO`.
Enums have no fields or methods. Events with different payloads use ordinary
classes and unions.

### Type aliases

```python
type Json = none | bool | int | float | str | list[Json] | dict[str, Json]
```

A `type` declaration gives a name to a type. The alias and the type it names are
the same type, and annotations may use either one. An alias may refer to classes
and aliases declared later, and to itself. An alias cannot expand to itself
except inside `list[...]` or `dict[...]`, so `type Loop = int | Loop` is an
error. An alias cannot be called.

### Annotations

The forms of type annotations are:

```text
int  float  bool  str  none
list[T]  dict[K, V]  tuple[A, B, ...]  tuple[]
Coroutine[T]
Class  module.Class  Class[T, ...]
Alias  module.Alias  Alias[T, ...]
Enum  module.Enum  Protocol  module.Protocol  Protocol[T, ...]
(A, B, ...) -> R
A | B | ...
```

Here `...` indicates additional type entries, not literal ellipsis syntax.
A callable type's return type extends as far as possible, so `(int) -> str | none`
returns `str | none`; `((int) -> str) | none` is an optional callable.
Otherwise, parentheses around a type group it.
Generic declarations and applications have fixed arity.

## 4. Types and values

| Type | Values |
| --- | --- |
| `int` | Integers from `-(2^63 - 1)` through `2^63 - 1` |
| `float` | IEEE 754 binary64 numbers |
| `bool` | `true` and `false` |
| `str` | Immutable UTF-8 text |
| `bytes` | Immutable sequences of octets |
| `none` | The single value `none` |
| `A \| B \| ...` | A value of any member type |
| `list[T]` | Ordered, mutable sequences of `T` |
| `dict[K, V]` | Mutable maps from `K` to `V` that keep insertion order |
| `tuple[A, B, ...]` | Immutable, fixed-length groups with a type for each position |
| Enums | Named values of a declared enum |
| `(A, B, ...) -> R` | Functions taking the listed positional arguments and returning `R` |
| `Coroutine[T]` | Unstarted async computations producing `T` (§15) |
| Protocols | Values satisfying the protocol's method signatures |
| Classes | Values of a declared class, including exception classes |
| Native types | Library values such as `io.File` (§14) |

Primitive and collection types have lowercase names. Classes,
protocols, enums, and `Coroutine` have capitalized names.

The scalar types are `int`, `float`, `bool`, `str`, `bytes`, enums, and `none`.
A type is printable if it is a scalar type other than `bytes`, or a union of
such types.
Lists, dictionaries, class values, coroutines, and task handles are reference
types. Assigning one or passing it as an argument shares the same value instead
of copying it.

### Assignability

Willow has no implicit conversions. In particular, `bool` is not a numeric type,
and an `int` is not assignable to `float`. A value is assignable to its own type.
In addition:

- A value is assignable to a union if it is assignable to one of the union's
  members. A union is assignable to a type if each of its members is assignable
  to that type.
- A value of any exception class is assignable to `Exception`.
- A value satisfying a protocol is assignable to that protocol (§3).
- A tuple is assignable to another tuple type of the same length when each
  position is assignable to the corresponding position.
- A function is assignable to a callable type when it accepts every positional
  call described by that type and returns a value assignable to its return type
  (§5).

Assignability rules apply to variable initializers, assignments, function
arguments, return values, elements of collection displays, and constructor
arguments. Lists and dictionaries are invariant. For example, `list[int]` is not
assignable to `list[int | none]`, and `list[ParseError]` is not assignable to
`list[Exception]`.

### Runtime classes

Every value has a runtime class: `int`, `float`, `bool`, `str`, `bytes`, `none`,
`list`, `dict`, `tuple`, callable, coroutine, or its class, enum, or native
type. Type arguments and callable signatures are not part of a runtime class,
so `list[int]` and `list[str]` values share the runtime class `list`.

A type covers the runtime classes its values can have. Most types cover one:
`list[int]` covers `list`, `Box[str]` covers `Box`, and `(int) -> str` covers
callable. `Exception` covers itself and every exception class. Protocols and
type parameters are open types: their declarations do not fix the runtime
classes they cover.

### Unions

The members of a union may be written in any order, and two unions with the same
members are the same type. When a member is itself a union, such as an alias for
a union, its members become members of the enclosing union. The members must
cover disjoint sets of runtime classes, and an open type may share a union only
with `none`. So `int | int`, `Exception | ParseError`, `list[int] | list[str]`,
`Box[int] | Box[str]`, `Iterable[int] | list[str]`, and `T | int` are errors.
Substituting a type argument flattens a union, so `T | none` with
`T = int | none` is `int | none`. A union that has `none` as a member, such as
`str | none`, is called an optional type.

A value of a union type can be assigned, passed as an argument, returned,
compared, and printed, and it can be tested with `is C` and `is not C`. To use
it in arithmetic, as a condition, or with indexing, field access, or method
calls, it must first be narrowed to a single member (§9).

`value is C` is `true` when the runtime class of `value` is one that `C`
covers; `value is not C` negates that test. `C` is a type name without type
arguments: `int`, `float`, `bool`, `str`, `bytes`, `none`, `list`, `dict`,
`tuple`, `Coroutine`, or a class, enum, native type, or alias, optionally
qualified with a module name. Aliases are tested by their runtime coverage:
`type Lists[T] = list[T]` covers `list`, while `type Maybe[T] = T | none`
remains open. Open coverage cannot be tested. Callable has no built-in type
name; an alias can name it, or excluding a union's other members with
`is not` narrows it to its callable member. `C` must cover one or more members
of the value's type and be disjoint from the rest. These operators test types,
not object identity. Testing an enum member is an error; compare enum values
with `==` or `!=`.

```python
def describe(value: int | str | none) -> str:
    if value is none:
        return "nothing"
    if value is int:
        return f"number {value + 1}"
    return "text " + value
```

### `none`

Functions whose return type is `none` return `none`. A `return` statement with no
value returns `none`, and such a body may also return by reaching its end.
Calling an async function still produces a coroutine (§15).

## 5. Expressions

The forms of expressions are literals, names, parenthesized expressions, list,
dict, and tuple displays, calls, indexing, slicing, field access, lambdas,
`await` expressions (§15), and unary and binary operations. Generic
specialization uses the type argument syntax in §3.

Operator precedence, from lowest to highest:

1. `or`
2. `and`
3. `not`
4. `==`, `!=`, `<`, `<=`, `>`, `>=`, `is`, `is not`, `in`, `not in`
5. `|`
6. `^`
7. `&`
8. `<<`, `>>`
9. Binary `+`, `-`
10. `*`, `/`, `//`, `%`
11. Unary `+`, `-`, `~`
12. `await`
13. Postfix operations: calls, indexing `a[i]`, slicing `a[i:j]`, and field or
   method access `a.name`
14. Literals, names, parenthesized expressions, and displays

Lambda expressions bind less tightly than all these operations; the expression
after `=>` extends as far to the right as its enclosing expression allows.

Binary operators are left-associative. Postfix operations are applied from left
to right, as in `text.strip().split(",")`. The value operands of a level 4
operator must be expressions at level 5 or higher, including bitwise expressions.
The right operand of `is` or `is not` is a single type name (§4), so
`x is int | none` is an error (`unsupported operator '|'`). As a result, `not a == b` means
`not (a == b)`, and `a == not b` is a syntax error. Chained comparisons such as
`0 <= x < 10` are errors. The operand of `await` must be an expression at
level 13 or higher, so `await -x` is a syntax error and nested awaits are
written `await (await c)`.

### Calls

A call can name a function, built-in function, conversion, or class by its bare
name (`area(p)`), a member of a module (`geometry.area(p)`), or a method of a
value (`items.append(x)`, `counter.add(1)`). It can also call an expression of
callable type, as in `(f)(x)`, `handlers[0](x)`, or `make_handler()(x)`. The callee
is evaluated before its arguments. Every call produces exactly one value.

A call's arguments are zero or more positional arguments followed by zero or
more keyword arguments of the form `name=expression`. Positional arguments are
matched to parameters in declaration order, and keyword arguments are matched to
the remaining parameters by name. Parameters with no matching argument take their
default values (§3).

```python
def greet(name: str, prefix: str = "Hello") -> str:
    return prefix + ", " + name

print(greet(prefix="Welcome", name="Ada"))
```

These are compile-time errors: a positional argument after a keyword argument, a
keyword that names no parameter, two values for the same parameter, a missing
argument for a parameter that has no default, a positional argument for a
keyword-only parameter, and too many arguments. Functions, methods, and class
constructors, including standard-library functions and native and collection
methods, accept keyword arguments using their declared or documented parameter
names. The intrinsic functions `print`, `input`, `len`, `range`, `int`, `float`,
`str`, `bytes`, `ord`, `chr`, `iter`, and `next` accept only
positional arguments.

### Function values and lambdas

File-level functions, nested functions, lambdas, and bound methods are values.
`(int, str) -> bool` describes a function that takes exactly an
`int` and a `str` positionally and returns `bool`. A callable parameter accepts
any function that can accept those arguments, including one with additional
defaulted parameters. Its return type must be assignable to the callable's
return type. Parameter types are checked in the opposite direction: a function
accepting `int | none` can serve a callable expecting `int`.

Calls through a callable type use exactly its listed positional arguments; parameter
names and defaults are not part of that type. Direct calls and inferred aliases
of declared functions and bound methods retain their complete call signatures,
including names, defaults, and keyword-only requirements. An explicit callable
annotation exposes only its positional contract. A function with required
keyword-only parameters cannot be converted to a callable type, but can still be
aliased and called with its inferred signature. Built-in functions can become
values when an expected callable type determines a compatible signature.

Evaluating a bound method such as `counter.add` evaluates and retains its receiver
once. Later calls use that same object and see its current fields. Callable
values can be stored in collections and class fields, passed, and returned.
They do not support equality or printing.

A lambda is a single-expression function written as a parenthesized parameter
list followed by `=>` and an expression, as in `(row) => row.score`. The
parentheses are required, including for one parameter; `() => 42` has no
parameters. A trailing comma is allowed in a nonempty parameter list.
Each parameter may have a type annotation, as in `(x: int) => x + 1`.
An unannotated parameter takes its type from an expected callable type; a
parameter with neither an annotation nor an expected type is a compile-time
error. The expression determines the return type, and an expected callable
type's return type is the expected type of the expression. This context can type
empty displays or a nested lambda in the body; it does not replace the body's
inferred return type. A lambda with all parameter types annotated, or with no
parameters, needs no expected type. Annotated and unannotated parameters may be
mixed. When an expected callable type is present, the lambda must be assignable
to it under the ordinary callable rules.
Lambdas have no defaults or return annotations; use a nested `def` when multiple
statements are needed. Captures follow §9.

```python
var increment = (x: int) => x + 1

def threshold(minimum: int) -> (int) -> bool:
    return (score) => score >= minimum
```

### Operators

- `and`, `or`, and `not` take `bool` operands and produce a `bool`. `and` and
  `or` evaluate their right operand only when needed.
- `==` and `!=` take two operands whose types are scalar types or unions of
  scalar types, where the type of one operand is assignable to the type of the
  other. For example, if `count` has type `int | none`, `count == 3` is valid.
  An operand of type `none` is an error; test for `none` with `is none`. Values
  of different runtime classes are never equal, so a union holding `1` is not
  equal to a union holding `1.0`. Bytes values are equal when their contents are equal.
  Lists, dictionaries, class values, and native values cannot be compared with
  `==`. Tuples support equality when all their corresponding positions support
  equality (§7).
- `<`, `<=`, `>`, and `>=` take two integers, two floats, two strings, or
  comparable tuples (§7).
- `is` and `is not` test a value's type as described in §4.
- `in` and `not in` test for an element in a list, a key in a dictionary, or a
  substring in a string (§7).
- `+` adds two numbers of the same type or concatenates two strings. `-`, `*`,
  unary `+`, and unary `-` take numbers.
- `/`, `//`, and `%` are described in §6.

Willow has no exponentiation operator and no bitwise operators.

### Evaluation order

Operands, arguments, and display elements are evaluated from left to right, and
each is evaluated exactly once. If an operand raises an exception, the remaining
operands are not evaluated. A dict display evaluates each entry's key and then
its value, one entry at a time. An index or field assignment evaluates the
right-hand side first, then the object, then the index. A slice evaluates the
object, then the start, then the stop. Call arguments are evaluated in the order
they are written, even when keyword arguments are given in a different order
from the parameters.

## 6. Numbers

### Integers

Integer `+`, `-`, `*`, unary `+`, and unary `-` are exact. A result outside the
`int` range raises `OverflowError` with the message `integer overflow`. There is
no integer negative zero.

Binary `&`, `|`, `^`, `<<`, and `>>`, and unary `~`, take only `int`
operands and return `int`. Bitwise operations act on the 64-bit two's-complement
value. A result of -2^63 raises `OverflowError` with the message
`integer overflow`; for example, `~9223372036854775807` raises this error.
`a << n` is the exact product of `a` and 2^n, raising the same overflow error
when out of range. `a >> n` is the floor of `a / 2^n`, so a count of 63 or
more produces `0` for a nonnegative value and `-1` for a negative value.
A negative shift count raises `ValueError` with the message
`negative shift count`. Thus `x & mask == 0` means `(x & mask) == 0`, and
`items[i | j]` indexes with the value of `i | j`.

### Floats

Float arithmetic follows IEEE 754 with round-to-nearest. Results may be infinite
or NaN. `-0.0` and `0.0` are distinct values, but they compare equal. NaN is not
equal to any value, including itself, and every ordering comparison involving NaN
is `false`.

### Division

Both operands of a division operator must have the same numeric type:

| Operator | `int` operands | `float` operands |
| --- | --- | --- |
| `/` | `float` quotient | `float` quotient |
| `//` | `int`, floor of the quotient | `float`, floor of the quotient |
| `%` | `int` remainder | `float` remainder |

The remainder has the same sign as the divisor, and for integers
`(a // b) * b + a % b == a`. For floats, `//` is the floor of the exact
quotient, not of the rounded `/` result, so `1.0 // 0.1` is `9.0`, and `%` is
`a - (a // b) * b` rounded once. A zero quotient has the sign of `a / b`, and a
zero remainder has the sign of the divisor. A NaN operand, or an infinite
dividend, gives NaN for both. A finite dividend and an infinite divisor give a
quotient of zero and a remainder equal to the dividend when the two have the
same sign or the dividend is zero, and otherwise a quotient of `-1.0` and a
remainder equal to the divisor. Dividing by zero, including by `-0.0`, raises
`ZeroDivisionError` with the message `division by zero`. For example,
`7 // -2` is `-4`, `7 % -2` is `-1`, `-7.5 // 2.0` is `-4.0`, `-7.5 % 2.0` is
`0.5`, and `1 / 3` is `0.3333333333333333`.

### Conversions

- `float(n: int) -> float` converts exactly.
- `int(x: float) -> int` truncates toward zero. If `x` is NaN or infinite, or the
  result is outside the `int` range, it raises `ValueError` with the message
  `cannot convert float to int`.
- `int(s: str) -> int` accepts an optional `+` or `-` followed by one or more
  decimal digits. Leading zeros are allowed. Any other text, or a result outside
  the `int` range, raises `ValueError` with the message
  `cannot convert str to int`.
- `float(s: str) -> float` accepts an optional `+` or `-` followed by either a
  decimal number or one of `inf`, `infinity`, and `nan` in any letter case. A
  decimal number consists of digits with an optional fraction and exponent, as in
  `7`, `2.5`, `.5`, `5.`, and `1e-3`. The result is the nearest float, and values
  too large for the float range become infinite. Any other text raises
  `ValueError` with the message `cannot convert str to float`.

The string conversions do not accept surrounding whitespace or underscores.

## 7. Strings and collections

### Strings

Strings are compared by their exact contents, without Unicode normalization.
Length, ordering, indexing, slicing, iteration, and the indexes returned by
`find` are all measured in code points.

| Expression | Type | Meaning |
| --- | --- | --- |
| `a + b` | `str` | Concatenation |
| `len(s)` | `int` | Number of code points |
| `s[i]` | `str` | The code point at index `i` |
| `s[i:j]` | `str` | The code points from index `i` up to `j` |
| `a < b`, `<=`, `>`, `>=` | `bool` | Lexicographic order by code point |
| `sub in s` | `bool` | `sub` occurs in `s` |
| `s.startswith(prefix)` | `bool` | `s` begins with `prefix` |
| `s.endswith(suffix)` | `bool` | `s` ends with `suffix` |
| `s.find(sub)` | `int \| none` | Index of the first occurrence of `sub`, or `none` |
| `s.replace(old, new)` | `str` | `s` with every non-overlapping occurrence of `old`, from left to right, replaced by `new` |
| `s.strip()` | `str` | `s` without leading and trailing ASCII whitespace |
| `s.lstrip()` | `str` | `s` without leading ASCII whitespace |
| `s.rstrip()` | `str` | `s` without trailing ASCII whitespace |
| `s.split(sep=none, maxsplit=-1)` | `list[str]` | The pieces of `s` between occurrences of `sep`, or between runs of ASCII whitespace when `sep` is `none` |
| `s.rsplit(sep=none, maxsplit=-1)` | `list[str]` | Like `split`, but `maxsplit` limits the splits made from the right |
| `s.splitlines(keepends=false)` | `list[str]` | The lines of `s`, ended by LF, CR, or CRLF, with the line endings kept if `keepends` is true |
| `s.removeprefix(prefix)` | `str` | `s` without a leading `prefix`, removed at most once |
| `s.removesuffix(suffix)` | `str` | `s` without a trailing `suffix`, removed at most once |
| `s.isascii()` | `bool` | Every code point of `s` is below 128; true for the empty string |
| `s.isspace()` | `bool` | `s` is not empty and has only ASCII whitespace |
| `s.isdigit()` | `bool` | `s` is not empty and has only `0` through `9` |
| `s.isalpha()` | `bool` | `s` is not empty and has only `A` through `Z` and `a` through `z` |
| `s.isalnum()` | `bool` | `s` is not empty and has only ASCII letters and digits |
| `s.lower()` | `str` | `s` converted to Unicode lowercase |
| `s.upper()` | `str` | `s` converted to Unicode uppercase |
| `s.ljust(width)` | `str` | `s` padded on the right with spaces to at least `width` code points |
| `s.rjust(width)` | `str` | `s` padded on the left with spaces to at least `width` code points |
| `sep.join(items)` | `str` | The items of a `list[str]` joined with `sep` |
| `str(value)` | `str` | The text `print` writes for a printable value, without the newline |
| `ord(c)` | `int` | The code point of `c`, which must be a single code point |
| `chr(n)` | `str` | The single-code-point string for code point `n` |

ASCII whitespace is space, tab, LF, VT, FF, and CR. The empty string occurs at
every index from 0 through `len(s)`, so `s.find("")` is `0`, `"" in s` is true, and
`startswith("")` and `endswith("")` are true. `s.replace("", new)` inserts
`new` before every code point and at the end.

`split` with a separator returns every piece, including empty ones, so
`"a,,b".split(",")` is `["a", "", "b"]` and `"".split(",")` is `[""]`. Without
a separator, runs of ASCII whitespace separate the pieces and whitespace at
either end is ignored, so a string that is empty or all whitespace gives `[]`.
A nonnegative `maxsplit` limits the number of splits, made from the left by
`split` and from the right by `rsplit`; the rest of the string becomes the last
piece for `split` and the first for `rsplit`, and in the form without a
separator that piece keeps its whitespace on the far side. A negative
`maxsplit` places no limit on the splits. `split` and `rsplit` with an empty
separator raise `ValueError` with the message `empty separator`. `splitlines`
gives `[]` for the empty string and no empty last line when the string ends
with a line ending. `ord` of a string whose
length is not 1 raises `ValueError` with the message `expected one character`.
`chr` of a surrogate, or of a value outside the range 0 through 0x10FFFF, raises
`ValueError` with the message `invalid code point`. An index outside the string
raises `IndexError` with the message `string index out of range`. Strings cannot
be modified by assigning to an index.

The classification methods are ASCII only: `isdigit`, `isalpha`, `isalnum`, and
`isspace` are false for any non-ASCII code point, as they are for the empty
string, so they are false for characters such as `é` and `²`.

`lower` and `upper` use the default full case mappings of Unicode 17.0,
including the Final_Sigma rule for `Σ`. They apply no locale-specific rules and
no normalization, so the result may have a different length from the original.
`ljust` and `rjust` measure width in code points, not in terminal display
columns. If the width is less than or equal to the length of the string, the
string is returned unchanged.

Indexing and slicing a string take time proportional to the string's length. To
process a string one code point at a time, iterate over it with `for`.

### Indexes and slices

Indexes and slice bounds for strings and lists are integers. A negative index
counts from the end of the sequence: the sequence's length is added to it once,
and the result must be a valid index. A slice `a[start:stop]` includes the
element at `start` and excludes the element at `stop`. An omitted start defaults
to zero and an omitted stop defaults to the length of the sequence. Negative
bounds count from the end, and bounds outside the sequence are clamped to it. If
the stop is at or before the start, the slice is empty. Slicing a list produces a
new list of the same type that contains the same elements. Slices cannot have a
step, and a slice cannot be the target of an assignment.

```python
var text = "café"
print(text[-1])       # é
print(text[1:3])      # af
var items = [10, 20, 30]
items[-1] = 40
var copy = items[:]
```

### Format specifications

An f-string field may end with a format specification, written
`{expression:spec}`. The specification starts after the first colon that is not
inside nested parentheses, brackets, braces, or string literals. So
`f"{text[1:3]}"` contains a slice and has no format specification. A
specification has the form `[alignment][width][.precision][type]`. The alignment
is `<`, `>`, or `^`. The width and precision are unsigned decimal integers with
no leading zeros. The type is `s`, `d`, or `f`. An empty specification has no
effect.

- A field without a type formats any printable value the way `str` does. A
  precision may only be given with the `f` type. The `s` type requires a `str`
  value, `d` requires an `int`, and `f` requires a `float`. A value of a union
  type must be narrowed before it can be formatted with a type.
- The `f` type writes the number in fixed-point notation with six digits after
  the decimal point unless a precision is given. It rounds to the nearest value,
  with ties going to the even digit. NaN and infinities are written as they are
  by `str`.
- Padding uses spaces. Strings are left-aligned by default and other values are
  right-aligned. For a union, the default depends on the type of the value the
  union holds. With center alignment, when the padding cannot be split evenly,
  the extra space goes on the right. The width is a minimum length in code
  points, and longer values are not truncated.
- A malformed specification, or a type that does not match the value, is a
  compile-time error. Fill characters, digit grouping, sign options, zero
  padding, and nested fields are not supported.

```python
print(f"{'total':<12s}{12:>6d}{2.5:>10.2f}")
```

### Text of printable values

`print`, `str`, and f-string fields write printable values as follows:

- A string is written as its contents, without quotation marks.
- An integer is written in decimal.
- A float is written with the fewest significant digits that read back as the
  same value; when several values with that many digits do, the one nearest
  the float is used, and of two equally near, the one whose last digit is even,
  so `1000000000000000.25` is written as `1000000000000000.2`. Zeros keep their
  sign, as in `0.0` and `-0.0`. Scientific notation is used when the decimal exponent is
  less than -4 or at least 16: the digits, with a decimal point after the first
  only if there are more, then `e`, a sign, and at least two exponent digits, as
  in `1e+16`, `1.5e+300`, `1e-05`, and `5e-324`. Otherwise fixed notation is
  used, with at least one digit after the decimal point, as in `2.5`, `100.0`,
  and `0.0001`. Non-finite values are written as `inf`, `-inf`, and `nan`.
- Booleans are written as `true` and `false`, and `none` is written as `none`.

### Displays

```python
var numbers = [1, 2, 3]                     # list[int]
var ages = {"ada": 36, "alan": 41}          # dict[str, int]
var names: list[str] = []
var scores: dict[str, int | none] = {"ada": none}
```

A display can have an expected type, which comes from an annotation, an existing
assignment target, a parameter, a return type, a class field, or an enclosing
display. When a display has an expected type, each element is checked against
it, and an empty display takes that type. If the expected type is a union, a list
display uses the union's list member and a dict display uses its dict member.

When a display has no expected type, a non-empty display takes its type from its
first element or entry, and every later element or entry must be assignable to
that type. An empty display with no expected type is an error.

If a dict display contains the same key more than once, the entry keeps the
position of the first occurrence and the value of the last. Displays may end
with a trailing comma.

### Bytes

```python
var data = "café".encode()      # bytes([99, 97, 102, 195, 169])
print(len(data))            # 5
print(data[-1])             # 169
print(data[:3].decode())    # caf
```

| Expression | Type | Meaning |
| --- | --- | --- |
| `bytes(values)` | `bytes` | The octets in a `list[int]` of values from 0 through 255 |
| `a + b` | `bytes` | Concatenation |
| `len(data)` | `int` | Number of octets |
| `data[i]` | `int` | The octet at index `i` |
| `data[i:j]` | `bytes` | The octets from index `i` up to `j` |
| `s.encode()` | `bytes` | The UTF-8 encoding of the string `s` |
| `data.decode()` | `str` | The text whose UTF-8 encoding is `data` |
| `data.find(sub: bytes)` | `int \| none` | The offset of the first occurrence of `sub`, or `none` |
| `data.startswith(prefix: bytes)` | `bool` | Whether `data` begins with `prefix` |
| `data.endswith(suffix: bytes)` | `bool` | Whether `data` ends with `suffix` |
| `data.split(sep: bytes, maxsplit: int = -1)` | `list[bytes]` | The fields between occurrences of `sep` |
| `data.hex()` | `str` | Two lowercase hex digits per octet |
| `bytes.fromhex(text: str)` | `bytes` | The octets written as hex digit pairs in `text` |

A `for` loop over a bytes value produces each octet as an `int`. Indexes and
slices follow the same rules as for strings and lists. `bytes` raises
`ValueError` with the message `bytes must be in range(0, 256)` if a value is
outside 0 through 255. An index outside the value raises `IndexError` with the
message `index out of range`. `decode` raises `ValueError` with the message
`invalid UTF-8` if the data is not valid UTF-8. There is no literal syntax for
bytes. Bytes values cannot be printed, formatted, converted with `str`, compared
with ordering operators, used as dictionary keys, or modified by assigning to an
index.

### Lists and dictionaries

Dictionary keys must be `int`, `str`, or one enum type. List elements and
dictionary values can have any type. A list or dictionary can store `none`.
A stored `none` counts toward the collection's length, and a key whose value is
`none` is different from a missing key.

| Expression | Type | Meaning |
| --- | --- | --- |
| `len(xs)` | `int` | Number of elements |
| `xs[i]` | `T` | Element at index `i` |
| `xs[i] = v` | | Replace the element at index `i` |
| `xs[i:j]` | `list[T]` | A new list of the elements from index `i` up to `j` |
| `xs.append(v)` | `none` | Add `v` to the end |
| `xs.pop()` | `T` | Remove and return the last element |
| `xs.sort(reverse=false, *, key=none)` | `none` | Sort the list in place |
| `xs.extend(items)` | `none` | Add the elements of an `Iterable[T]` to the end |
| `xs.reverse()` | `none` | Reverse the list in place |
| `v in xs` | `bool` | Some element equals `v` |
| `len(d)` | `int` | Number of entries |
| `d[k]` | `V` | Value for key `k` |
| `d[k] = v` | | Insert or replace the entry for `k` |
| `d.get(k)` | `V \| none` | Value for `k`, or `none` if `k` is missing |
| `d.get(k, default)` | `V` | Value for `k`, or `default` if `k` is missing |
| `d.keys()` | `Iterator[K]` | The keys in insertion order |
| `d.values()` | `Iterator[V]` | The values in key order |
| `d.items()` | `Iterator[tuple[K, V]]` | The keys and values in key order |
| `d.pop(k)` | `V` | Remove the entry for `k` and return its value |
| `k in d` | `bool` | `k` is a key |

List indexes start at zero and may be negative (see Indexes and slices above). An
index outside the list raises `IndexError` with the message
`list index out of range`. `pop()` on an empty list raises `IndexError` with the
message `pop from empty list`. `d[k]` and `d.pop(k)` raise `KeyError` with the
message `key not found` when `k` is missing. `v in xs` requires an element type
that supports `==`.

The `default` of `d.get(k, default)` must be assignable to `V`. `get` returns
`none` or the default only for a missing key: a key whose stored value is `none`
is present, and `get` returns that `none`.

Replacing the value of an existing key keeps the entry in its current position.
A key that is removed and then inserted again moves to the end.

`xs.extend(items)` takes an `Iterable[T]` of the list's element type `T`. It
iterates `items` completely before changing `xs`, so `xs.extend(xs)` appends a
copy of the original elements, and a failure while iterating leaves `xs`
unchanged. `d.keys()`, `d.values()`, and `d.items()` return iterators over the
dictionary, which follow the rules for iterating a dictionary directly: adding
or removing a key before the iterator is exhausted raises `RuntimeError` with
the message `dictionary changed size during iteration` at its next step.

`sorted(items, reverse=false, *, key=none)` returns a new sorted list from an
`Iterable[T]` (§3), and `xs.sort(reverse=false, *, key=none)` sorts a list in
place. `reverse` is a `bool`. Without `key`, the element type must be exactly
`int`, `float`, `str`, or a comparable tuple. With `key`, its callable takes one
`T` and returns one of those comparable types, and elements may have any type:

```python
var ordered = sorted(records, key=(row) => (row.name, row.score))
```

`sorted` fully consumes its iterable before evaluating keys. The key is evaluated
exactly once for each element, in input order, before any reordering. A key
function must not mutate the list being sorted in place;
doing so raises `RuntimeError` with the message `list changed during sort`.
Sorting is stable in both directions and compares strings by code point.
Infinities and signed zeros follow the usual comparisons. NaN anywhere in a
comparison key raises `ValueError` with the message `cannot sort NaN`. Key
evaluation and validation failures do not reorder the input; other effects of
callbacks are not undone.

### Numeric and iterable functions

These built-in functions work on numbers and on iterables (§3), which they
iterate as `for` does. Parameters are named as written below; `min` and `max`
take no keyword arguments. No function treats a value as true or false.

| Function | Meaning |
| --- | --- |
| `abs(x)` | The absolute value of an `int` or `float`, of the same type |
| `round(x: float) -> int` | The nearest integer, with ties to the even integer |
| `min(items)`, `max(items)` | The least or greatest item of an `Iterable[T]` |
| `min(a, b)`, `max(a, b)` | The lesser or greater of two operands of type `T` |
| `sum(items)` | The total of an `Iterable[int]` as an `int`, or of an `Iterable[float]` as a `float` |
| `any(items)`, `all(items)` | Whether some, or every, item of an `Iterable[bool]` is `true` |
| `list(items) -> list[T]` | A new list of the items of an `Iterable[T]` |
| `enumerate(items, start=0)` | An `Iterator[tuple[int, T]]` of positions and items |
| `zip(a, b)` | An `Iterator[tuple[T, U]]` of pairs from an `Iterable[T]` and an `Iterable[U]` |

`abs` of an `int` cannot overflow, since the `int` range is symmetric. `round`
raises `ValueError` with the message `cannot round float to int` when `x` is NaN
or infinite or the result is outside the `int` range.

For `min` and `max`, `T` is one type that `sorted` accepts without a key: `int`,
`float`, `str`, or a comparable tuple. Two operands must have the same type. The
iterable form raises `ValueError` with the message `min() of an empty iterable`
(or `max()`) when it has no items. NaN in any compared value, including a tuple
position, raises `ValueError` with the message `cannot compare NaN`. Of equal
values the first is returned. Arguments are evaluated once, from left to right.

`sum` returns `0` or `0.0` for no items, and `int` addition raises
`OverflowError` as `+` does. `any` and `all` stop at the first item that decides
the result; their results for no items are `false` and `true`.

`list` iterates its argument once. `enumerate` and `zip` are lazy: `enumerate`
counts from `start`, which raises `OverflowError` if the count leaves the `int`
range, and `zip` takes the next item of `a` and then of `b`, stopping when either
is exhausted.

### Tuples and unpacking

Tuples have fixed arity and a type for each position. `(1, "Ada")` has type
`tuple[int, str]`; `(1,)` has type `tuple[int]`; `()` has type `tuple[]`.
Tuple expressions require parentheses. `(value)` is grouping, not a tuple.
Elements are evaluated left to right. Tuple positions cannot be reassigned,
but a contained mutable object is still shared.

`len` returns the arity. Indexes must be integer literals, optionally negated;
negative indexes count from the end, and an invalid index is a compile-time
error. Indexing returns the corresponding position's type. Tuple slicing is
not supported. Iteration produces the union of the position types, removing
duplicate and subsumed members; the element type of an empty tuple is `none`.
Iteration is an error when the resulting union is not a valid type.

Tuples of equal arity support equality when corresponding types support the
existing equality rules, and ordering when corresponding types are the same
ordered scalar type or comparable tuple type. Comparison proceeds left to right
and stops at the first unequal position. Empty tuples compare equal. Tuples do
not become printable or valid dictionary keys merely by being tuples.

Variable declarations, assignments, and `for` targets may unpack fixed-length
tuples:

```python
var name, count = ("Ada", 3)
for key, value in pairs:
    process(key, value)
```

Targets are names or nested tuple patterns of names. The source type must have
the same tuple shape, checked statically. The right-hand side is evaluated once,
then its positions are bound or assigned left to right under the ordinary
local-type rules. A `var` pattern declares every name; an assignment pattern
updates existing variables. `for` patterns declare fresh iteration bindings.
Repeated target names and starred targets are errors. Unpacking lists or
arbitrary iterables is not supported.

## 8. Statements

```python
var name = expression
var name: Type = expression
var name: Type
name = expression
items[index] = expression
point.x = expression
function_call()
await expression
return expression
return
pass
break
continue
raise expression
raise
assert condition
assert condition, message

if condition:
    statements
else if condition:
    statements
else:
    statements

while condition:
    statements

for target in iterable:
    statements

try:
    statements
except ParseError as error:
    statements
finally:
    statements

with expression as target:
    statements

async with expression as name:
    statements

yield expression
```

An `else if` clause continues an `if` statement at the same indentation
as its initial `if`.

A block must contain at least one statement. Use `pass` for an empty block.
Calls and `await` expressions may be used as statements. An expression statement
cannot discard a value whose static type is `Coroutine[T]` or a union with a
`Coroutine` member; its body would not run (§15). A value whose type is a type
parameter may be discarded. An assignment
has one target, which may be a tuple pattern (§7), and one value. Chained
assignment, augmented assignment such as `+=`, and assignment expressions are
not supported. `var` declares local variables; assignment updates existing
variables and never declares them (§9). Nested `def` and `async def` statements
bind function values as described in §9.

Conditions must have type `bool`. Other types cannot be used as conditions, so
`if count:` is a type error.

`break` and `continue` apply to the innermost enclosing `while` or `for` loop. It
is an error to use them outside a loop. Loops cannot have an `else` clause.

`assert` takes a `bool` condition and an optional `str` message. Assertions are
always checked. If the condition is false, the message is evaluated and the
statement raises `AssertionError` with that message, or with the message
`assertion failed` if none is given. If the condition is true, the message is not
evaluated.

### `for`

`for name in iterable:` runs its body once for each item of the iterable. The
iterable can be a list, which produces its elements in index order; a
dictionary, which produces its keys in insertion order; a string, which produces
each code point as a one-code-point string; bytes; a tuple; or a value satisfying
`Iterable[T]` (§3). `range` produces an iterable of integers.

The loop obtains one iterator by calling `iter(iterable)`, and calls `next` for
each step. Only `StopIteration` raised by that advancement ends the loop;
`StopIteration` from the loop body propagates normally. Other advancement errors
also propagate. A loop does not close its iterator on early exit; the iterator
can be resumed. Use `with` for an owned iterator that needs cleanup.

- `range(stop)`, `range(start, stop)`, and `range(start, stop, step)` take
  integers, with `start` defaulting to 0 and `step` to 1. They produce `start`,
  `start + step`, `start + 2 * step`, and so on, while the value is less than
  `stop` for a positive step or greater than `stop` for a negative step, so
  `range(10, 0, -3)` produces 10, 7, 4, and 1. A step of zero raises
  `ValueError` with the message `range step must not be zero`. The range value
  satisfies `Iterable[int]`; each `iter` call starts a fresh traversal.
- The iterable and the arguments to `range` are evaluated once, before the first
  iteration.
- Each iteration declares fresh bindings for the target names in the loop body's
  scope. They are not visible after the loop.
  Assigning to a loop variable inside the body does not change the iteration.
- Iteration over a list continues as long as the current index is less than the
  list's current length, so elements appended during the loop are visited.
- If keys are added to or removed from a dictionary while a loop iterates over
  it, the next step of the loop raises `RuntimeError` with the message
  `dictionary changed size during iteration`. Replacing the values of existing
  keys is allowed.

### Generators

A function containing `yield expression` in its own body is a generator
function. Its return annotation is `Generator[T]`, `Iterator[T]`,
or `Iterable[T]`, and each yielded expression must be assignable to `T`.
Calling it binds and checks arguments normally, but runs none of its body. The
body starts on the first `next` and resumes after each `yield` on subsequent
calls. Local variables, captured bindings, and active exception handlers remain
in effect while suspended.

```python
import io

def lines(path: str) -> Generator[str]:
    with io.open(path) as source:
        for line in source:
            yield line

def main():
    with lines("input.txt") as rows:
        for line in rows:
            print(line)
            break
```

Here the outer `with` closes the generator after the early loop exit, which
runs the suspended file context's cleanup and closes the file.

Bare `return` or reaching the end exhausts the generator and runs pending
cleanup. Returning a value is an error, and a generator need not return on every
path. Yielding `none` is permitted when `T` permits it. An exhausted or closed
generator always raises `StopIteration` on `next`. A body exception closes the
generator and propagates; a `StopIteration` escaping its body instead raises
`RuntimeError` with the message `generator raised StopIteration`, so an accidental
exhaustion from another iterator cannot silently end the generator.

`Generator[T]` also provides `close() -> none`. Closing a suspended generator
discards the rest of its ordinary execution and runs pending `finally` clauses
and `with` cleanup, from inner to outer. It does not enter `except` handlers,
and each pending `exit` receives `none`, as for a control transfer. Closing a
generator whose body has not started does not start it. Closing an exhausted or
closed generator has no effect. Cleanup errors propagate and leave the
generator closed. Resuming or closing a generator already executing raises
`RuntimeError` with the message `generator already running`.

Generators satisfy the context-manager protocol: `enter` returns the generator
and `exit` closes it. Cleanup is guaranteed by exhaustion or explicit closing,
including `with`, rather than by discarding the last reference. `yield` is a
statement, not an expression, and cannot occur directly in a `finally` clause.
Sending values into generators and injecting exceptions into them are not
supported; these generators provide pull iteration, not coroutines.

### Scoped cleanup

`with manager as target:` requires a value satisfying
`ContextManager[T]` (§3). The expression is evaluated once; its
`enter() -> T` method runs, and the returned value is assigned to the optional
`as` target. A target is a name or tuple pattern. After successful entry,
`exit(error: Exception | none) -> none` runs exactly once when control leaves
the body, including through `return`, `break`, `continue`, or an exception.
`error` is the pending exception, or `none` for normal completion and control
transfers. This lets a manager distinguish successful use from failure, such as
when committing or discarding a temporary output. Closing a suspended generator
and async cancellation (§15) are also control transfers, so `none` can mean the
body was interrupted before it finished. If entry fails, the body does
not run and that manager's exit is not called.

Exit has the same exception behavior as `finally`: it cannot suppress a body
exception, and an exception it raises replaces the pending exception or control
transfer. Return expressions are evaluated before exit. `sys.exit` and failures
that bypass `finally` also bypass context cleanup. Suspending a generator at
`yield` does not exit its contexts.

Several managers may be listed with commas. They enter left to right and exit
right to left, like nested `with` statements, including when a later entry fails.
The statement creates a lexical scope. Its `as` targets declare new bindings
visible to later managers in the same statement and throughout the body, but not
after the statement. Assignment to an enclosing variable still updates that
variable.

## 9. Names and static checking

### Scope

Each indented block creates a lexical scope. A local declaration is visible
from its declaration onward through that block and its nested scopes; it does
not affect earlier uses of the name. A `var` initializer is checked before the
new names enter scope. Parameters and a method's `self` belong to the
function body's scope and are available from its start. A nested function's
name is also available inside its own body for recursion.

`var` declarations, nested function declarations, and names introduced by `for`,
`except ... as`, `with ... as`, and `async with ... as` create bindings. The
latter names belong to their construct's body scope. Each execution of a block
creates fresh bindings for its declarations; `for` also creates fresh target
bindings for each iteration. Parameters of nested functions and lambdas are also
declarations. A declaration cannot reuse the name of a visible local variable,
parameter, or nested function, including one in an enclosing function.
Assignment updates the visible variable or parameter with that name, including
one in an enclosing function. Assigning to an undeclared name or to a nested
function name is an error.

There are no module-level variables or global variables.

The file scope contains functions, classes, protocols, enums, aliases, and
imports. These share a single namespace with the built-in names (§11). It is an
error to declare the same name twice, to give two parameters the same name, or to
declare a file-level name that is also a built-in name. A local declaration can
hide a function, class, alias, import, or built-in from its declaration onward
within its scope.
A local variable can be called when its type is callable and it is definitely
assigned. Type annotations and `is` tests still refer to hidden type
declarations.

### Captures

A nested function or lambda captures the bindings of referenced variables in
enclosing lexical scopes. Captures remain alive after their declaring scope
exits. They are shared bindings: rebinding a captured variable changes what every
closure over that binding subsequently reads. Separate calls to the enclosing
function create separate bindings. Closures created in different loop iterations
capture different iteration bindings.

```python
def counter() -> () -> int:
    var count = 0

    def increment() -> int:
        count = count + 1
        return count

    return increment
```

Each loop iteration has its own bindings:

```python
var callbacks: list[() -> int] = []
for i in range(3):
    callbacks.append(() => i)
print(callbacks[0]())    # 0
print(callbacks[1]())    # 1
print(callbacks[2]())    # 2
```

Reading or assigning to an outer variable uses that variable's binding.
Assignments must preserve the target binding's declared or inferred type.
Mutating a captured object's fields or contents does not rebind the variable.

Nested definitions execute in statement order and bind their function name when
the definition executes. A function may refer to its own name recursively. Other
captured variables must be definitely assigned when the closure is created;
reading an uninitialized outer binding is a compile-time error.

### Local types

`var name = expression` declares a mutable local variable whose type is inferred
from the initializer. `var name: Type = expression` gives it an explicit type,
and the initializer must be assignable to that type. `var name: Type` declares
a variable without assigning a value; an omitted initializer requires an
annotation. A `var` with a tuple pattern has no annotation and requires an
initializer. An initializer is an assignment for definite assignment and
narrowing. Every subsequent assignment must be assignable to the declared or
inferred type. Assignments cannot have type annotations.

```python
var count: int = 3
count = count + 1     # valid
count = "four"        # type error
var best: str | none = none
```

A `for` target's type comes from the iterable's item type. An `except ... as`
binding has the handled exception type, and a `with ... as` binding has the
manager's entry result type.

### Definite assignment

A local variable may only be read at points where it has been assigned on every
path that reaches that point. This is determined from the structure of the code:

- After an `if` statement, a variable is assigned if every branch that completes
  normally assigns it. An `if` without an `else` has an implicit empty `else`
  branch that completes normally.
- The body of a `while` or `for` loop may run zero times, so assignments in the
  body do not count as assignments after the loop.
- A variable bound by `except ... as` is assigned inside its `except` clause.
- A plain `with ... as` target is assigned after successful entry and before
  its body. Assignments made on all normally completing paths through the body
  remain definite after the statement.
- An `async with ... as` target is also assigned before its body, but graceful
  cancellation adds possible exits from that body (§15).

These rules carry assignments to enclosing variables across block boundaries;
bindings declared inside a block are not visible after it. For example:

```python
var result: int
if condition:
    result = 1
else:
    result = 2
print(result)
```

The checker does not evaluate conditions. Both branches of every `if` are
checked, and `if false:` and `while true:` are treated the same as any other
condition.

### Control transfer

`return`, `break`, `continue`, `raise`, and a statement that calls the standard
library function `sys.exit` (§14) transfer control. `assert` does not, even
`assert false`. An `if` statement with an `else` branch transfers control if all
of its branches do. A statement that follows a control transfer in the same block
is an unreachable-code error.

A non-generator function whose return type is not `none` must return a value on
every path. The checker never treats a loop as guaranteeing a return, so a final
`return` is required even after `while true:`.

`yield` suspends execution and is not a terminating control transfer; statements
after it are reachable. Generator return rules are defined in §8.
A plain `with` statement transfers control when its body transfers control.
Async group scopes have additional possible exits (§15).

### Narrowing

A local variable or parameter that has a union type is narrowed to a subset of
its members wherever a check proves that its value has one of those types. When
only one member remains, the variable has that member's type. Each condition
produces facts that hold when it is true and facts that hold when it is false:

- `name is C`, when true, narrows `name` to the members `C` covers. When false,
  it narrows `name` to its other members. `name is not C` swaps these facts.
- `not C` swaps the true and false facts of `C`.
- `A and B`, when true, has the true facts of both `A` and `B`. `B` is checked
  with the true facts of `A`.
- `A or B`, when false, has the false facts of both `A` and `B`. `B` is checked
  with the false facts of `A`.
- Other conditions produce no facts.

Field access and index expressions are not narrowed. To narrow such a value,
assign it to a local variable first. Facts apply to statements as follows:

- An `if` or `else if` branch starts with the true facts of its condition and the
  false facts of all earlier conditions in the statement. An `else` branch, or
  the implicit empty `else` branch, starts with the false facts of every
  condition.
- After an `if` statement, a variable's possible members are those it has at the
  end of any branch that completes normally.
- A `while` body starts with the true facts of its condition.
- The statements after an `assert` have the true facts of its condition, and its
  message is checked with the false facts.
- Assigning a value whose type is a single member other than `none` narrows the
  variable to that member. Assigning any other value removes the variable's
  narrowing.
- At the start of a loop body and after the loop, narrowing established before
  the loop still applies only to variables that the body does not assign.

```python
def describe(name: str | none) -> str:
    if name is none:
        return "anonymous"
    return "user " + name
```

Captured variables are checked against their full binding types at the start of
a closure body; narrowing at closure creation does not become a permanent fact.
For any captured binding, every function call, including implicit protocol
calls, every generator suspension, every `await`, and every implicit task-group
join removes its narrowing. A fresh test or assignment can establish it again.
Copying the value to a separate local permits narrowing that is independent of
later rebinding.

### `try`

- A `try` body may be interrupted at any statement. Each `except` clause
  therefore starts with the definite assignments that held before the `try`. It
  also keeps the narrowing from before the `try`, but only for variables that the
  body does not assign. A `finally` clause starts the same way, and additionally
  loses narrowing for variables assigned in the `except` clauses.
- After the `try` statement, the body and the `except` clauses are joined like
  the branches of an `if` with an `else`, counting only those that complete
  normally. The `finally` clause is then checked as ordinary statements.
- A `try` statement transfers control when its body and every `except` clause
  transfer control, or when its `finally` clause transfers control.

## 10. Exceptions

```python
class ParseError(Exception):
    line: int

def parse_digit(text: str, line: int) -> int:
    var index = "0123456789".find(text)
    if len(text) != 1 or index is none:
        raise ParseError(f"not a digit: {text}", line)
    return index

def main():
    try:
        print(parse_digit("7", 1))                      # 7
        print(parse_digit("x", 2))
    except ParseError as error:
        print(f"line {error.line}: {error.message}")    # line 2: not a digit: x
    finally:
        print("done")                                   # done
```

### Exception classes

`Exception` is a built-in class with one field, `message: str`. A class declared
with `Exception` as its base is an exception class. Its fields are `message`
followed by the fields it declares, and its constructor takes them in that order.
The body of an exception class may be `pass` instead of field and method
declarations. No declared field or method may be named `message`. The
base class must be `Exception`. In all other respects, exception classes follow
the rules for classes.

These built-in exception classes have only the `message` field:

| Class | Raised for |
| --- | --- |
| `AssertionError` | A false `assert` condition |
| `OverflowError` | Integer overflow |
| `ZeroDivisionError` | Division by zero |
| `ValueError` | Invalid values for conversions, `ord`, `chr`, `range`, `split`, `sys.exit`, and UTF-8 input |
| `IndexError` | Invalid list indexes and `pop` from an empty list |
| `KeyError` | Missing dictionary keys |
| `RuntimeError` | Mutation during iteration or sorting, and invalid generator, coroutine, task, or task-group state |
| `OSError` | Failed filesystem and host operations |
| `TimeoutError` | Expired time limits |
| `StopIteration` | Iterator exhaustion |

Programs can construct and raise these classes in the same way as their own
exception classes.

### `raise`

`raise expression` raises a value of an exception type. The exception records the
source location of the `raise` statement and the Willow call frames that are
active. When an exception is raised by a failing runtime operation, it records the
location of that operation instead.

A `raise` statement with no expression may only appear inside an `except` clause.
It raises the exception handled by that clause again, keeping the exception's
original location and frames.

### `try`

A `try` statement has one or more `except` clauses, a `finally` clause, or both.
Each `except` clause names one exception class, optionally qualified with a
module name, and may bind the exception to a variable with `as name`. A bare
`except:`, a parenthesized list of classes, `except*`, and an `else` clause are
errors.

If the body raises an exception, the `except` clauses are tested in order. The
first clause that names the exception's class, or names `Exception`, handles it.
If no clause matches, the exception propagates. It is an error to write an
`except` clause after `except Exception`, or to name the same class in two
clauses.

The `finally` clause runs whenever control leaves the `try` statement: when the
body completes normally, when `return`, `break`, or `continue` leaves it, and
when the body or an `except` clause raises an exception. After `finally`
completes, control continues as it would have without it. The value of a
`return` is evaluated before `finally` runs. If the `finally` clause raises an
exception, that exception replaces the one being propagated. `return`, `break`,
and `continue` cannot appear directly inside a `finally` clause.

### Failures that are not exceptions

Running out of stack space or memory ends the program and cannot be caught. The
program reports the failure and exits with status 1 when it can; otherwise the
operating system ends it, with no diagnostic and a status of its own.

These failures end the program with exit status 1 and cannot be caught: failing
to write to stdout or stderr through `print`, `sys.eprint`, or the final flush
(§14), and failing to read stdin through `input`. Writing to a closed pipe is
one of these failures; it does not deliver a signal to the program.

In an async program, if no task can run and no I/O operation or timer is pending,
the program reports `deadlock: all tasks are waiting` and exits with status 1.

## 11. Built-in functions

| Function | Meaning |
| --- | --- |
| `print(value) -> none` | Write a printable value and `\n` to stdout |
| `input() -> str \| none` | The next line of stdin without its line ending, or `none` at end of input |
| `len`, `range`, `int`, `float`, `str`, `bytes`, `ord`, `chr`, `sorted` | See §6, §7, and §8 |
| `abs`, `round`, `min`, `max`, `sum`, `any`, `all`, `list`, `enumerate`, `zip` | See §7 |
| `iter(value)` | Obtain the iterator of an iterable (§3) |
| `next(iterator)` | Obtain its next value, or raise `StopIteration` (§3) |

The built-in names are these functions and the built-in exception classes.

A line of input ends at `\n`. `input` removes the `\n` and a `\r` immediately
before it. A final line with no line ending is returned as it is. Text read by
`input` must be valid UTF-8, or the call raises `ValueError` with the message
`invalid UTF-8`.

## 12. Modules

```python
# geometry.wlo
class Point:
    x: float
    y: float

def distance_squared(a: Point, b: Point) -> float:
    var dx = a.x - b.x
    var dy = a.y - b.y
    return dx * dx + dy * dy
```

```python
# main.wlo
import geometry

def main():
    var origin = geometry.Point(0.0, 0.0)
    var corner = geometry.Point(3.0, 4.0)
    print(geometry.distance_squared(origin, corner))    # 25.0
```

- `import name` loads the file `name.wlo`, and `import app.util` loads
  `app/util.wlo`, from the search roots described below. Each component of a
  module name is an identifier, and each import names one module. Directories
  serve only as namespaces, so importing `app.util` does not require or load a
  file named `app.wlo`.
- An import binds its first component as a name in the importing file's
  namespace (§9). Several imports may share the same first component, but that
  name cannot also be used for a function, class, enum, protocol, or alias. A name
  cannot be both a module and a namespace, so importing both `app` and `app.util`
  is an error. A local declaration with the same name hides the whole namespace
  from its declaration onward within its scope.
- `module.name`, written with the module's full name, as in `app.util.name`,
  refers to a function or type declaration in that module. It can be used
  in calls, constructors, annotations, `except` clauses, and `is` type tests.
  Modules and namespaces are not values. Names that begin with `_` are private to
  the module that declares them.
- Imports may form cycles. Modules contain only declarations, so the order in
  which they are loaded has no effect.

Modules are searched for in these roots, in order:

1. The directory of the entry file or, in a project, the project's source root.
2. The project's dependency roots. If a module is found in more than one
   dependency root, it is the error `module '<name>' is ambiguous: found in
   <file> and <file>`.
3. The standard library.

As a result, a program's own module takes precedence over a standard library
module with the same name. Imports are always absolute, so a module in `app/`
imports a module next to it as `app.other`. An import of a module that cannot be
found is an error at the import. Each file is loaded once and has a single module
name. Importing a loaded file under a second name is the error
`module '<name>' is the same file as module '<name>'`. The entry file has a
module name too, formed from its path under its root with `.wlo` removed and `/`
replaced by `.`, and an import of that name refers to the entry file itself.

### Projects

A `willow.json` file in the current directory describes a project:

```json
{
  "entry": "portcheck/main.wlo",
  "source": "src",
  "dependencies": ["vendor"],
  "tests": "tests"
}
```

The file contains a JSON object. Each of these keys is optional, and no other
keys are allowed:

- `entry` is the path of the entry file under the source root. It must end in
  `.wlo`, and each of its path components must be an identifier. The default is
  `main.wlo`.
- `source` is the source root. The default is `.`.
- `dependencies` is a list of dependency roots. The default is an empty list.
- `tests` is the test directory. The default is `tests`.

The paths in `source`, `dependencies`, and `tests` are relative to the directory
that contains `willow.json`. They may also be absolute or contain `..`. Roots
contain `.wlo` modules; manifests in dependency roots are not loaded. If a key
appears more than once, the last value is used. An unknown key, a value of the
wrong type, an empty path, or an invalid `entry` is an error that names
`willow.json`.

`willow init` creates a project in the current directory: a `willow.json` with
the source root `src` and the test directory `tests`, `src/main.wlo`,
`tests/test_main.wlo`, `AGENTS.md`, `.gitignore`, and a git repository. It is an error if `willow.json` already exists; other existing
files are left unchanged.

When no source file is given, `willow check`, `willow run`,
`willow compile -o <output>`, and `willow build -o <output>` use the project in
the current directory, and `willow run -- <args>` passes `<args>` to the program.
If there is no `willow.json`, these commands report
`no source file given and no willow.json in the current directory`. When a
source file is given, the commands search only that file's directory and the
standard library, whether or not a `willow.json` exists. Programs run in the
current directory, and their file operations are relative to it. Compiled and
built output contains every module the program uses, from all roots.
`willow compile -o <output>` writes the program as one QBE intermediate
language file. `willow build -o <output>` writes a native executable, and
`willow run` builds the program to a temporary file and runs it.

### Tests

```python
# test_cart.wlo, next to cart.wlo
import cart

def test_empty_cart_totals_zero():
    assert cart.Cart([]).total() == 0
```

`willow test [path]` takes a file or a directory, and defaults to `.`. For a
directory, it uses the files directly inside it whose names match `test_*.wlo`. A
file given explicitly may have any name. Each test file is an entry file, and its
imports are resolved from its own directory.

In a project, the default path is the project's test directory, directories are
searched recursively without following symlinks to directories, and imports are
resolved from the project's roots. The test directory is not a root, so modules
shared by tests must be placed under the source root or a dependency root.

A test file does not need a `main` function. Its functions whose names begin
with `test_` are its tests. Each test function must take no parameters and
return `none`.

A test function may be declared `async def`. It runs as the root task, as
an async `main` does (§15), and it passes when its body completes.

All test files and the modules they import are checked before any test runs.
Tests run in order of file path and then function name. Each test runs in a new
process with no program arguments, an empty stdin, and the current working
directory. A test passes when it returns. It fails when an exception propagates
out of it, when it calls `sys.exit` with any status, or when it ends abnormally
in any other way. A failing test does not stop later tests from running.

The report contains a line `PASS path name` or `FAIL path name` for each test.
After a `FAIL` line, the report shows the test's combined stdout and stderr,
indented, and its exit status. The last line gives the number of passed and
failed tests. The command exits with status 0 only if at least one test ran and
every test passed. Usage errors, check errors, finding no tests, and failed tests
give exit status 1. Tests share the filesystem and the environment.

`willow test --check [path]` finds and checks the tests without running them. It
exits with status 0 if there is at least one test and all tests are valid.

`willow run` and `willow test` set the environment variable `WILLOW` to the
absolute path of the `willow` launcher in the programs they run, replacing any
inherited value. Compiled and built programs do not set it.

## 13. Diagnostics

Compile-time errors have this form:

```text
hello.wlo:8:5: error: expected int, received str
```

Line and column numbers start at 1, and columns are counted in code points.

When an exception propagates out of `main`, the program reports the exception's
class and message at its recorded location, followed by its recorded call
frames:

```text
main.wlo:7:9: error: ParseError: not a digit: x
  in parse_digit at main.wlo:7:9
  called from main at main.wlo:13:15
```

The frames of an exception raised in a task end at that task's first frame.
For a task started by a task group, a final line gives the location of the
`start` call:

```text
server.wlo:12:9: error: ValueError: bad request
  in handle at server.wlo:12:9
  called from serve at server.wlo:20:13
  in task started at server.wlo:31:17
```

An exception observed again through `await`, `result()`, or a group keeps its
original location and frames.

Each location includes the name of its file. Diagnostics are written to stderr.

## 14. Standard library

The standard library consists of modules that are included with Willow. They are
imported in the same way as a program's own modules (§12).

### `aio`

```python
import aio

async def echo(listener: aio.Listener):
    with await listener.accept(timeout=5.0) as connection:
        await connection.sendall(await connection.recv(1024))

async def main():
    with aio.listen("127.0.0.1", 0) as listener:
        async with aio.task_group() as group:
            group.start(echo(listener))
            with await aio.connect("127.0.0.1", listener.local_port()) as client:
                await client.sendall("ping\n".encode())
                print((await client.recv(1024)).decode())    # ping
```

| Declaration | Meaning |
| --- | --- |
| `sleep(seconds: float) -> Coroutine[none]` | Wait for at least `seconds` seconds |
| `task_group() -> TaskGroup` | Create an inactive, single-use task group |
| `connect(host: str, port: int, timeout: float \| none = 30.0) -> Coroutine[Connection]` | Open a TCP connection |
| `listen(host: str, port: int, backlog: int = 16) -> Listener` | Listen for TCP connections on `host` |
| `semaphore(value: int = 1) -> Semaphore` | Create a semaphore with `value` permits |
| `class Task[T]` | A handle to a scheduled task (§15) |
| `class TaskGroup` | A scope owning concurrent tasks, entered with `async with` (§15) |
| `class Connection` | A native type with the methods below |
| `class Listener` | A native type with the methods below |
| `class Semaphore` | A native type with the methods below |

| Method | Meaning |
| --- | --- |
| `Connection.recv(size: int, timeout: float \| none = none) -> Coroutine[bytes]` | Return up to `size` bytes as soon as any arrive, or empty bytes when the peer has closed its side |
| `Connection.sendall(data: bytes, timeout: float \| none = none) -> Coroutine[none]` | Send all of `data` |
| `Connection.close() -> none` | Close the connection |
| `Listener.accept(timeout: float \| none = none) -> Coroutine[Connection]` | Wait for the next connection |
| `Listener.local_port() -> int` | The port the listener is bound to |
| `Listener.close() -> none` | Stop listening |
| `Connection.enter() -> Connection` | Return this open connection for scoped use |
| `Connection.exit(error: Exception \| none) -> none` | Close the connection |
| `Listener.enter() -> Listener` | Return this open listener for scoped use |
| `Listener.exit(error: Exception \| none) -> none` | Close the listener |
| `Semaphore.acquire() -> Coroutine[none]` | Take a permit, waiting until one is available |
| `Semaphore.release() -> none` | Return a permit |

`sleep` validates its argument as `time.sleep` does. `await aio.sleep(0.0)`
always suspends the current task, so other ready tasks run before it continues.
The task and task-group operations are specified in §15.

Hosts, ports, timeouts, validation, error messages, the unusable state after a
failed send, and the behavior of `close`, `enter`, and `exit` are the same as
for `net`. Host name lookup is synchronous: it happens before a timeout starts
and blocks every task while it runs.

A handle allows one unfinished operation in each direction: `recv` or `accept`
for receiving, and `sendall` for sending. Starting a second operation in the
same direction raises `RuntimeError` with the message
`recv is already in progress`, `accept is already in progress`, or
`sendall is already in progress` before performing any I/O. The first
operation and the handle remain usable. A `recv` and a `sendall` on one
connection may run at the same time.

Closing a handle wakes its pending operations, which raise `ValueError` with
that handle's closed-handle message. An operation never acts on a handle other
than its own.

A semaphore limits how many tasks hold a permit at once. `semaphore` raises
`ValueError` if `value` is not positive; `value` is also the most permits the
semaphore can hold. `acquire` is a cancellation checkpoint even when a permit
is free, but it suspends only when none is. Waiting tasks receive permits in
the order they began waiting, and a task that arrives later never overtakes
them. A task cancelled while waiting stops waiting without taking a permit; if
the cancellation arrives after a `release` handed it a permit, the permit goes
to the next waiter or back to the semaphore. `release` raises `ValueError` when
every permit is already available. A permit belongs to no task: scope one with
`try` and `finally`, releasing only after a successful `acquire`. A semaphore
whose waiters can never be woken is reported as a deadlock (§10).

```python
async def fetch(limit: aio.Semaphore):
    await limit.acquire()
    try:
        ...
    finally:
        limit.release()
```

### `cli`

```python
import cli
import io
import sys

def main():
    var parser = cli.parser("report", description="Summarize a log file")
    parser.add_int("limit", 10, help="Maximum rows", short="n")
    parser.add_positional("file")
    var args: cli.Args
    try:
        args = parser.parse(sys.args())
    except cli.HelpRequested as help:
        io.stdout().write_text(help.message)
        sys.exit(0)
    except cli.UsageError as error:
        sys.eprint(error.message)
        sys.exit(2)
    print(args.get_str("file"))
    print(args.get_int("limit"))
```

| Declaration | Meaning |
| --- | --- |
| `parser(prog: str, description: str = "") -> Parser` | A new parser for the program named `prog` |
| `class Parser` | A native type that declares arguments and parses them |
| `class Args` | A native type that holds the values from one parse |
| `class UsageError(Exception)` | Arguments that do not match the declarations |
| `class HelpRequested(Exception)` | `-h` or `--help` was given; the message is the help text |

| `Parser` method | Meaning |
| --- | --- |
| `add_str(name: str, default: str, help: str = "", short: str \| none = none, required: bool = false) -> none` | Declare a text option `--name VALUE` |
| `add_int(name: str, default: int, help: str = "", short: str \| none = none, required: bool = false) -> none` | Declare an integer option |
| `add_float(name: str, default: float, help: str = "", short: str \| none = none, required: bool = false) -> none` | Declare a number option |
| `add_flag(name: str, help: str = "", short: str \| none = none) -> none` | Declare an option that takes no value and is false unless given |
| `add_positional(name: str, help: str = "") -> none` | Declare a required positional argument |
| `add_rest(name: str, help: str = "") -> none` | Declare zero or more remaining positional arguments |
| `parse(args: list[str]) -> Args` | Parse `args` |
| `help() -> str` | The help text |

| `Args` method | Meaning |
| --- | --- |
| `get_str(name: str) -> str` | The value of a text option or positional argument |
| `get_int(name: str) -> int` | The value of an integer option |
| `get_float(name: str) -> float` | The value of a number option |
| `get_bool(name: str) -> bool` | The value of a flag |
| `get_list(name: str) -> list[str]` | A new list of the remaining positional arguments |

An argument name starts with an ASCII letter and continues with ASCII letters and
digits, which may be separated by single hyphens. An option named `name` is
written `--name` on the command line. A short name is a single ASCII letter,
written `-x`. Names and short names must be unique, and `help` and `h` are
reserved. Positional arguments share the same set of names as options and are
matched in the order they are declared. A parser can have at most one rest
argument, and it must be declared after the positional arguments.

An option's value is written as `--name value`, `--name=value`, or `-x value`.
The value is taken even if it begins with `-`. If an option is given more than
once, the last value is used. Options may appear between positional arguments.
Every argument after `--` is treated as positional, and `-` by itself is always
positional. Abbreviated option names, combined short options, and subcommands are
not supported. Integer and number values are converted the same way `int` and
`float` convert text (§6). An option declared with `required` must be given even
though it has a default. An option that is not given takes its default value.

The message of a `UsageError` is the usage line, a newline, and
`<prog>: error: ` followed by one of these:

- `unknown option '<arg>'`
- `option '--<name>' needs a value`
- `option '--<name>' takes no value`
- `option '--<name>' expects an integer, received '<value>'`, or
  `option '--<name>' expects a number, received '<value>'`
- `option '--<name>' is required`
- `missing argument '<name>'`
- `unexpected argument '<arg>'`

Neither `UsageError` nor `HelpRequested` prints anything or ends the program. A
program usually exits with status 2 after a usage error and with status 0 after
printing the help text.

The help text starts with `usage: <prog> [options]` followed by the positional
arguments. Next comes the description, then an `arguments:` section and an
`options:` section, each listing its entries in declaration order with their
help text aligned. Each option that takes a value shows an upper-case
placeholder, and either `(required)` or `(default: <value>)` when the default is
not empty. Every line ends with a newline, including the last.

An invalid declaration raises `ValueError` with a message such as
`invalid name '<name>'`, `duplicate name '<name>'`, or
`'help' and 'h' are reserved`. A getter raises `ValueError` if the name was not
declared (`no argument named '<name>'`) or belongs to an argument of a different
kind (`'<name>' is not an int argument`). Each call to `parse` returns a separate
`Args` value.

### `fs`

| Declaration | Meaning |
| --- | --- |
| `read_file(path: str) -> str` | The contents of the file |
| `write_file(path: str, text: str) -> none` | Create the file, or replace its contents, with `text` |
| `join(a: str, b: str) -> str` | `a` and `b` joined with `/`; if `b` is absolute, the result is `b` |
| `basename(path: str) -> str` | The text after the last `/`, or empty if the path ends with `/` |
| `dirname(path: str) -> str` | The text through the last `/`, without trailing slashes unless it is all slashes, or empty if there is no `/` |
| `listdir(path: str) -> list[str]` | The names of the entries in the directory, excluding `.` and `..`, sorted by code point |
| `stat(path: str, follow_symlinks: bool = true) -> Stat` | Metadata for the file |
| `exists(path: str) -> bool` | Whether the path exists, following symlinks |
| `mkdir(path: str, parents: bool = false, exist_ok: bool = false) -> none` | Create a directory |
| `remove(path: str) -> none` | Remove a file or symlink |
| `rmdir(path: str) -> none` | Remove an empty directory |
| `rename(source: str, destination: str) -> none` | Rename a file or directory, replacing the destination where POSIX allows it |
| `read_bytes(path: str) -> bytes` | The contents of the file, without decoding |
| `write_bytes(path: str, data: bytes) -> none` | Create the file, or replace its contents, with `data` |
| `copy_file(source: str, destination: str) -> none` | Copy the contents of a file, creating or replacing the destination |
| `normpath(path: str) -> str` | `path` with redundant separators and `.` and `..` components removed |
| `abspath(path: str) -> str` | `path` made absolute against the working directory and normalized |
| `realpath(path: str) -> str` | The absolute path of an existing file with symlinks resolved |
| `glob(pattern: str) -> list[str]` | The paths that match `pattern`, sorted by code point |
| `walk(path: str) -> Iterator[tuple[str, list[str], list[str]]]` | The directory tree below `path`, one tuple of directory path, directory names, and other names per directory, top down |
| `temp_file(prefix: str = "willow-", directory: str \| none = none) -> str` | Create a new empty file with a unique name and return its path |
| `temp_dir(prefix: str = "willow-", directory: str \| none = none) -> str` | Create a new empty directory with a unique name and return its path |
| `class Stat` | A class with the fields `kind: str`, `size: int`, and `modified: float` |

Paths are strings. A relative path is relative to the working directory.
`read_file` and `write_file` read and write text exactly as it is, without
translating line endings. `write_file` does not replace the file atomically.

`join`, `basename`, and `dirname` operate only on the text of the path. They do
not access the filesystem, follow symlinks, or resolve `..`. `join` adds a `/`
between `a` and `b` only when `a` is not empty and does not already end with
one, so `join("a", "")` is `a/`, `join("a/", "b")` is `a/b`, and
`join("", "b")` is `b`. For example, `dirname("/a")` is `/`,
`dirname("a//b")` is `a`, and `dirname("//a")` is `//`.

`read_bytes` and `write_bytes` follow `read_file` and `write_file`, except that
they do not decode. `copy_file` streams the data of `source` to `destination`,
which it creates or truncates first. It does not copy permissions, ownership, or
timestamps, and it does not replace the destination atomically. If `source` and
`destination` are the same file, or `source` cannot be read, `copy_file` raises
`OSError` before it changes the destination.

`normpath` and `abspath` operate on the text of the path. `normpath` collapses
repeated slashes, removes `.` components and trailing slashes, and removes each
`..` together with the component before it when that component is not `..`. A
`..` with no such component is kept in a relative path and removed directly
after the root. Exactly two leading
slashes are kept as two; one, or three or more, become one. An empty result is
`.`. So `normpath("a/./b/../c/")` is `a/c`, `normpath("../../a/..")` is
`../..`, `normpath("/../a")` is `/a`, `normpath("//a/../b")` is `//b`, and
`normpath("")` is `.`. `abspath` joins a relative path to the working directory
first. `realpath`
asks the system to resolve the path, which must exist, and raises `OSError`
otherwise.

`glob` matches `*`, `?`, and `[...]` (with `!` negating a set) within each path
component. A backslash is an ordinary character, and `**` is not recursive. A
name that starts with `.` is matched only by a component that starts with `.`.
A pattern without wildcard characters matches itself when the path exists, a
pattern ending with `/` matches directories, and a directory that cannot be read
has no matches. A pattern with no matches gives an empty list.

`walk` yields the starting directory and then each directory below it, parents
before children, with each directory's entries sorted by code point. The two
lists hold the names of the real directories and of every other entry. A symlink,
even to a directory, is not a real directory: it is listed with the other entries
and not entered. Each list is a snapshot, and changing it does not change which
directories `walk` visits. The directory is read completely and closed before its
tuple is yielded. A failure, including one for `path` itself, raises on the
`next` call that reaches it.

`temp_file` and `temp_dir` create the entry atomically in `directory`, or if it
is `none`, in the directory named by the `TMPDIR` environment variable, or `/tmp`
when that is unset or empty. Its name is `prefix` followed by six random
characters. A `prefix` that contains `/` or a NUL character raises `ValueError`.
The file is closed before `temp_file` returns. The program owns the entry and
removes it with `remove` or `rmdir`.

`Stat` is an ordinary class. `kind` is `file`, `directory`, `symlink`, or
`other`. `size` is the size in bytes. `modified` is the time of the last
modification, in seconds since the Unix epoch. When `follow_symlinks` is true,
`stat` describes the target of a symlink rather than the symlink itself. A size
larger than the `int` range raises `OverflowError` with the message
`file size out of range`.

`exists` returns false for a missing path, a symlink whose target does not exist,
or a path that passes through something that is not a directory. Any other
failure raises an exception. `mkdir` with `parents` creates any missing parent
directories. With `exist_ok`, `mkdir` succeeds if the directory already exists,
but not if a file exists at the path. New directories receive the system's
default permissions, as modified by the umask. `rename` cannot move a file to a
different filesystem.

A path that contains a NUL character raises `ValueError` with the message
`path contains a NUL character`. Text read by `read_file` and names returned by
`listdir` must be valid UTF-8, or the call raises `ValueError` with the message
`invalid UTF-8`. When the operating system reports a failure, the function raises
`OSError` with a message that names the operation and the path and gives the
system's reason. Examples are `cannot read <path>: <reason>`,
`cannot write <path>: <reason>`, `cannot list <path>: <reason>`,
`cannot remove directory <path>: <reason>`, `cannot resolve <path>: <reason>`, and
`cannot create temporary file in <directory>: <reason>`.

### `hash`

| Declaration | Meaning |
| --- | --- |
| `sha256(data: bytes) -> bytes` | Return the 32-byte SHA-256 digest of `data` |
| `sha256_hasher() -> Sha256` | Create an incremental SHA-256 computation with empty input |
| `class Sha256` | An incremental SHA-256 computation with the methods below |
| `Sha256.update(data: bytes) -> none` | Append `data` to the input |
| `Sha256.digest() -> bytes` | Return the 32-byte digest of the input so far |
| `Sha256.hexdigest() -> str` | Return the digest as 64 lowercase hexadecimal digits |

SHA-256 follows [FIPS 180-4](https://doi.org/10.6028/NIST.FIPS.180-4).
Updates hash the concatenation of their arguments; an empty update has no
effect. `digest` and `hexdigest` leave the
computation unchanged: repeated calls give the same result, and later updates
append to the original input. Separate instances have independent state.

### `http`

```python
import http
import json

def main():
    var response = http.request("GET", "https://example.com/api/items?" + http.urlencode({"q": "tea"}))
    if response.status == 200:
        var items = json.parse(response.body.decode())
    var body = json.dump({"name": "tea"}).encode()
    var headers = [http.Header("Content-Type", "application/json")]
    var created = http.request("POST", "https://example.com/api/items", headers=headers, body=body)
    print(created.status)
```

| Declaration | Meaning |
| --- | --- |
| `request(method: str, url: str, headers: list[Header] \| none = none, body: bytes \| none = none, timeout: float = 30.0, follow_redirects: bool = true, ca_file: str \| none = none) -> Response` | Make a request and read the whole response |
| `download(url: str, path: str, headers: list[Header] \| none = none, timeout: float = 30.0, follow_redirects: bool = true, ca_file: str \| none = none) -> Download` | Send a `GET` request and save the response body to the file at `path` |
| `request_async(method: str, url: str, headers: list[Header] \| none = none, body: bytes \| none = none, timeout: float = 30.0, follow_redirects: bool = true, ca_file: str \| none = none) -> Coroutine[Response]` | `request` for tasks |
| `download_async(url: str, path: str, headers: list[Header] \| none = none, timeout: float = 30.0, follow_redirects: bool = true, ca_file: str \| none = none) -> Coroutine[Download]` | `download` for tasks |
| `header(headers: list[Header], name: str) -> str \| none` | The value of the first header named `name`, compared case-insensitively, or `none` |
| `urlencode(values: dict[str, str]) -> str` | `values` encoded as `key=value` pairs joined with `&`, in insertion order |
| `class Header` | A class with the fields `name: str` and `value: str` |
| `class Response` | A class with the fields `status: int`, `headers: list[Header]`, `body: bytes`, and `url: str` |
| `class Download` | A class with the fields `status: int`, `headers: list[Header]`, `url: str`, and `bytes_written: int` |

The `http` module uses the system's libcurl. macOS includes libcurl. On Linux, a
program that makes requests needs the `libcurl4` and `ca-certificates` packages.
If libcurl cannot be loaded, a request raises `OSError` with the message
`cannot load libcurl: <reason>`. Programs that do not import `http` do not need
libcurl.

A URL must be an absolute `http` or `https` URL with an ASCII host name and an
optional port. Internationalized domain names must be given in their ASCII form.
The URL's fragment is not sent. Bytes that are not allowed in URLs, including
non-ASCII UTF-8 text, are percent-encoded, and existing `%XX` escapes are kept as
they are. Other schemes, relative URLs, and malformed hosts or ports raise
`ValueError` with the message `invalid URL '<url>'`. A URL that contains user
information raises `ValueError` with the message
`URL user information is not allowed`.

The method is sent exactly as given and must be a valid HTTP token. Header names
must be valid tokens, and header values may contain only printable ASCII and
tab. The `Host`, `Content-Length`, and `Transfer-Encoding` headers are set by
the module, and giving any of them raises `ValueError`. Response headers are
returned in the order received, including repeated headers. Bytes above 127 in
response headers are read as the characters U+0080 through U+00FF.

`urlencode` keeps ASCII letters, digits, `-`, `.`, `_`, and `~` as they are,
writes spaces as `+`, and percent-encodes the UTF-8 encoding of every other
character. It does not add a leading `?`.

Every completed exchange returns its status, including 4xx and 5xx statuses. The
body contains the bytes received, without transfer encoding. The module does not
decompress or decode the body. It does not handle cookies, retry requests, send
credentials, or use proxies, regardless of environment variables. Connection,
protocol, and TLS failures raise `OSError` with the message
`cannot fetch <url>: <reason>`.

When `follow_redirects` is true, `GET` and `HEAD` requests follow 301, 302, 303,
307, and 308 responses that have a `Location` header. The location is resolved
relative to the current URL. At most ten redirects are followed, and an eleventh
raises `OSError` with the message `too many redirects`. A redirect from `https`
to `http` raises `OSError` with the message
`refusing to follow a redirect from https to http`. For other methods, the
redirect response itself is returned. If a redirect changes the scheme, host, or
port, the caller's headers are not sent to the new location. The result
describes the final request and response.

`timeout` limits periods of inactivity. Connecting, and each wait for more data,
may each take at most `timeout` seconds, so a slow transfer that keeps receiving
data can take longer in total. When the time limit expires, the request raises
`TimeoutError` with the message `request timed out after <timeout> seconds`. The
timeout does not include looking up the host name, which may take longer. The
timeout must be finite and positive.

HTTPS requests always verify the server's certificate and host name. By default,
the certificate is checked against the platform's trusted certificates. When
`ca_file` is given, it is checked only against the PEM bundle in that file.

`download` writes a 2xx response body to a temporary file in the same directory
as `path`. After the whole body has been written and the file closed, it replaces
`path` with the temporary file, so `path` is never left partly written. If the
final response is not 2xx, `download` returns its status with `bytes_written`
set to 0 and does not change `path`. If the download fails, the temporary file is
removed. The body is written to the file as it arrives instead of being held in
memory.

`request_async` and `download_async` take the same parameters and defaults as
`request` and `download`, return the same results, and raise the same errors,
which are raised when the coroutine is awaited. The transfer advances in steps
of at most 10 ms, between which other tasks run. A request that is cancelled
releases its connection as a failed request does, and a cancelled download
removes its temporary file and leaves `path` unchanged. Host name lookup is
synchronous unless the system's libcurl resolves names in the background, and
blocks every task while it runs. `timeout` applies as for `request`.

### `io`

```python
import io

def main():
    var source = io.open("input.bin")
    try:
        var target = io.open("output.bin", mode="w")
        try:
            while true:
                var chunk = source.read(65536)
                if len(chunk) == 0:
                    break
                target.write(chunk)
        finally:
            target.close()
    finally:
        source.close()
```

| Declaration | Meaning |
| --- | --- |
| `open(path: str, mode: str = "r") -> File` | Open a file for reading (`r`), for writing after creating or truncating it (`w`), or for appending after creating it if needed (`a`) |
| `stdin() -> File` | A handle for standard input, open for reading |
| `stdout() -> File` | A handle for standard output, open for writing |
| `stderr() -> File` | A handle for standard error, open for writing |
| `class File` | A native type with the methods below |

| `File` method | Meaning |
| --- | --- |
| `read(size: int) -> bytes` | Read up to `size` octets; the result is empty only at end of input |
| `readline() -> str \| none` | Read the next line the same way `input` does, or return `none` at end of input |
| `write(data: bytes) -> none` | Write all of `data` |
| `write_text(text: str) -> none` | Write the UTF-8 encoding of `text`, without adding a newline |
| `iter() -> Iterator[str]` | Iterate over lines from the current file position |
| `flush() -> none` | Write any buffered data |
| `close() -> none` | Flush and close the file |
| `enter() -> File` | Return this open file for scoped use |
| `exit(error: Exception \| none) -> none` | Close the file |

A native type is a library class that has methods and no fields. Its values can
only be created by functions in its module. A native type can be used in
annotations, aliases, unions, and `is` type tests, and its values can be stored and
passed as arguments. It does not support `==`, printing, or construction. All
references to a handle refer to the same handle, so closing it through one
reference closes it for all of them.

Files contain octets, and no newline translation is done. `readline` and
`write_text` use UTF-8. `readline` removes the line's `\n` and a `\r`
immediately before it. It returns a final line that has no line ending as it is,
and returns `""` for an empty line. If a line is not valid UTF-8, `readline`
consumes it and then raises `ValueError` with the message `invalid UTF-8`. Byte
reads and line reads share the same file position. A read may return fewer octets
than requested.

The standard handles share their buffers with `input`, `print`, and
`sys.eprint`, so reads and writes through either keep their relative order.
stdout and stderr are flushed when `main` returns, when an uncaught exception
ends the program, and when `sys.exit` is called. Data written to a file opened
with `open` is only guaranteed to reach the file after `flush` or `close`, so
programs should close such files with `with` or a `try`/`finally` statement.

`enter` rejects a closed file and rejects a standard stream with
`cannot close a standard stream` before the body can run. `exit` has the same
behavior as `close`.

Each `iter` call returns a fresh iterator that reads through `readline`. Iterators
share the file's position with other reads, yield lines without their line
endings, and do not close the file. A closed file raises the usual closed-file
error when an iterator tries to read from it.

Calling `close` more than once has no further effect, and `close` closes the
handle even if flushing fails. These operations raise `ValueError`:

- any other operation on a closed handle: `I/O operation on closed file`
- reading from a handle opened for writing, or writing to a handle opened for
  reading: `file is not open for reading` or `file is not open for writing`
- `read` with a size less than 1: `read size must be positive`
- closing a standard handle: `cannot close a standard stream`
- `open` with an unknown mode: `invalid mode '<mode>'`
- `open` with a path that contains a NUL character:
  `path contains a NUL character`

When the operating system reports a failure, the operation raises `OSError` with
the message `cannot open <path>: <reason>`, `cannot read <path>: <reason>`,
`cannot write <path>: <reason>`, or `cannot close <path>: <reason>`. The paths of
the standard handles are `<stdin>`, `<stdout>`, and `<stderr>`. A failed write
through a handle can be caught, including a write to a closed pipe. This differs
from `print` (§10).

### `json`

```python
import json

def main():
    var doc = json.parse('{"name": "Willow", "ports": [80, 443]}')
    if doc is dict:
        var ports = doc["ports"]
        if ports is list:
            print(len(ports))       # 2
    var reply: json.Json = {"ok": true, "items": [1, 2.5, none]}
    print(json.dump(reply))         # {"ok":true,"items":[1,2.5,null]}
```

| Declaration | Meaning |
| --- | --- |
| `type Json = none \| bool \| int \| float \| str \| list[Json] \| dict[str, Json]` | A JSON value |
| `class JsonError(Exception)` | Invalid JSON text, or a value that `dump` cannot encode |
| `parse(text: str) -> Json` | The value represented by the JSON text `text` |
| `dump(value: Json) -> str` | The JSON text for `value` |

`parse` accepts JSON as defined by RFC 8259, with integer tokens limited to the
`int` range. A number with no fraction or exponent becomes an `int`; if it is
outside the `int` range, parsing raises `JsonError` with the message
`integer out of range` and the line and column of the number's first character.
A number with a fraction or exponent becomes the nearest `float`. If an object
contains the same key more than once, the entry keeps the position of the first
occurrence and the value of the last. Text that is not valid JSON, including an
escape for an unpaired surrogate, raises `JsonError` with a message that
describes the problem and gives its line and column.

`dump` writes no whitespace and keeps the order of dictionary entries. Floats are
written the same way `str` writes them, so `2.0` is parsed back as a `float`.
Strings escape `"`, `\`, and control characters. Control characters use `\b`,
`\f`, `\n`, `\r`, and `\t` where those escapes exist and `\u00XX` otherwise. All
other characters are written unchanged. NaN and infinities raise `JsonError` with
the message `cannot encode <value>`, as in `cannot encode inf`.

### `math`

| Function | Meaning |
| --- | --- |
| `sqrt(x: float) -> float` | The square root of `x`, correctly rounded |
| `floor(x: float) -> int` | The largest integer not greater than `x` |
| `ceil(x: float) -> int` | The smallest integer not less than `x` |
| `isfinite(x: float) -> bool` | Whether `x` is neither infinite nor NaN |
| `isnan(x: float) -> bool` | Whether `x` is NaN |
| `isinf(x: float) -> bool` | Whether `x` is positive or negative infinity |
| `pow(x: float, y: float) -> float` | `x` raised to the power `y` |
| `exp(x: float) -> float` | `e` raised to the power `x` |
| `log(x: float) -> float` | The natural logarithm of `x` |
| `log10(x: float) -> float` | The base-10 logarithm of `x` |
| `sin(x: float)`, `cos(x: float)`, `tan(x: float) -> float` | Trigonometric functions of `x` in radians |
| `asin(x: float)`, `acos(x: float)`, `atan(x: float) -> float` | Inverse trigonometric functions, in radians |
| `atan2(y: float, x: float) -> float` | The angle in radians of the point `(x, y)` |

`math` also provides the `float` constants `pi`, `e`, and `tau` (`2 * pi`).
They are values, not functions, and cannot be assigned.

`sqrt` follows IEEE 754: `sqrt(-0.0)` is `-0.0`, and the square root of a
negative number or NaN is NaN. The other functions that return `float` follow
the host's C math library in the same way: a domain error such as `log(-1.0)`
is NaN, an overflow such as `exp(1000.0)` is infinity, and a result that is a
zero keeps its sign. `floor` and `ceil` raise `ValueError` if `x` is NaN or
infinite or the result is outside the range of `int`.

### `net`

```python
import net

def main():
    var listener = net.listen("127.0.0.1", 0)
    var client = net.connect("127.0.0.1", listener.local_port())
    var server = listener.accept(timeout=5.0)
    client.sendall("ping\n".encode())
    print(server.recv(1024).decode())       # ping
    client.close()
    server.close()
    listener.close()
```

| Declaration | Meaning |
| --- | --- |
| `connect(host: str, port: int, timeout: float \| none = 30.0) -> Connection` | Open a TCP connection |
| `listen(host: str, port: int, backlog: int = 16) -> Listener` | Listen for TCP connections on `host` |
| `reader(connection: Connection) -> Reader` | Buffer reads from `connection`, which the reader then owns |
| `class Connection` | A native type with the methods below |
| `class Listener` | A native type with the methods below |
| `class Reader` | A native type with the methods below |

| Method | Meaning |
| --- | --- |
| `Connection.recv(size: int, timeout: float \| none = none) -> bytes` | Return up to `size` bytes as soon as any arrive, or empty bytes when the peer has closed its side |
| `Connection.sendall(data: bytes, timeout: float \| none = none) -> none` | Send all of `data` |
| `Connection.close() -> none` | Close the connection |
| `Listener.accept(timeout: float \| none = none) -> Connection` | Wait for the next connection |
| `Listener.local_port() -> int` | The port the listener is bound to |
| `Listener.close() -> none` | Stop listening |
| `Connection.enter() -> Connection` | Return this open connection for scoped use |
| `Connection.exit(error: Exception \| none) -> none` | Close the connection |
| `Listener.enter() -> Listener` | Return this open listener for scoped use |
| `Listener.exit(error: Exception \| none) -> none` | Close the listener |
| `Reader.read_exactly(size: int, timeout: float \| none = none) -> bytes` | Return exactly `size` bytes |
| `Reader.read_until(separator: bytes, max_bytes: int = 1048576, timeout: float \| none = none) -> bytes` | Return the bytes through the next `separator` |
| `Reader.close() -> none` | Close the reader and its connection |
| `Reader.enter() -> Reader` | Return this open reader for scoped use |
| `Reader.exit(error: Exception \| none) -> none` | Close the reader and its connection |

A host is a host name, which is looked up with the system resolver, or a literal
IPv4 or IPv6 address. Hosts are written in ASCII, and internationalized domain
names must be given in their ASCII form. Ports range from 1 through 65535.
`listen` also accepts port 0, which selects a free port. `listen` binds exactly
the given address, so a local service should use a loopback address. `connect`
tries each resolved address in order, all within one timeout. `listen` binds the
first resolved address that works. Host name lookup happens before the timeout
starts and may take longer.

Each call to `recv`, `sendall`, and `accept` has its own timeout. To limit an
exchange that involves several calls, compute a deadline with
`time.monotonic()`. The program is responsible for dividing data into messages,
because one `recv` may return part of a message or several messages. When a
`recv` or `accept` times out, it raises `TimeoutError` and the handle remains
usable. `sendall` either sends all of the data or raises an exception, and its
timeout covers the whole call. After a send fails or times out, the peer may have
received any part of the data, so every later operation on the connection raises
`ValueError` with the message `connection is unusable after a failed send`.

Calling `close` more than once has no further effect. Other operations on a
closed handle raise `ValueError` with the message
`I/O operation on closed connection` or `I/O operation on closed listener`. An
invalid host name or port, a `size` or `backlog` less than 1, and a timeout that
is not finite and positive raise `ValueError`. Failures to resolve a host,
connect, listen, send, or receive raise `OSError` with messages such as
`cannot resolve <host>: <reason>`, `cannot connect to <host>:<port>: <reason>`,
and `cannot send: <reason>`. Writing to a connection whose peer has closed it is
such a failure and does not deliver a signal. Timeouts raise `TimeoutError` with
messages such as `recv timed out after <timeout> seconds`. Child processes do not
inherit connections or listeners.

`enter` rejects a closed or unusable handle with the same error as its other
operations. `exit` has the same behavior as `close`.

A `Reader` receives from its connection into a buffer and keeps the bytes a call
did not return for the next call. Once a connection is given to `reader`, the
program must not call `recv` on it, because the reader may hold bytes that
`recv` would skip; closing the reader closes the connection. `reader` rejects a
closed or unusable connection like `enter`.

`read_exactly` returns `size` bytes, and empty bytes for a `size` of 0. If the
peer closes the connection first, it raises `OSError` with a message that starts
`unexpected end of stream`. `read_until` returns the bytes up to and including
the first `separator`; a separator that ends exactly at `max_bytes` is found. If
the peer closes the connection first, it returns the bytes that remain, which
are empty when there are none. If `max_bytes` bytes arrive without a complete
separator, it raises `ValueError` with a message that starts
`separator not found`. A negative `size`, an empty `separator`, a `max_bytes`
less than 1, and a timeout that is not finite and positive raise `ValueError`.

The `timeout` of a `Reader` call covers the whole call, however many receives it
takes, and expiry raises `TimeoutError` with a message such as
`read_exactly timed out after <timeout> seconds`. Bytes already received stay
buffered after a timeout, a size limit, or an early end of stream, so the next
call sees them. Operations on a closed reader raise `ValueError` with the
message `I/O operation on closed reader`.

### `random`

```python
import random

def main():
    var rng = random.generator(42)
    print(rng.randint(1, 6))
    var items = ["a", "b", "c"]
    rng.shuffle(items)
    print(rng.choice(items))
    var key = random.secure_bytes(16)
```

| Declaration | Meaning |
| --- | --- |
| `generator(seed: int) -> Random` | A new pseudo-random generator started from `seed` |
| `secure_bytes(size: int) -> bytes` | `size` bytes from the operating system's random source |
| `class Random` | A native type with the methods below |

| Method | Meaning |
| --- | --- |
| `Random.random() -> float` | The next float in `[0, 1)` |
| `Random.randint(a: int, b: int) -> int` | The next integer from `a` through `b`, inclusive |
| `Random.choice[T](items: list[T]) -> T` | A uniformly chosen element of `items` |
| `Random.shuffle[T](items: list[T]) -> none` | Reorder `items` in place, uniformly at random |

Each `Random` has its own state, so the same seed always produces the same
sequence of results from the same calls, in this version of Willow. The
generator is a small 32-bit PRNG
for simulations, tests, and games. It is not secure; use `secure_bytes` for
secrets. `randint` accepts any `a <= b` in the `int` range. `choice` of an empty
list and `randint` with `a > b` raise `ValueError`. `secure_bytes` with a
negative `size` raises `ValueError`, and a failure to read the random source
raises `OSError`.

### `subprocess`

```python
import subprocess

def main():
    var result = subprocess.run(["printf", "%s", "hello"], capture_output=true)
    var output = result.stdout
    if output is not none:
        print(output.decode())          # hello
```

| Declaration | Meaning |
| --- | --- |
| `run(args: list[str], input: bytes \| none = none, capture_output: bool = false, cwd: str \| none = none, env: dict[str, str] \| none = none, timeout: float \| none = none) -> Result` | Run a command and wait for it to finish |
| `run_async(args: list[str], input: bytes \| none = none, capture_output: bool = false, cwd: str \| none = none, env: dict[str, str] \| none = none, timeout: float \| none = none) -> Coroutine[Result]` | `run` for a task, without blocking other tasks |
| `spawn(args: list[str], cwd: str \| none = none, env: dict[str, str] \| none = none, stdin: io.File \| none = none, stdout: io.File \| none = none, stderr: io.File \| none = none) -> Process` | Start a command and return without waiting for it |
| `class Result` | A class with the fields `returncode: int`, `stdout: bytes \| none`, and `stderr: bytes \| none` |
| `class Process` | A native type with the methods below |

| `Process` method | Meaning |
| --- | --- |
| `poll() -> int \| none` | The exit status if the child has exited, otherwise `none` |
| `wait(timeout: float \| none = none) -> int` | Wait for the child to exit and return its status |
| `wait_async(timeout: float \| none = none) -> Coroutine[int]` | `wait` for a task, without blocking other tasks |
| `terminate() -> none` | Send `SIGTERM` to the child |
| `kill() -> none` | Send `SIGKILL` to the child |

`args` contains the program followed by its arguments. They are passed to the
program directly, without a shell. A program name that contains `/` is treated as
a path. Any other program name is searched for in the `PATH` of the child's
environment, or in `/usr/bin:/bin` if that environment has no `PATH`. `cwd` sets
the child's working directory and `env` replaces its environment. When either is
`none`, the child inherits the parent's. A process's status is its exit code, or
the negative of the signal number if a signal ended it. A nonzero status is
returned normally and does not raise an exception.

When `run` is given `input`, it writes the input to the child's stdin and then
closes it. Empty input gives the child an immediate end of input. If the child
does not read all of the input, the rest is discarded without an error. Without
`input`, the child inherits stdin. With `capture_output`, `run` collects the
child's stdout and stderr as bytes while it writes the input, so full pipes
cannot deadlock. Without `capture_output`, the child inherits stdout and
stderr, and both fields of the result are `none`. Captured output is held in
memory. `run` returns as soon as the child exits, even if processes started by
the child are still running.

`timeout` limits how long `run` waits, starting when the child starts. When the
time limit expires, `run` kills the child, waits for it to exit, and raises
`TimeoutError` with the message `command timed out after <timeout> seconds`.
Processes started by the child are not killed.

`spawn` connects the child's standard streams to the given `io.File` handles.
The `stdin` handle must be open for reading, and the `stdout` and `stderr`
handles must be open for writing. When a handle is `none`, the child inherits
that stream. The parent's handles remain open. If the `stdin` handle may already
have input read into its buffer, `spawn` raises `ValueError` with the message
`stdin has buffered input`. This is the case when the handle has been read from
and either is not a seekable file or has a non-empty buffer. A child that
inherits stdin does not receive input that the parent has already buffered.

Once a child's exit status has been collected, the `Process` remembers it, so
`poll` and `wait` return the same status, and `terminate` and `kill` do nothing.
`wait` with a `timeout` raises `TimeoutError` with the message
`process did not exit within <timeout> seconds` and leaves the child running.
Children are not stopped or waited for automatically.

`run_async` and `wait_async` take the same arguments and give the same results
and errors as `run` and `wait`, but only when the coroutine is awaited, and they
suspend the calling task instead of blocking the program (§15). Each begins with
an await checkpoint. `run_async` writes the input and collects the output
without blocking, so other tasks run even while a command moves large amounts of
data. It does not use threads: while the child runs, the task checks its pipes
and its exit status at intervals of at most 10 ms, so the child's exit can be
noticed up to 10 ms late. A `timeout` is a deadline for the whole operation.
If `run_async` times out, is cancelled, or fails, it kills the child with
`SIGKILL`, waits for it to exit, and closes its pipes before the original
`TimeoutError` or cancellation continues; processes started by the child are
not killed. `wait_async` is cancelled or times out like `wait`: it leaves the
child running and owned by the caller.

Before a child starts, stdout, stderr, and any `io.File` handles passed to
`spawn` for writing are flushed. If flushing fails, the call raises `OSError` and
the child does not start. Children start with the default action for `SIGPIPE`.
These cases raise `ValueError`:

- empty `args` or an empty program name:
  `args must contain a nonempty executable name`
- a NUL character in an argument, in `cwd`, or in an environment value
- an invalid environment variable name
- a timeout that is not finite and positive:
  `timeout must be finite and positive`
- a closed handle, or a handle open in the wrong direction, such as
  `stdout must be open for writing`

A program that cannot be found or started raises `OSError` with the message
`cannot run <program>: <reason>`.

### `sys`

```python
import fs
import sys

def main():
    var args = sys.args()
    if len(args) != 1:
        sys.eprint("usage: chars <file>")
        sys.exit(2)
    var text: str
    try:
        text = fs.read_file(args[0])
    except OSError as error:
        sys.eprint(error.message)
        sys.exit(1)
    print(len(text))
```

| Function | Meaning |
| --- | --- |
| `args() -> list[str]` | A new list of the program's arguments in order, not including the program name |
| `eprint(value) -> none` | Write a printable value and `\n` to stderr |
| `exit(status: int) -> none` | End the program with exit status `status` |
| `getenv(name: str) -> str \| none` | The value of the environment variable `name`, or `none` if it is not set |
| `environ() -> dict[str, str]` | A new dictionary of the environment variables, ordered by name |
| `getcwd() -> str` | The absolute path of the working directory |

`args` raises `ValueError` with the message `invalid UTF-8` if an argument is not
valid UTF-8.

`exit` takes a status from 0 through 255. Any other status raises `ValueError`
with the message `exit status out of range`. `exit` flushes stdout and stderr and
ends the program immediately, without running pending `finally` clauses.

Changing the dictionary returned by `environ` does not change the environment.
An environment variable name that is empty or contains `=` or a NUL character
raises `ValueError` with the message `invalid environment variable name`.
Environment values and the working directory must be valid UTF-8, or the call
raises `ValueError` with the message `invalid UTF-8`.

### `terminal`

| Function | Meaning |
| --- | --- |
| `isatty(file: io.File) -> bool` | Whether `file` is a terminal |
| `color_enabled(file: io.File) -> bool` | Whether `file` is a terminal, `TERM` is not `dumb`, and `NO_COLOR` is not set |
| `style(text: str, color: str = "default", bold: bool = false, enabled: bool = true) -> str` | `text` wrapped in ANSI escape sequences for the color and bold setting, or `text` unchanged when `enabled` is false |
| `progress(message: str) -> none` | Replace the progress line on stderr with `message` |
| `finish_progress(message: str = "") -> none` | Clear the progress line, then write `message` and a newline to stderr if `message` is not empty |

The colors are `default`, `black`, `red`, `green`, `yellow`, `blue`, `magenta`,
`cyan`, and `white`. Any other color raises `ValueError` with the message
`unknown color '<color>'`. `style` does not inspect any stream. Callers pass
`enabled=terminal.color_enabled(stream)` or make their own choice.

`progress` writes nothing unless stderr is a terminal and `TERM` is not `dumb`.
A message that contains CR or LF raises `ValueError` with the message
`progress message cannot contain a line break`. `finish_progress` clears the
progress line only on such a terminal, but it writes its message in every case.
Both functions flush stderr, which they write through the same buffer as
`sys.eprint`. Neither function writes to stdout.

### `time`

| Function | Meaning |
| --- | --- |
| `time() -> float` | Seconds since the Unix epoch |
| `monotonic() -> float` | Seconds on a clock that never goes backward, measured from an unspecified starting point |
| `sleep(seconds: float) -> none` | Wait for at least `seconds` seconds |
| `utc(timestamp: float) -> str` | The UTC time `timestamp`, formatted as `YYYY-MM-DDTHH:MM:SSZ` |

`sleep` raises `ValueError` with the message
`sleep length must be finite and nonnegative` if the duration is negative or not
finite. `utc` rounds down to whole seconds and supports years 0001 through 9999.
Timestamps outside that range raise `ValueError` with the message
`timestamp out of range`.

## 15. Asynchronous execution

Async functions run cooperatively on one thread. A task runs until it suspends
or finishes; other tasks can make progress while it waits. Ready tasks run in
the order they became ready. Ordinary synchronous calls keep their behavior,
including blocking the entire event loop.

```python
import aio

async def square(value: int) -> int:
    return value * value

async def main():
    var first: aio.Task[int]
    var second: aio.Task[int]
    async with aio.task_group() as group:
        first = group.start(square(3))
        second = group.start(square(4))
    print(first.result() + second.result())    # 25
```

### Coroutines and task handles

Calling an async function evaluates and binds its arguments normally but runs
none of its body. The call produces a `Coroutine[T]`, where `T` is the
function's return annotation. Thus a function declared
`async def f(value: int) -> str` has callable type `(int) -> Coroutine[str]`.
Its body must return values assignable to `str`, following §9's return rules.

`Coroutine[T]` and `aio.Task[T]` are opaque nominal types. They are invariant in
`T`, and like a generic class, each has one runtime class for all of its
specializations (§4). They cannot be constructed directly.
They are not structural protocols; user-defined values cannot make themselves
awaitable.

A coroutine may be stored, passed, or returned. It may be consumed only once,
either by `await` or by a group's `start` method. Attempting either operation
on a coroutine that has already been consumed raises `RuntimeError` with the
message `coroutine was already awaited or started`. Aliases share that consumed
state. An unused coroutine never starts, and discarding it does not run its body
or cleanup. Expression statements follow §8's restriction on discarding
coroutines; storing one does not prove that it will eventually run.

An `aio.Task[T]` is a handle to a scheduled computation. It may be awaited
repeatedly and has one method:

| Method | Meaning |
| --- | --- |
| `result() -> T` | Return the completed task's value, or raise its final exception |

`result` does not wait. It raises `RuntimeError` with the message
`task is not finished` if the task is unfinished, or `task was cancelled` if
cancellation unwound its body. Handles may outlive the group and continue to
expose the task's outcome; the task's execution cannot outlive that group.

### `await`

`await expression` requires a `Coroutine[T]` or `aio.Task[T]` and produces `T`.
Its operand is evaluated once. Awaiting a coroutine consumes it and runs its
body as part of the current task, without starting a separate task. Awaiting
a task waits for that task's final outcome. Both forms return the resulting
value or raise the resulting exception. Awaiting a cancelled task raises
`RuntimeError` with the message `task was cancelled`. A group's join already
waits for every child, so cleanup in the group's body need not await them.

An await whose result is ready need not suspend. `await aio.sleep(0.0)` always
suspends, letting other ready tasks run first (§14).

`await` is allowed only inside an async function or method, including its
`finally` clauses. It is not allowed in a synchronous nested function, lambda,
or generator body. An async function cannot contain `yield` in its own body.
There are no async generators, async lambdas, or `async for` statements.

A sequence of direct coroutine awaits runs those computations sequentially.
Tasks already scheduled through groups continue independently of the order in
which their handles are awaited.

### Task groups

`async with expression as name:` is allowed only in an async function or method.
It evaluates the expression once and enters its `aio.TaskGroup`. The optional
`as name` declares that group in the body's lexical scope. The group name and
variables declared inside the body are not visible after the statement.

This is a built-in task-group scope. It accepts only `aio.TaskGroup`, which
does not satisfy `ContextManager`. General async context managers are not
supported.

| Method | Meaning |
| --- | --- |
| `start[T](coro: Coroutine[T]) -> Task[T]` | Consume `coro` and schedule a child task |
| `cancel() -> none` | Request a graceful stop of this group's body and children |

A group is inactive until it is entered, active from entry until its boundary
completes, including the join, and exited afterwards. An active group is
stopping once its own stop has been requested or it has recorded a failure.
Entering a group that is not inactive raises `RuntimeError` with the message
`task group was already entered`.

`start` neither suspends its caller nor executes the child inline. Every
scheduled task belongs to a group except the root task running async `main` or
an async test. A group may be passed to its children so they can start further
children in the same group. There is no operation to start a detached task or
cancel an individual task through its handle.

`start` succeeds only while its group is active and not stopping. Otherwise it
raises `RuntimeError` with the message `task group is not accepting tasks` and
does not consume its coroutine. Admission depends only on the group's own
state: a pending request from an outer group does not stop it, and a task
admitted then receives that request at its first checkpoint.

When the body completes normally, returns, breaks, or continues, the group
waits for all its children before continuing that departure. This wait is
called joining. During a normal join, running children may still start children
in the group.

A final exception from the body or a child stops admission, requests
cancellation of the remaining children, and interrupts a still-active body at
a checkpoint. The group joins its children, including their cleanup, before
propagating its failure. Catching an exception obtained from a task handle does
not clear its group's failure; a child must handle an expected error within its
own body to complete successfully.

`cancel` is idempotent while the group is active, including while it is
stopping or joining. Calling it on an inactive or exited group raises
`RuntimeError` with the message `task group is not active`. If the request
interrupts the active body, the rest of that body is skipped. At its boundary,
after joining, the group absorbs its own graceful stop and completes normally
unless it has recorded a failure or a request from an outer group is pending.
An inner group cannot absorb an outer group's request.

A stop requested during a join preserves any return, break, or continue already
pending. After absorbing its own stop, the boundary continues that departure.
Calling `cancel` is a request, not an immediate transfer: the caller can finish
normally before reaching another checkpoint.

### Cancellation and cleanup

Cancellation is control flow outside the `Exception` hierarchy. It bypasses
`except` handlers and unwinds through `finally` and `with` cleanup. A plain
context manager's `exit` receives `none`, as for other control transfers.
Suspension at an await does not exit active scopes.

Requests retain the identity of their originating group. A request is delivered
only at a checkpoint:

- an async library operation, before it acts and again each time it wakes;
- an await of a task, before the task's outcome is used, even when that outcome
  is already available;
- a group boundary.

A task suspended at a checkpoint is woken when a request reaches it. Awaiting a
coroutine is not itself a checkpoint: it always enters the coroutine's body,
and checkpoints inside the body deliver requests. Leaving a `finally` clause or
a resource exit is not a checkpoint.

A request stays in effect for every task inside the requesting group until that
group exits, and every unprotected checkpoint delivers it again. Raising and
catching an exception during cleanup therefore does not clear a request.

An admitted task enters its body even if cancellation was requested before its
first scheduled turn. Its initial synchronous setup runs before cancellation is
delivered at its first checkpoint. A task that finishes without reaching a
checkpoint may complete normally despite the request.

In async code, `finally` bodies and resource exits are protected from
cancellation originating in enclosing scopes. This includes a first request
arriving during cleanup entered by an ordinary return or exception. Cleanup
may await. A group entered inside that protected cleanup can still interrupt
its own body for its own failure or stop; outer cancellation does not cancel
that protected group's children. Groups outside that protection still receive
cancellation. Pending outer requests survive inner boundaries and are delivered
at the first checkpoint after protection is left.

A join of a group not protected from an outer request stops its children and
waits for their cleanup. A protected group's join waits for its children
normally. Interruption never abandons a join.

Cancellation cannot forcibly interrupt synchronous work. Cleanup that does not
finish can keep a group from exiting. There is no cleanup deadline or public
operation for shielding, suppressing, or clearing cancellation. `sys.exit` and
the fatal failures in §10 retain their immediate process-ending behavior.

### Competing failures

Within a task, ordinary `try` and `finally` rules apply: a cleanup exception
can replace that task's pending exception. The group observes a child's final
exception when the task completes, or the body's final exception when it
departs after its cleanup.

The first final exception observed by the group is its failure. Later failures
do not replace it and are neither aggregated nor automatically logged. This
includes later failures from another child's cleanup. Observation order depends
on scheduling and I/O; it is not promised to be the same across runs. A
`finally` outside the group may replace its propagated failure as usual.

When a group has recorded a failure and a request from an outer group is also
pending, the group joins all its children and then propagates its failure; the
failure takes precedence over delivering the request at that boundary. The
request stays in effect and is delivered at the next unprotected checkpoint. If
the exception reaches the requesting group's boundary, it is that body's final
exception, so the requesting group propagates a failure instead of absorbing
its stop. If the program catches the exception first, the requesting group
absorbs its stop at its boundary.

### Static checking across a group

A graceful stop can leave a group's body at a checkpoint. For static checking,
each `await` in the body, and each exit from a nested `async with`, is a
possible transfer to the end of every enclosing `async with` in the same
function that is not separated from it by a `finally` clause. Like `break`, the
transfer runs the intervening `finally` and `with` cleanup, and the state it
carries includes the effects of those `finally` clauses. Definite assignment,
narrowing, and control-transfer checking merge these transfers with the body's
ordinary completion. Every `await` counts, including one whose operand reaches
no checkpoint at run time.

Assignments to enclosing variables before the first such transfer remain
definite after the group. A value assigned only after an await in the body
cannot be assumed assigned after the group, and a return after that await does
not by itself satisfy the enclosing function's requirement to return on every
path. A return whose expression has finished and is already pending during the
join is preserved.
Interruption for a failure leaves by exception, rather than creating a normal
exit.

To use the results of concurrent work after the group, declare the handle
variables in the enclosing scope, start the tasks in the group, and assign their
handles to those variables, as in the example at the start of this section. The
handles are assigned before the first await, and a group whose stop was never
requested has no cancelled children. To run work sequentially, await its
coroutine directly without a group.

Captured-variable narrowing is removed at every await and implicit join (§9).

### Async I/O boundaries

Async I/O uses explicit async APIs and handle types (`aio` in §14). Calling a
synchronous library operation from an async function never makes that operation
suspend cooperatively. Plain `with` remains suitable for handles whose closing
is synchronous.

A caller must scope or hand off an acquired resource before its next await.
For example, after accepting a connection it may immediately pass it to
`group.start(serve(connection))`, where `serve` enters `with connection:`
before its first await. The admitted-task startup rule lets that cleanup scope
be established even under a pending cancellation request. Starting a task does
not automatically manage resources passed as its arguments.

Async library operations either deliver an acquired resource to the caller or
release it on interruption. Cancellation removes pending I/O waits. A cancelled
send that may have sent partial data makes the connection unusable, as a failed
`sendall` does in §14.

## References

- Python documentation:
  [sequence operations](https://docs.python.org/3/library/stdtypes.html),
  [calls](https://docs.python.org/3/reference/expressions.html#calls),
  [format specifications](https://docs.python.org/3/library/string.html#format-specification-mini-language),
  [subprocesses](https://docs.python.org/3/library/subprocess.html),
  [sockets](https://docs.python.org/3/library/socket.html)
  (library behavior); [callables](https://typing.python.org/en/latest/spec/callables.html)
  and [protocols](https://typing.python.org/en/latest/spec/protocol.html)
  (type-system precedents)
- [Unicode 17.0](https://www.unicode.org/versions/Unicode17.0.0/), for case
  mappings
