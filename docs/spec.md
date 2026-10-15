# Willow Language Specification

Willow is a small, statically typed language with Python-like syntax that compiles
to Lua and runs on LuaJIT. Source files use the `.wlo` extension. Willow does not
aim for Python source compatibility or access to Lua libraries.

## 1. Programs

```python
def sum_to(limit: int) -> int:
    total = 0
    current = 1
    while current <= limit:
        total = total + current
        current = current + 1
    return total

def greeting(name: str) -> str:
    return "Hello, " + name

def main() -> None:
    print(greeting("Willow"))
    print(sum_to(10))
```

This program prints:

```text
Hello, Willow
55
```

A program is an entry file and the modules it imports (§12). A file contains
`import` statements followed by `def`, `class`, and `type` declarations in any
order.
Nothing else appears at file scope.

The entry file defines exactly one `main`, with the signature
`def main() -> None:`. In other modules, `main` is an ordinary function name. The
program's arguments come from `sys.args()` (§14).

The whole program is checked before any of it runs; an error in any module
prevents execution. The program then calls `main` once. A call to `main` from user
code is an ordinary call. Programs have no access to Lua globals or `require`.

The exit status is 0 when `main` returns, 1 when an exception leaves `main` or the
program otherwise fails, and the given status when the program calls `sys.exit`
(§14).

## 2. Lexical structure

Source text is UTF-8. Lines end with LF or CRLF; a bare CR anywhere, including in
comments and strings, is an error. A missing final newline is allowed.

A comment runs from `#` to the end of the line.

### Indentation

A block is a colon followed by an indented suite. Each indentation level is four
spaces. Tabs are errors anywhere outside string literals and comments, including on
blank lines. Blank lines and comment-only lines do not affect indentation and need
not align.

A statement ends at a newline. Newlines inside parentheses, brackets, and braces do
not end statements and do not affect indentation. There is no backslash
continuation, semicolon separator, or one-line block.

### Identifiers and reserved words

Identifiers are case-sensitive ASCII letters, digits, and underscores, and do not
begin with a digit. These words are reserved:

```text
False None True and as assert async await break case class continue def del
elif else except finally for from global if import in is lambda match nonlocal
not or pass raise return try type while with yield
```

The type names `int`, `float`, `bool`, `str`, `list`, and `dict` are also
reserved. A reserved word that begins no construct described here is an error
where that construct would appear.

### Numeric literals

Integer literals are decimal digits without leading zeros, except `0` itself. A
leading minus is the unary operator. A literal outside the `int` range (§4) is an
error. There are no hexadecimal, binary, or underscore-separated literals.

A float literal has a fractional part, an exponent, or both: `1.0`, `0.25`, `1e9`,
`2.5e-3`. Digits are required on both sides of a decimal point, and the integer
part follows the leading-zero rule. A literal that rounds to infinity is an error.

### String literals

Strings are single- or double-quoted and cannot contain an unescaped newline.
Triple-quoted strings (`"""..."""` and `'''...'''`) may span lines; each line break
becomes `\n` and indentation is kept. There are no raw strings.

The escapes are `\\`, `\'`, `\"`, `\n`, `\r`, `\t`, and `\xhh`, `\uhhhh`, and
`\Uhhhhhhhh`, which denote the code point with that hexadecimal value. Unknown
escapes, surrogates (U+D800 through U+DFFF), and values above U+10FFFF are errors.

An f-string (`f"..."`, `f'...'`, or a triple-quoted form) interpolates expressions
in braces:

```python
f"{name} has {len(name)} letters"
```

Each field holds one expression of a printable type (§4) and contributes the text
`str(...)` would produce. Fields are evaluated left to right. `{{` and `}}` denote
literal braces. A field cannot be empty or contain a backslash, a `#`, or the
f-string's own quote character, and a lone `}` is an error. There are no format
specifications or conversions.

## 3. Declarations

### Functions

```python
def function_name(parameter: Type, other: Type) -> Type:
    statements
```

Parameter and return annotations are required. There are no default, named, or
variadic parameters, nested functions, or lambdas. Trailing commas are allowed in
parameter and argument lists. Functions may call functions declared later, and may
recurse directly or mutually.

### Records

A `class` declaration defines a record type. Its body holds one or more field
declarations and nothing else:

```python
class Node:
    value: int
    next: Node | None
```

Field names are unique within a record. Field types may name any record, including
the record itself and records declared later. Records are nominal: two records with
the same fields are different types.

Calling a record by name constructs a value. The constructor takes one positional
argument per field, in declaration order, with exact arity; each argument must be
assignable to its field's type. `p.x` reads a field and `p.x = v` replaces it, where
`v` must be assignable to the field's type. Naming an unknown field is an error.

Exception classes (§10) are records declared with the base `Exception`.

### Type aliases

```python
type Json = None | bool | int | float | str | list[Json] | dict[str, Json]
```

A `type` declaration gives a type a name. The alias and the type it names are the
same type, and an annotation may use either. Aliases may name records and aliases
declared later, including themselves, but an alias cannot expand to itself except
inside `list[...]` or `dict[...]`, so `type Loop = int | Loop` is an error. An alias
cannot be called or named in `isinstance`.

### Annotations

```text
int  float  bool  str  None
list[T]  dict[K, V]
Record  module.Record
Alias  module.Alias
A | B | ...
```

## 4. Types and values

| Type | Values |
| --- | --- |
| `int` | Integers from `-(2^53 - 1)` through `2^53 - 1` |
| `float` | IEEE 754 binary64 numbers |
| `bool` | `True` and `False` |
| `str` | Immutable UTF-8 text |
| `None` | The single value `None` |
| `A \| B \| ...` | A value of any member type |
| `list[T]` | Ordered, mutable sequences of `T` |
| `dict[K, V]` | Mutable, insertion-ordered maps from `K` to `V` |
| Records | Values of a declared record or exception class |

The scalar types are `int`, `float`, `bool`, `str`, and `None`. A type is
printable if it is a scalar type or a union of them. Lists, dictionaries, and
records have reference semantics: assignment and argument passing share a value
rather than copy it.

### Assignability

There are no implicit conversions; in particular `bool` is not a number and `int`
is not a `float`. A value is assignable to its own type, and also:

- A value is assignable to a union if it is assignable to one of its members, and
  a union is assignable to a type if each of its members is.
- A value of any exception class is assignable to `Exception`.

Assignability applies to initializers, assignments, arguments, returns, display
elements, and constructor arguments. Collection types are invariant: `list[int]` is
not assignable to `list[int | None]`, and `list[ParseError]` is not assignable to
`list[Exception]`.

### Unions

A union's members may appear in any order, and unions with the same members are the
same type. A member that is itself a union, such as an alias of one, contributes
its members. No member may be assignable to another, and a union has at most one
`list` member and at most one `dict` member, so `int | int`,
`Exception | ParseError`, and `list[int] | list[str]` are errors. A union with a
`None` member, such as `str | None`, is called optional.

A union value can be assigned, passed, returned, compared, printed, and tested with
`is None`, `is not None`, and `isinstance`. Arithmetic, conditions, indexing, field
access, and method calls require narrowing it to one member first (§9).

`isinstance(value, C)` is `True` when `value` holds a value of `C`. `C` is `int`,
`float`, `bool`, `str`, `list`, `dict`, or a record or exception class name,
possibly module-qualified, and must name `value`'s type or one of its members;
`list` and `dict` name the list or dict member.

```python
def describe(value: int | str | None) -> str:
    if value is None:
        return "nothing"
    if isinstance(value, int):
        return f"number {value + 1}"
    return "text " + value
```

### `None`

`None` is the return value of functions annotated `-> None`. A bare `return` is
`return None`, and such a function may fall off its end.

## 5. Expressions

The expression forms are literals, names, parenthesized expressions, list and dict
displays, calls, indexing, field access, and unary and binary operations.

Precedence, from lowest to highest:

1. `or`
2. `and`
3. `not`
4. `==`, `!=`, `<`, `<=`, `>`, `>=`, `is`, `is not`, `in`, `not in`
5. Binary `+`, `-`
6. `*`, `/`, `//`, `%`
7. Unary `+`, `-`
8. Postfix: calls, indexing `a[i]`, and field or method access `a.name`
9. Literals, names, parenthesized expressions, and displays

Binary operators associate left to right, and postfix operations chain left to
right, as in `text.strip().split(",")`. Operands of a level 4 operator come from
level 5 or higher, so `not a == b` is `not (a == b)` and `a == not b` is a syntax
error. Comparison chains such as `0 <= x < 10` are errors.

### Calls

A call names a function, built-in, conversion, or record by bare name (`area(p)`),
a module member (`geometry.area(p)`), or a method on a value (`items.append(x)`).
Arguments are positional with exact arity. Functions and methods are not values,
so `(f)(x)`, `items[0](x)`, and an uncalled `items.append` are errors. A call has
exactly one value.

### Operators

- `and`, `or`, and `not` take and produce `bool`; `and` and `or` short-circuit.
- `==` and `!=` take two operands of printable types where one's type is
  assignable to the other's, so `count == 3` and `count == None` are valid for
  `count: int | None`. Values of different types are unequal, so a union holding
  `1` does not equal one holding `1.0`. Lists, dictionaries, and records do not
  support `==`.
- `<`, `<=`, `>`, and `>=` take two integers, two floats, or two strings.
- `is` appears only as `e is None` or `e is not None`, where `e` has an optional
  type.
- `in` and `not in` test list elements, dictionary keys, and substrings (§7).
- `+` adds numbers of the same type or concatenates strings. `-`, `*`, unary `+`,
  and unary `-` take numbers.
- `/`, `//`, and `%` are described in §6.

There is no exponentiation or bitwise operator.

### Evaluation order

Operands, arguments, and display elements are evaluated left to right, each once,
and an operand that raises stops evaluation of the rest. Dict displays evaluate each
key, then its value, entry by entry. Index and field assignments evaluate the
right-hand side, then the object, then the index.

## 6. Numbers

### Integers

`+`, `-`, `*`, and unary operators on integers are exact. A result outside the
`int` range raises `OverflowError` with the message `integer overflow`. Integers
have no negative zero.

### Floats

Float arithmetic follows IEEE 754 with round-to-nearest. Results may be infinite
or NaN. `-0.0` is distinct from `0.0` but equal to it. NaN is unequal to every
value, including itself, and every ordering comparison with NaN is `False`.

### Division

Division operators take two operands of the same numeric type:

| Operator | `int` operands | `float` operands |
| --- | --- | --- |
| `/` | `float` quotient | `float` quotient |
| `//` | `int`, floor of the quotient | `float`, floor of the quotient |
| `%` | `int` remainder | `float` remainder |

The remainder has the sign of the divisor, and `(a // b) * b + a % b == a` for
integers. A zero divisor, including `-0.0`, raises `ZeroDivisionError` with the
message `division by zero`. Results match Python: `7 // -2` is `-4`, `7 % -2` is
`-1`, `-7.5 // 2.0` is `-4.0`, and `1 / 3` is `0.3333333333333333`.

### Conversions

- `float(n: int) -> float` is exact.
- `int(x: float) -> int` truncates toward zero. NaN, infinity, and results outside
  the `int` range raise `ValueError` with the message
  `cannot convert float to int`.
- `int(s: str) -> int` reads an optional `+` or `-` followed by one or more decimal
  digits; leading zeros are allowed. Other text and results outside the `int` range
  raise `ValueError` with the message `cannot convert str to int`.
- `float(s: str) -> float` reads an optional `+` or `-` followed by decimal digits
  with an optional fraction and exponent, as in `7`, `2.5`, `.5`, `5.`, and `1e-3`,
  or by `inf`, `infinity`, or `nan` in any letter case. The result is the nearest
  float, and magnitudes beyond the float range are infinite. Other text raises
  `ValueError` with the message `cannot convert str to float`.

Unlike Python's, the string conversions accept neither whitespace nor underscores.

## 7. Strings and collections

### Strings

Strings compare by exact contents, without Unicode normalization. Length, ordering,
and iteration use code points, as do the indexes `find` returns.

| Expression | Type | Meaning |
| --- | --- | --- |
| `a + b` | `str` | Concatenation |
| `len(s)` | `int` | Number of code points |
| `a < b`, `<=`, `>`, `>=` | `bool` | Lexicographic order by code point |
| `sub in s` | `bool` | `sub` occurs in `s` |
| `s.startswith(prefix)` | `bool` | `s` begins with `prefix` |
| `s.endswith(suffix)` | `bool` | `s` ends with `suffix` |
| `s.find(sub)` | `int` | Index of the first occurrence of `sub`, or `-1` |
| `s.replace(old, new)` | `str` | Every non-overlapping `old`, left to right, replaced by `new` |
| `s.strip()` | `str` | `s` without leading and trailing ASCII whitespace |
| `s.split(sep)` | `list[str]` | Pieces of `s` between occurrences of `sep` |
| `sep.join(items)` | `str` | The `list[str]` items joined with `sep` |
| `str(value)` | `str` | The text `print` writes for a printable value, without the newline |
| `ord(c)` | `int` | The code point of the one-code-point string `c` |
| `chr(n)` | `str` | The one-code-point string for code point `n` |

Results match Python's, except that `strip` removes only space, tab, LF, VT, FF,
and CR. `split` with an empty separator raises `ValueError` with the message
`empty separator`. `ord` of any other length raises `ValueError` with the message
`expected one character`. `chr` of a surrogate or a value outside 0 through
0x10FFFF raises `ValueError` with the message `invalid code point`. Strings have no
indexing or slicing.

### Text of printable values

- Strings are their contents, without quotation marks.
- Integers are decimal.
- Floats are Python's `repr`: the shortest decimal text that reads back as the
  same value; scientific notation when the decimal exponent is below -4 or at
  least 16, otherwise fixed notation with at least one fractional digit; and
  `inf`, `-inf`, or `nan` for non-finite values.
- Booleans are `True` and `False`, and `None` is `None`.

### Displays

```python
numbers = [1, 2, 3]                     # list[int]
ages = {"ada": 36, "alan": 41}          # dict[str, int]
names: list[str] = []
scores: dict[str, int | None] = {"ada": None}
```

A display with an expected type, from an annotation, an existing target, a
parameter, a return type, a field, or an enclosing display, checks each element
against that type, and an empty display takes that type. When the expected type is
a union, a list display expects its list member and a dict display its dict member.
Without an expected type,
a non-empty display takes the types of its first element or entry, later ones must
be assignable to them, and an empty display is an error. In a dict display, a
repeated key keeps its first position and its last value. Displays allow trailing
commas.

### Lists and dictionaries

Dictionary keys are `int` or `str`. Element and value types can be any type.
Collections store `None`; a stored `None` counts toward length and is distinct from
a missing key.

| Expression | Type | Meaning |
| --- | --- | --- |
| `len(xs)` | `int` | Number of elements |
| `xs[i]` | `T` | Element at index `i` |
| `xs[i] = v` | | Replace the element at index `i` |
| `xs.append(v)` | `None` | Add `v` at the end |
| `xs.pop()` | `T` | Remove and return the last element |
| `v in xs` | `bool` | Some element equals `v` |
| `len(d)` | `int` | Number of entries |
| `d[k]` | `V` | Value for key `k` |
| `d[k] = v` | | Insert or replace the entry for `k` |
| `d.get(k)` | `V \| None` | Value for `k`, or `None` when missing |
| `d.pop(k)` | `V` | Remove the entry for `k` and return its value |
| `k in d` | `bool` | `k` is a key |

List indexes are zero-based, with `0 <= i < len(xs)`; any other index, including a
negative one, raises `IndexError` with the message `list index out of range`.
Lists have no slicing. `pop()` on an empty list raises `IndexError` with the
message `pop from empty list`. `d[k]` and `d.pop(k)` raise `KeyError` with the
message `key not found` for a missing key. When `V` is already optional, `d.get(k)`
has type `V`. `v in xs` requires an element type that supports `==`.

Replacing a dictionary value keeps the entry's position; a key removed and inserted
again moves to the end.

## 8. Statements

```python
name = expression
name: Type = expression
items[index] = expression
point.x = expression
function_call()
return expression
return
pass
break
continue
raise expression
raise

if condition:
    statements
elif condition:
    statements
else:
    statements

while condition:
    statements

for name in iterable:
    statements

try:
    statements
except ParseError as error:
    statements
finally:
    statements
```

A block contains at least one statement; `pass` is an empty body. Only calls may
be expression statements. An assignment has one target and one value; there is no
chained, destructuring, or augmented assignment, and no assignment expression.

Conditions have type `bool`. Other values have no truthiness, so `if count:` is a
type error.

`break` and `continue` apply to the nearest enclosing `while` or `for` and are
errors outside one. Loops have no `else` clause.

### `for`

`for name in iterable:` runs its body once per item of a list (elements in index
order), a dictionary (keys in insertion order), a string (each code point as a
one-code-point string), or a `range` call.

- `range(stop)`, `range(start, stop)`, and `range(start, stop, step)` take
  integers and produce the same sequence as in Python. A zero step raises
  `ValueError` with the message `range step must not be zero`. `range` appears
  only as a `for` iterable.
- The iterable and the `range` arguments are evaluated once, before the first
  iteration.
- Assigning the loop name in the body does not affect iteration. After the loop,
  the name keeps its last value.
- List iteration continues while the index is below the list's current length, so
  appended elements are visited.
- Adding or removing keys of a dictionary during iteration over it raises
  `RuntimeError` with the message `dictionary changed size during iteration` at
  the next step. Replacing values is allowed.

## 9. Names and static checking

### Scope

Each function has one local scope. Parameters, assignment targets, `for` loop
names, and `except ... as` names anywhere in a function are locals throughout the
whole function. There are no block scopes, module variables, or globals.

File scope holds functions, records, aliases, and imports, and these share one
namespace with the built-in names (§11). Duplicate declarations, duplicate
parameters, and file-level declarations that use a built-in name are errors. A
local shadows a function, record, alias, import, or built-in of the same name
throughout its function.
Calling a local is an error, even before its first assignment; annotations still
name the shadowed record or alias.

### Local types

A local's lexically first assignment fixes its type: from the annotation if present,
otherwise from the value. Every later assignment must be assignable to that type.
An annotation requires a value and may appear only on a local's lexically first
assignment, never on a parameter.

```python
count: int = 3
count = count + 1     # valid
count = "four"        # type error
best: str | None = None
```

A `for` loop or `except ... as` clause assigns its name; the item or handled
exception type must be assignable to the local's type, and fixes it when the clause
is the lexically first assignment.

### Definite assignment

A local may be read only where it is assigned on every path that reaches the read.
Facts flow structurally:

- After an `if`, a local is assigned if every branch that falls through assigns
  it. An `if` without `else` has an implicit empty branch that falls through.
- A `while` or `for` body may run zero times, so its assignments do not carry past
  the loop.
- An `except ... as` name is assigned inside its clause.

The checker does not evaluate conditions: both sides of every branch are checked,
and `if False:` and `while True:` are treated like any other condition.

### Control transfer

`return`, `break`, `continue`, `raise`, and a statement that calls the standard
library's `sys.exit` (§14) transfer control. An `if` whose branches all transfer,
including an `else`, transfers. A statement after a transfer in the same block is
an unreachable-code error.

A function not annotated `-> None` must return a value on every path. A loop never
establishes that a function returns, so a trailing `return` is required even after
`while True:`.

### Narrowing

A local or parameter of a union type narrows to some of its members where a check
proves its value belongs to them; with one member left, it has that member's type.
Each condition yields facts that hold when it is true and facts that hold when it
is false:

- `name is not None` narrows `name` to its other members when true; `name is None`
  does so when false.
- `isinstance(name, C)` narrows `name` to `C`'s member when true and to its other
  members when false.
- `not C` swaps the facts of `C`.
- `A and B` has the true facts of both operands when true. `B` is checked with the
  true facts of `A`.
- `A or B` has the false facts of both operands when false. `B` is checked with the
  false facts of `A`.
- Other conditions yield no facts.

Field and index expressions do not narrow; copy them into a local first. Facts
flow through statements:

- An `if` or `elif` branch starts with the true facts of its condition and the
  false facts of the conditions before it. An `else` branch, or the implicit empty
  branch, starts with the false facts of every condition.
- After an `if`, a local has the members it has at the end of any branch that
  falls through.
- A `while` body starts with the true facts of its condition.
- Assigning a value whose type is one member other than `None` narrows a local to
  that member; assigning anything else ends its narrowing.
- At the start of a loop body and after the loop, narrowing from before the loop
  holds only for locals the body does not assign.

```python
def describe(name: str | None) -> str:
    if name is None:
        return "anonymous"
    return "user " + name
```

### `try`

- A `try` body may stop at any statement. An `except` clause therefore starts with
  the definite assignments from before the `try`, and with the narrowing from
  before the `try` only for locals the body does not assign. A `finally` clause
  starts the same way, also excluding locals the `except` clauses assign.
- After the `try`, the body and the `except` clauses join like the branches of an
  `if` with an `else`, counting those that fall through. The `finally` clause then
  applies as ordinary statements.
- A `try` transfers control when its body and every `except` clause transfer, or
  when its `finally` clause transfers.

## 10. Exceptions

```python
class ParseError(Exception):
    line: int

def parse_digit(text: str, line: int) -> int:
    index = "0123456789".find(text)
    if len(text) != 1 or index < 0:
        raise ParseError(f"not a digit: {text}", line)
    return index

def main() -> None:
    try:
        print(parse_digit("7", 1))                      # 7
        print(parse_digit("x", 2))
    except ParseError as error:
        print(f"line {error.line}: {error.message}")    # line 2: not a digit: x
    finally:
        print("done")                                   # done
```

### Exception classes

`Exception` is a built-in class with one field, `message: str`. A class that names
`Exception` as its base is an exception class. Its fields are `message` followed by
the declared fields, and its constructor takes them in that order. Its body may be
`pass` instead of fields, and no declared field may be named `message`. The base
must be `Exception`. Otherwise exception classes follow the record rules.

These built-in exception classes have only the `message` field:

| Class | Raised for |
| --- | --- |
| `OverflowError` | Integer overflow |
| `ZeroDivisionError` | Division by zero |
| `ValueError` | Invalid values for conversions, `ord`, `chr`, `range`, `split`, `sys.exit`, and UTF-8 input |
| `IndexError` | List indexes and `pop` from an empty list |
| `KeyError` | Missing dictionary keys |
| `RuntimeError` | Dictionary size changes during iteration |
| `OSError` | File read and write failures |

Programs may construct and raise them like their own classes.

### `raise`

`raise expression` raises a value of an exception type. It records its source
location and the active Willow call frames; a runtime failure records the failing
operation's location instead.

A bare `raise` appears only inside an `except` clause and raises the exception that
clause handles again, with its original location and frames. `raise ... from ...`
is an error.

### `try`

A `try` has one or more `except` clauses, a `finally` clause, or both. Each `except`
names one exception class, possibly module-qualified, and may bind the exception
with `as name`. A bare `except:`, a parenthesized list of classes, `except*`, and an
`else` clause are errors.

If the body raises, the `except` clauses are tested in order, and the first that
names the exception's class or `Exception` handles it. If none does, the exception
propagates. A clause after `except Exception`, or one naming the same class as an
earlier clause, is an error.

`finally` runs however the `try` is left: by falling through, by `return`, `break`,
or `continue`, or by an exception from the body or an `except` clause. The departure
then resumes; a `return` value is evaluated before `finally` runs. An exception
raised in `finally` replaces the one in flight. `return`, `break`, and `continue`
directly inside `finally` are errors.

### Failures that are not exceptions

Stack exhaustion, memory exhaustion, failure to write stdout or stderr, and failure
to read stdin terminate the program with status 1. They cannot be caught.

## 11. Built-in functions

| Function | Meaning |
| --- | --- |
| `print(value) -> None` | Write a printable value and `\n` to stdout |
| `input() -> str \| None` | The next line of stdin without its line ending, or `None` at end of input |
| `len`, `range`, `int`, `float`, `str`, `ord`, `chr`, `isinstance` | See §4, §6, §7, and §8 |

The built-in names are these functions and the built-in exception classes.

A line of input ends at `\n`; `input` removes the `\n` and a `\r` just before it,
and returns a final line that has no line ending. Text read by `input` must be
valid UTF-8, or the call raises `ValueError` with the message `invalid UTF-8`.

## 12. Modules

```python
# geometry.wlo
class Point:
    x: float
    y: float

def distance_squared(a: Point, b: Point) -> float:
    dx = a.x - b.x
    dy = a.y - b.y
    return dx * dx + dy * dy
```

```python
# main.wlo
import geometry

def main() -> None:
    origin = geometry.Point(0.0, 0.0)
    corner = geometry.Point(3.0, 4.0)
    print(geometry.distance_squared(origin, corner))    # 25.0
```

- `import name` loads `name.wlo` from the entry file's directory, or from the
  standard library (§14) when that directory has no `name.wlo`, so a program's own
  module shadows a standard one. Each import names one module. A missing module is
  an error at the import.
- An import binds the module name in the importing file's namespace (§9).
- `module.name` refers to a function, record, or alias declared in that module, in
  calls, constructors, annotations, `except` clauses, and `isinstance`. Modules
  are not values. Names that begin with `_` are private to their module.
- Imports may form cycles. Modules contain only declarations, so they have no
  initialization order. Each module loads once.

## 13. Diagnostics

Compile-time errors have this form:

```text
hello.wlo:8:5: error: expected int, received str
```

Lines and columns are one-based, and columns count code points.

An exception that leaves `main` reports its class and message at its recorded
location, followed by its recorded frames:

```text
main.wlo:7:9: error: ParseError: not a digit: x
  in parse_digit at main.wlo:7:9
  called from main at main.wlo:13:15
```

Each location names the file it belongs to. Diagnostics go to stderr.

## 14. Standard library

The standard library is a set of modules that ship with Willow and are imported
like a program's own (§12).

### `fs`

| Function | Meaning |
| --- | --- |
| `read_file(path: str) -> str` | The contents of the file |
| `write_file(path: str, text: str) -> None` | Create the file, or replace its contents, with `text` |

Both transfer text exactly, without line-ending translation, and `write_file` does
not replace the file atomically. Relative paths resolve against the current
working directory.

Text read by `read_file` must be valid UTF-8, or the call raises `ValueError` with
the message `invalid UTF-8`. When either function cannot open, read, or write a
file, it raises `OSError` with the message `cannot read <path>: <reason>` or
`cannot write <path>: <reason>`, where the host supplies the reason.

### `json`

```python
import json

def main() -> None:
    doc = json.parse('{"name": "Willow", "ports": [80, 443]}')
    if isinstance(doc, dict):
        ports = doc["ports"]
        if isinstance(ports, list):
            print(len(ports))       # 2
    reply: json.Json = {"ok": True, "items": [1, 2.5, None]}
    print(json.dump(reply))         # {"ok":true,"items":[1,2.5,null]}
```

| Declaration | Meaning |
| --- | --- |
| `type Json = None \| bool \| int \| float \| str \| list[Json] \| dict[str, Json]` | A JSON value |
| `class JsonError(Exception)` | Invalid JSON text, or a value `dump` cannot encode |
| `parse(text: str) -> Json` | The value of the JSON text `text` |
| `dump(value: Json) -> str` | The JSON text of `value` |

`parse` accepts JSON as RFC 8259 defines it. A number without a fraction or
exponent and within the `int` range is an `int`; any other number is the nearest
`float`. An object's repeated key keeps its first position and its last value.
Text that is not JSON, including an escape of an unpaired surrogate, raises
`JsonError` with a message that describes the problem and gives its line and
column.

`dump` writes no whitespace and keeps dictionary order. Floats are written as
`str` writes them, so `2.0` reads back as a `float`. Strings escape `"`, `\`, and
control characters, using `\b`, `\f`, `\n`, `\r`, and `\t` where they exist and
`\u00XX` otherwise; other characters are written as they are. NaN and infinities
raise `JsonError` with the message `cannot encode <value>`, as in
`cannot encode inf`.

### `sys`

```python
import fs
import sys

def main() -> None:
    args = sys.args()
    if len(args) != 1:
        sys.eprint("usage: chars <file>")
        sys.exit(2)
    try:
        text = fs.read_file(args[0])
    except OSError as error:
        sys.eprint(error.message)
        sys.exit(1)
    print(len(text))
```

| Function | Meaning |
| --- | --- |
| `args() -> list[str]` | A new list of the program's arguments in order, without the program or source name |
| `eprint(value) -> None` | Write a printable value and `\n` to stderr |
| `exit(status: int) -> None` | End the program with exit status `status` |

`args` raises `ValueError` with the message `invalid UTF-8` when an argument is not
valid UTF-8.

`exit` takes a status from 0 through 255 and otherwise raises `ValueError` with the
message `exit status out of range`. It ends the program at once; pending `finally`
clauses do not run.
