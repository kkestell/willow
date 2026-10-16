# Willow Language Specification

Willow is a small, statically typed language with Python-like syntax that compiles
to Lua and runs on LuaJIT. Source files use the `.wlo` extension. Willow does not
aim for Python source compatibility or access to Lua libraries.

Sections 1–19 describe the implemented language. Sections 20–24 describe planned
milestones, introduced under
[planned application development milestones](#planned-application-development-milestones).

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

Test files (§12) are entry files without `main`; `willow test` runs their test
functions.

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

The type names `int`, `float`, `bool`, `str`, `bytes`, `list`, and `dict` are also
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
`str(...)` would produce, shaped by an optional format specification (§7). Fields
are evaluated left to right. `{{` and `}}` denote literal braces. A field cannot be
empty or contain a backslash, a `#`, or the f-string's own quote character, and a
lone `}` is an error. There are no `!` conversions.

## 3. Declarations

### Functions

```python
def function_name(parameter: Type, other: Type) -> Type:
    statements
```

Parameter and return annotations are required. A parameter may have a default
after its annotation, as in `prefix: str = "Hello"`. A default is `None`, `True`,
`False`, a string literal, or an integer or float literal optionally preceded by
`+` or `-`, and must be assignable to the parameter's type. A parameter without a
default cannot follow one with a default. There are no variadic parameters,
nested functions, or lambdas. Trailing commas are allowed in parameter and
argument lists. Functions may call functions declared later, and may recurse
directly or mutually.

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

Calling a record by name constructs a value. The constructor takes one argument per
field, bound like a function's arguments (§5) with the field names as parameter
names; each argument must be assignable to its field's type. A field may have a
default under the rules for parameter defaults, which an omitted argument takes:

```python
class Options:
    output: str = "-"
    verbose: bool = False

options = Options(verbose=True)
```

`p.x` reads a field and `p.x = v` replaces it, where `v` must be assignable to the
field's type. Naming an unknown field is an error.

Exception classes (§10) are records declared with the base `Exception`. Their
`message` field comes first and has no default.

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
| `bytes` | Immutable sequences of octets |
| `None` | The single value `None` |
| `A \| B \| ...` | A value of any member type |
| `list[T]` | Ordered, mutable sequences of `T` |
| `dict[K, V]` | Mutable, insertion-ordered maps from `K` to `V` |
| Records | Values of a declared record or exception class |
| Native types | Library values such as `io.File` (§14) |

The scalar types are `int`, `float`, `bool`, `str`, `bytes`, and `None`. A type is
printable if it is a scalar type other than `bytes` or a union of them. Lists, dictionaries, and
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
displays, calls, indexing, slicing, field access, and unary and binary operations.

Precedence, from lowest to highest:

1. `or`
2. `and`
3. `not`
4. `==`, `!=`, `<`, `<=`, `>`, `>=`, `is`, `is not`, `in`, `not in`
5. Binary `+`, `-`
6. `*`, `/`, `//`, `%`
7. Unary `+`, `-`
8. Postfix: calls, indexing `a[i]`, slicing `a[i:j]`, and field or method access
   `a.name`
9. Literals, names, parenthesized expressions, and displays

Binary operators associate left to right, and postfix operations chain left to
right, as in `text.strip().split(",")`. Operands of a level 4 operator come from
level 5 or higher, so `not a == b` is `not (a == b)` and `a == not b` is a syntax
error. Comparison chains such as `0 <= x < 10` are errors.

### Calls

A call names a function, built-in, conversion, or record by bare name (`area(p)`),
a module member (`geometry.area(p)`), or a method on a value (`items.append(x)`).
Functions and methods are not values, so `(f)(x)`, `items[0](x)`, and an uncalled
`items.append` are errors. A call has exactly one value.

Arguments are positional arguments followed by keyword arguments,
`name=expression`. Positional arguments fill parameters in declaration order and
keyword arguments name the rest; omitted parameters take their defaults (§3).

```python
def greet(name: str, prefix: str = "Hello") -> str:
    return prefix + ", " + name

print(greet(prefix="Welcome", name="Ada"))
```

A positional argument after a keyword, an unknown name, a second value for one
parameter, a missing argument for a parameter without a default, and too many
arguments are compile-time errors. Functions, constructors, `fs.read_file`,
`fs.write_file`, `sys.exit`, `sorted`, and `list.sort` accept keywords with the
parameter names §7 and §14 give. Other built-ins and methods take only
positional arguments.

### Operators

- `and`, `or`, and `not` take and produce `bool`; `and` and `or` short-circuit.
- `==` and `!=` take two operands of scalar types or unions of them where one's
  type is assignable to the other's, so `count == 3` and `count == None` are valid
  for `count: int | None`. Values of different types are unequal, so a union
  holding `1` does not equal one holding `1.0`. Bytes compare by content. Lists,
  dictionaries, records, and native values do not support `==`.
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
right-hand side, then the object, then the index. A slice evaluates the object,
then the start, then the stop. Call arguments are evaluated in the order they are
written, even when keywords name parameters out of order.

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
indexing, slicing, and iteration use code points, as do the indexes `find` returns.

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
| `s.find(sub)` | `int` | Index of the first occurrence of `sub`, or `-1` |
| `s.replace(old, new)` | `str` | Every non-overlapping `old`, left to right, replaced by `new` |
| `s.strip()` | `str` | `s` without leading and trailing ASCII whitespace |
| `s.split(sep)` | `list[str]` | Pieces of `s` between occurrences of `sep` |
| `s.lower()` | `str` | Unicode lowercase text |
| `s.upper()` | `str` | Unicode uppercase text |
| `s.ljust(width)` | `str` | `s` padded on the right with spaces to at least `width` code points |
| `s.rjust(width)` | `str` | `s` padded on the left with spaces to at least `width` code points |
| `sep.join(items)` | `str` | The `list[str]` items joined with `sep` |
| `str(value)` | `str` | The text `print` writes for a printable value, without the newline |
| `ord(c)` | `int` | The code point of the one-code-point string `c` |
| `chr(n)` | `str` | The one-code-point string for code point `n` |

Results match Python's, except that `strip` removes only space, tab, LF, VT, FF,
and CR. `split` with an empty separator raises `ValueError` with the message
`empty separator`. `ord` of any other length raises `ValueError` with the message
`expected one character`. `chr` of a surrogate or a value outside 0 through
0x10FFFF raises `ValueError` with the message `invalid code point`. An invalid
string index raises `IndexError` with the message `string index out of range`.
Strings cannot be assigned through an index.

Case conversion uses the Unicode 17.0 default full case mappings, including the
Final_Sigma rule for `Σ`, without locale tailoring or normalization, so a result
may differ in length from its argument. Widths measure code points, not terminal
display cells, and a width at most the text's length leaves it unchanged.

String iteration is the idiom for sequential scans; indexing and slicing take time
proportional to the string's length.

### Indexes and slices

Indexes and slice bounds of strings and lists are integers. A negative index
counts from the end: the sequence length is added once, and the result must then
lie within the sequence. A slice `a[start:stop]` includes `start` and excludes
`stop`. An omitted start means zero and an omitted stop means the length; negative
bounds count from the end, and bounds are clamped to the sequence. A stop at or
before the start gives an empty result. A list slice is a new list of the same
type sharing the original's elements. Slices have no step and cannot be assigned
to.

```python
text = "café"
print(text[-1])       # é
print(text[1:3])      # af
items = [10, 20, 30]
items[-1] = 40
copy = items[:]
```

### Format specifications

An f-string field may end in a format specification, `{expression:spec}`. The
separating colon is the first one outside nested parentheses, brackets, braces,
and string literals, so `f"{text[1:3]}"` contains a slice and no specification. A
specification has the form `[alignment][width][.precision][type]`: alignment is
`<`, `>`, or `^`; width and precision are unsigned decimal integers without leading
zeros; type is `s`, `d`, or `f`. An empty specification has no effect.

- Without a type, a field formats any printable value as `str` does. Precision
  requires `f`. `s` requires `str`, `d` requires `int`, and `f` requires `float`;
  a union must be narrowed first.
- `f` writes fixed-point notation with six fractional digits by default, rounding
  to nearest with ties to even; NaN and infinities keep their usual spelling.
- Padding uses spaces. Alignment defaults to left for strings and right for other
  values, judged by the value a union holds. Center alignment puts an odd extra
  space on the right. Width is a minimum length in code points and never truncates.
- A malformed specification or a mismatched type is a compile-time error. There are
  no fill characters, grouping, signs, zero padding, or nested fields.

```python
print(f"{'total':<12s}{12:>6d}{2.5:>10.2f}")
```

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

### Bytes

```python
data = "café".encode()      # bytes([99, 97, 102, 195, 169])
print(len(data))            # 5
print(data[-1])             # 169
print(data[:3].decode())    # caf
```

| Expression | Type | Meaning |
| --- | --- | --- |
| `bytes(values)` | `bytes` | The octets of a `list[int]` of values from 0 through 255 |
| `a + b` | `bytes` | Concatenation |
| `len(data)` | `int` | Number of octets |
| `data[i]` | `int` | The octet at index `i` |
| `data[i:j]` | `bytes` | The octets from index `i` up to `j` |
| `s.encode()` | `bytes` | The UTF-8 encoding of the string `s` |
| `data.decode()` | `str` | The text whose UTF-8 encoding is `data` |

`for` over bytes yields each octet as an `int`. Indexes and slices follow the
string and list rules. `bytes` of a value outside 0 through 255 raises
`ValueError` with the message `bytes must be in range(0, 256)`, an invalid index
raises `IndexError` with the message `index out of range`, and `decode` of
anything but valid UTF-8 raises `ValueError` with the message `invalid UTF-8`.
There are no byte literals. Bytes cannot be printed, formatted, converted with
`str`, ordered, used as dictionary keys, or assigned through an index.

### Lists and dictionaries

Dictionary keys are `int` or `str`. Element and value types can be any type.
Collections store `None`; a stored `None` counts toward length and is distinct from
a missing key.

| Expression | Type | Meaning |
| --- | --- | --- |
| `len(xs)` | `int` | Number of elements |
| `xs[i]` | `T` | Element at index `i` |
| `xs[i] = v` | | Replace the element at index `i` |
| `xs[i:j]` | `list[T]` | A new list of the elements from index `i` up to `j` |
| `xs.append(v)` | `None` | Add `v` at the end |
| `xs.pop()` | `T` | Remove and return the last element |
| `xs.sort(reverse)` | `None` | Sort the list in place |
| `v in xs` | `bool` | Some element equals `v` |
| `len(d)` | `int` | Number of entries |
| `d[k]` | `V` | Value for key `k` |
| `d[k] = v` | | Insert or replace the entry for `k` |
| `d.get(k)` | `V \| None` | Value for `k`, or `None` when missing |
| `d.pop(k)` | `V` | Remove the entry for `k` and return its value |
| `k in d` | `bool` | `k` is a key |

List indexes are zero-based and may be negative (§7, Indexes and slices); an index
outside the list raises `IndexError` with the message `list index out of range`.
`pop()` on an empty list raises `IndexError` with the
message `pop from empty list`. `d[k]` and `d.pop(k)` raise `KeyError` with the
message `key not found` for a missing key. When `V` is already optional, `d.get(k)`
has type `V`. `v in xs` requires an element type that supports `==`.

Replacing a dictionary value keeps the entry's position; a key removed and inserted
again moves to the end.

`sorted(items, reverse)` returns a new sorted list of `items`, and
`xs.sort(reverse)` sorts `xs` in place. `reverse` is a `bool` and defaults to
`False`. The element type must be exactly `int`, `float`, or `str`. Sorting is
stable in both directions, compares strings by code point, and keeps the usual
comparisons for infinities and signed zeros. A list containing NaN raises
`ValueError` with the message `cannot sort NaN` before anything changes.

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
assert condition
assert condition, message

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

`assert` takes a `bool` condition and an optional `str` message and is always
enabled. When the condition is false, the message is evaluated and the statement
raises `AssertionError` with it, or with `assertion failed` when there is none; a
true condition does not evaluate the message.

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
library's `sys.exit` (§14) transfer control; `assert`, even `assert False`, does
not. An `if` whose branches all transfer, including an `else`, transfers. A
statement after a transfer in the same block is an unreachable-code error.

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
- The statements after an `assert` have the true facts of its condition, and its
  message is checked with the false facts.
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
| `AssertionError` | A false `assert` condition |
| `OverflowError` | Integer overflow |
| `ZeroDivisionError` | Division by zero |
| `ValueError` | Invalid values for conversions, `ord`, `chr`, `range`, `split`, `sys.exit`, and UTF-8 input |
| `IndexError` | List indexes and `pop` from an empty list |
| `KeyError` | Missing dictionary keys |
| `RuntimeError` | Dictionary size changes during iteration |
| `OSError` | Failed filesystem and host operations |
| `TimeoutError` | Expired time limits |

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

Stack exhaustion, memory exhaustion, failure to write stdout or stderr through
`print`, `sys.eprint`, or the final flush (§14), and failure to read stdin through
`input` terminate the program with status 1. They cannot be caught. A write to a
closed pipe is such a failure rather than a signal.

## 11. Built-in functions

| Function | Meaning |
| --- | --- |
| `print(value) -> None` | Write a printable value and `\n` to stdout |
| `input() -> str \| None` | The next line of stdin without its line ending, or `None` at end of input |
| `len`, `range`, `int`, `float`, `str`, `bytes`, `ord`, `chr`, `isinstance`, `sorted` | See §4, §6, §7, and §8 |

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

### Tests

```python
# test_cart.wlo, next to cart.wlo
import cart

def test_empty_cart_totals_zero() -> None:
    assert cart.total(cart.Cart([])) == 0
```

`willow test [path]` takes a file or a directory, `.` by default. A directory
contributes the files directly inside it named `test_*.wlo`; a file named
explicitly may have any name. Each test file is an entry file whose imports
resolve from its own directory. It needs no `main`; its functions named `test_*`
are its tests, and each must take no parameters and return `None`.

Every test file and its imports are checked before any test runs. Tests run in
order of file path, then function name, each in a new process with no program
arguments, empty stdin, and the current working directory. A test passes when it
returns. An uncaught exception, a `sys.exit` call with any status, or any other
abnormal end fails it, and later tests still run.

The report lists `PASS path name` or `FAIL path name` for each test. A failure is
followed by the test's combined stdout and stderr, indented, and its exit status;
the last line counts the passed and failed tests. The command exits with status 0
only when at least one test ran and every test passed; usage errors, check errors,
finding no tests, and failed tests exit with status 1. Tests share the filesystem
and environment.

`willow test --check [path]` finds and checks the tests without running them, and
exits with status 0 when they are valid and there is at least one.

Programs run by `willow run` and `willow test` have the environment variable
`WILLOW` set to the absolute path of the `willow` launcher, replacing any
inherited value. Compiled and built programs do not set it.

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

| Declaration | Meaning |
| --- | --- |
| `read_file(path: str) -> str` | The contents of the file |
| `write_file(path: str, text: str) -> None` | Create the file, or replace its contents, with `text` |
| `join(a: str, b: str) -> str` | `a` and `b` joined with `/`; an absolute `b` replaces `a` |
| `basename(path: str) -> str` | The text after the last `/`; empty after a trailing `/` |
| `dirname(path: str) -> str` | The text before the last `/`, or empty when there is none |
| `listdir(path: str) -> list[str]` | The directory's entry names, without `.` and `..`, sorted by code point |
| `stat(path: str, follow_symlinks: bool = True) -> Stat` | The file's metadata |
| `exists(path: str) -> bool` | Whether the path, followed through symlinks, exists |
| `mkdir(path: str, parents: bool = False, exist_ok: bool = False) -> None` | Create a directory |
| `remove(path: str) -> None` | Remove a file or symlink |
| `rmdir(path: str) -> None` | Remove an empty directory |
| `rename(source: str, destination: str) -> None` | Rename, replacing the destination where POSIX allows |
| `class Stat` | Fields `kind: str`, `size: int`, and `modified: float` |

Paths are strings, relative to the working directory unless absolute. `read_file`
and `write_file` transfer text exactly, without line-ending translation, and
`write_file` does not replace the file atomically.

`join`, `basename`, and `dirname` work on the text alone, as Python's
`posixpath` does: they do not touch the filesystem, follow symlinks, or collapse
`..`. `join("a", "")` is `a/`, `join("", "b")` is `b`, and a head of only slashes
stays whole, so `dirname("//a")` is `//`.

`Stat` is an ordinary record. `kind` is `file`, `directory`, `symlink`, or
`other`; `size` is the size in bytes; `modified` is the modification time in
seconds since the Unix epoch. With `follow_symlinks`, it describes the symlink's
target. A size above the `int` range raises `OverflowError` with the message
`file size out of range`.

`exists` is false for a missing path, a dangling symlink, or a path through a
non-directory; any other failure raises. `mkdir` with `parents` creates missing
parent directories, and with `exist_ok` accepts an existing directory but not a
file. New directories get the host's default permissions under its umask.
`rename` does not move across filesystems.

A path containing NUL raises `ValueError` with the message
`path contains a NUL character`. Text read by `read_file` and names from
`listdir` must be valid UTF-8, or the call raises `ValueError` with the message
`invalid UTF-8`. A failed host operation raises `OSError` with a message naming
the operation and path and giving the host's reason, such as
`cannot read <path>: <reason>`, `cannot write <path>: <reason>`,
`cannot list <path>: <reason>`, or `cannot remove directory <path>: <reason>`.

### `io`

```python
import io

def main() -> None:
    source = io.open("input.bin")
    try:
        target = io.open("output.bin", mode="w")
        try:
            while True:
                chunk = source.read(65536)
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
| `open(path: str, mode: str = "r") -> File` | Open a file to read (`r`), to write after creating or truncating it (`w`), or to append after creating it if needed (`a`) |
| `stdin() -> File` | A handle for standard input, open for reading |
| `stdout() -> File` | A handle for standard output, open for writing |
| `stderr() -> File` | A handle for standard error, open for writing |
| `class File` | A native type with the methods below |

| `File` method | Meaning |
| --- | --- |
| `read(size: int) -> bytes` | Up to `size` octets; empty only at end of input |
| `readline() -> str \| None` | The next line as `input` reads it, or `None` at end of input |
| `write(data: bytes) -> None` | Write all of `data` |
| `write_text(text: str) -> None` | Write the UTF-8 encoding of `text`, without adding a newline |
| `flush() -> None` | Write any buffered data |
| `close() -> None` | Flush and close the file |

A native type is a library type with methods. Only its module's functions create
its values, and it has no fields. It can be used in annotations, aliases, unions,
and `isinstance`, and its values can be stored and passed; it does not support
`==`, printing, or construction. Every reference to a handle shares it, so
closing one closes them all.

Files carry octets with no newline translation; `readline` and `write_text` use
UTF-8. `readline` removes the line's `\n` and a `\r` just before it, returns a
final line that has no line ending, returns `""` for an empty line, and consumes
a line that is not valid UTF-8 before raising `ValueError` with the message
`invalid UTF-8`. Byte and line reads share the file position. Reads may return
fewer octets than asked for.

The standard handles share their streams' buffers with `input`, `print`, and
`sys.eprint`, so reads and writes through either keep their order. When `main`
returns, when an uncaught exception ends the program, and in `sys.exit`, stdout
and stderr are flushed. Data written to an owned file is guaranteed to reach it
only after `flush` or `close`, so close owned files with `try/finally`.

`close` is idempotent and closes the handle even when it fails. These raise
`ValueError`:

- any other operation on a closed handle: `I/O operation on closed file`;
- reading a handle open for writing or writing one open for reading:
  `file is not open for reading` or `file is not open for writing`;
- `read` with a size below 1: `read size must be positive`;
- closing a standard handle: `cannot close a standard stream`;
- `open` with any other mode: `invalid mode '<mode>'`;
- `open` with a path containing NUL: `path contains a NUL character`.

Host failures raise `OSError` with the message `cannot open <path>: <reason>`,
`cannot read <path>: <reason>`, `cannot write <path>: <reason>`, or
`cannot close <path>: <reason>`, where the standard handles' paths are
`<stdin>`, `<stdout>`, and `<stderr>`. Unlike `print`, a failed write through a
handle, including to a closed pipe, can be caught.

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
| `getenv(name: str) -> str \| None` | The value of environment variable `name`, or `None` when it is unset |
| `environ() -> dict[str, str]` | A new dictionary of the environment, in name order |
| `getcwd() -> str` | The absolute path of the working directory |

`args` raises `ValueError` with the message `invalid UTF-8` when an argument is not
valid UTF-8.

`exit` takes a status from 0 through 255 and otherwise raises `ValueError` with the
message `exit status out of range`. It flushes stdout and stderr and ends the
program at once; pending `finally` clauses do not run.

Changing the dictionary `environ` returns does not change the environment. An
environment name that is empty or contains `=` or NUL raises `ValueError` with the
message `invalid environment variable name`. Values, and the working directory,
must be valid UTF-8, or the call raises `ValueError` with the message
`invalid UTF-8`.

### `time`

| Function | Meaning |
| --- | --- |
| `time() -> float` | Seconds since the Unix epoch |
| `monotonic() -> float` | Seconds on a clock that never goes back, from an unspecified start |
| `sleep(seconds: float) -> None` | Wait at least `seconds` |
| `utc(timestamp: float) -> str` | The UTC time `timestamp` as `YYYY-MM-DDTHH:MM:SSZ` |

`sleep` raises `ValueError` with the message
`sleep length must be finite and nonnegative` for a negative or non-finite
duration. `utc` rounds down to whole seconds, covers years 0001 through 9999, and
raises `ValueError` with the message `timestamp out of range` otherwise.

## Planned application development milestones

Sections 20–24 define accepted targets, in implementation order. They are not yet
implemented. Sections 1–19 describe the implemented baseline; each planned section
identifies the rules it changes when its milestone lands. Completion and delivery
examples are tracked in `agents/todo.md`. A planned API is not available merely
because its signature appears here.

Prefer Python's familiar spelling and behavior where they fit Willow's static
types and small scope. Keep differences explicit. These milestones retain strict
boolean conditions, explicit numeric conversions, declaration-only modules, and
functions that are not values. They introduce neither general inheritance nor
user-defined protocols, callbacks, async execution, or a package registry.

Library signatures below describe the public contract. `T` in a signature is
explanatory notation for an existing element type, not user-defined generics.
`= value` denotes an optional argument. Module functions are called with the module
prefix. Unless specified otherwise, result records follow §3, and new exceptions
have only `message: str` and directly extend `Exception`.

New native types follow the `io.File` conventions of §14. Invalid options and
values raise `ValueError`, and expired waits raise `TimeoutError` (§10). Unless an
API says otherwise, a timeout is a finite, strictly positive float in seconds,
`None` means no limit, and elapsed time is measured on a monotonic clock.

## 15. Text and collection essentials

This milestone is implemented. Its rules are part of §2, §5, §7, and §11.

## 16. Readable function and record APIs

This milestone is implemented. Its rules are part of §3 and §5.

## 17. Application tests and editor basics

This milestone is implemented. Its rules are part of §1, §8, §9, §10, and §12.
Editor support is described in `README.md`.

## 18. Filesystem, environment, and time

This milestone is implemented. Its rules are part of §10 and §14. The native-type
conventions it introduced take effect with §19.

## 19. Bytes and streaming I/O

This milestone is implemented. Its rules are part of §2, §4, §5, §7, §10, §11,
and §14.

## 20. Subprocess execution and control

The `subprocess` module executes argument lists directly, never through a shell.
Arguments and environment values are UTF-8 and cannot contain NUL. Arguments must
contain a nonempty executable name. Names with a slash are paths; other names use
the child's `PATH`, or `/usr/bin:/bin` when it is absent. Launch failures raise
`OSError`, not a returned exit status.

```text
run(args: list[str], input: bytes | None = None,
    capture_output: bool = False, cwd: str | None = None,
    env: dict[str, str] | None = None,
    timeout: float | None = None) -> Result

spawn(args: list[str], cwd: str | None = None,
      env: dict[str, str] | None = None,
      stdin: io.File | None = None, stdout: io.File | None = None,
      stderr: io.File | None = None) -> Process
```

`cwd=None` inherits the working directory. `env=None` inherits the environment;
a provided dictionary replaces it. `sys.environ()` is the way to inherit and
change selected values. Calls snapshot arguments and environment. Child changes
do not change the parent's environment or working directory.

### Running a command

`Result` has fields `returncode: int`, `stdout: bytes | None`, and
`stderr: bytes | None`. Nonzero exit codes are ordinary results; a signal exit is
the negative signal number. With `capture_output=True`, both output streams are
captured as bytes, including empty bytes, and drained concurrently with supplying
input so pipe capacity cannot deadlock the child. Otherwise they are inherited
and both result fields are `None`.

With `input=None`, stdin is inherited. Otherwise the supplied bytes are sent and
stdin is closed; an empty value supplies immediate EOF. A child that closes input
early is allowed to finish, and its result is returned without raising a
broken-pipe error for the unused input. Callers decode captured text explicitly.
Capture stores output in memory; use `spawn` and file redirection for large output.

The timeout bounds communication and waiting after successful process creation.
Expiry kills and reaps the direct child, then raises `TimeoutError`; it does not
promise to kill descendants or return partial captures. Pipe cleanup must not wait
indefinitely for descendants that inherited descriptors. Process creation itself
is not promised interruptible.

### Child lifecycle

`spawn` returns a native `Process`. A `None` stream inherits that standard stream;
a supplied file must be open with the appropriate access mode. Passing buffered
input with unread prefetched bytes is rejected with `ValueError`, since an OS
child cannot consume the parent's buffer. The child receives its own descriptor
references; the parent retains ownership of its files. The API exposes no live
child pipe handles.

| `Process` method | Meaning |
| --- | --- |
| `poll() -> int \| None` | Collect an exit status if ready, otherwise return `None` |
| `wait(timeout: float \| None = None) -> int` | Wait for and collect exit status |
| `terminate() -> None` | Send SIGTERM to the running direct child |
| `kill() -> None` | Send SIGKILL to the running direct child |

Collected statuses are cached; repeated `poll` and `wait` agree. Signals to an
already collected child do nothing. A `wait` timeout leaves the child alive;
callers must explicitly stop it if needed and eventually call `wait` to reap it.
There is no `Process.close()` and no automatic termination at garbage collection.

Before launching either kind of child, flush parent stdout/stderr and supplied
writable files. Failure prevents launch and raises `OSError`. Implicitly inherited
stdin uses the underlying descriptor, as in Python: unread bytes already prefetched by the
parent stay in its buffer and are not passed to the child. This does not cause a
launch error; callers that need those bytes must supply explicit `input` instead.
The unread-buffer rejection applies only to explicitly supplied `stdin` handles.
Children start with the ordinary POSIX
SIGPIPE disposition even if Willow suppresses it for its own checked writes.

```python
import subprocess

def main() -> None:
    result = subprocess.run(["printf", "%s", "hello"], capture_output=True)
    output = result.stdout
    if output is not None:
        print(output.decode())
```

## 21. Command-line and terminal tools

### `cli`

`cli.parser(prog: str, description: str = "") -> cli.Parser` creates a native
argument parser. Its schema is explicit; it does not inspect user records or
require callbacks. Typed option defaults are required, making getters nonoptional.

```text
Parser.add_str(name: str, default: str, help: str = "",
               short: str | None = None, required: bool = False) -> None
Parser.add_int(name: str, default: int, help: str = "",
               short: str | None = None, required: bool = False) -> None
Parser.add_float(name: str, default: float, help: str = "",
                 short: str | None = None, required: bool = False) -> None
Parser.add_flag(name: str, help: str = "", short: str | None = None) -> None
Parser.add_positional(name: str, help: str = "") -> None
Parser.add_rest(name: str, help: str = "") -> None
Parser.parse(args: list[str]) -> Args
Parser.help() -> str

Args.get_str(name: str) -> str
Args.get_int(name: str) -> int
Args.get_float(name: str) -> float
Args.get_bool(name: str) -> bool
Args.get_list(name: str) -> list[str]
```

An option name contains ASCII letters, digits, and single interior hyphens,
begins with a letter, and denotes `--name`. A short spelling, when present, is
one ASCII letter without a dash and denotes `-x`. Names and spellings must be
unique; `--help` and `-h` are reserved. Getter names are the registered names.
Positionals use the same naming rules and share the name namespace.

Options accept `--name value`, `--name=value`, or `-x value`. Flags take no value
and default to false. Repeated value options use the last value; repeated flags
remain true. `--` ends option processing. There is no abbreviation, short-option
bundling, subcommand system, environment lookup, or response-file expansion.
A value-taking option consumes the next argument even if it starts with `-`;
for signed numeric positionals use `--` when needed. Options may appear among
positionals. Fixed positionals are required strings. At most one `add_rest`
collects zero or more remaining positionals into `list[str]`, and it must follow
all fixed positionals.

Integer and float values use §6's conversions. `required=True` requires an
explicit occurrence even though the schema supplies a typed default. A missing
value, unknown option, conversion failure, or wrong positional count raises
`cli.UsageError` with a useful message. Encountering help in option position
raises `cli.HelpRequested`, whose message is the generated help. Both are exception
classes; neither prints nor exits. Applications handle them with statuses 2 and 0
respectively. Help includes usage, description, declared options/positionals,
required markers, and defaults in declaration order, with a trailing newline.

Invalid schemas and wrong getter names or types raise `ValueError`, not
`UsageError`. Parse results are independent snapshots; `get_list` returns a copy.
User code may construct its own options record from the typed getters.

```python
import cli
import io
import sys

def main() -> None:
    parser = cli.parser("report", description="Summarize a log file")
    parser.add_int("limit", 10, help="Maximum rows", short="n")
    parser.add_positional("file")
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

### `terminal`

| Function | Meaning |
| --- | --- |
| `isatty(file: io.File) -> bool` | Whether the stream is a terminal |
| `color_enabled(file: io.File) -> bool` | TTY, `TERM` is not `dumb`, and `NO_COLOR` is absent |
| `style(text: str, color: str = "default", bold: bool = False, enabled: bool = True) -> str` | Wrap text in ANSI style/reset sequences, or return it unchanged |
| `progress(message: str) -> None` | Replace the current stderr progress line and flush |
| `finish_progress(message: str = "") -> None` | Clear an active progress line and write any final message to stderr |

Colors are `default`, `black`, `red`, `green`, `yellow`, `blue`, `magenta`, `cyan`,
and `white`; unknown names raise `ValueError`. `style` is independent of the host;
applications pass `enabled=terminal.color_enabled(stream)` or an explicit override.
`progress` does nothing when stderr is not a terminal or `TERM=dumb`.
`finish_progress` clears the line only on a capable terminal, then writes any
nonempty message followed by a newline on every destination and flushes. An empty
message only clears the line. Progress messages must contain no CR or LF, or
raise `ValueError`. These operations use the shared stderr buffer and leave stdout
untouched. There is no raw keyboard
mode, cursor-positioning API, terminal-size model, or full-screen UI system.

## 22. HTTP and HTTPS clients

The `http` module provides synchronous requests without an HTTP server framework.
It accepts absolute `http` and `https` URLs, with ASCII hostnames (internationalized names must already be in ASCII IDNA
form) and non-ASCII path/query characters percent-encoded as UTF-8.
Already valid percent escapes are preserved. URL user information is rejected;
fragments are removed before sending. Other schemes and malformed URLs raise
`ValueError`.

The following are ordinary records:

```text
Header(name: str, value: str)
Response(status: int, headers: list[Header], body: bytes, url: str)
Download(status: int, headers: list[Header], url: str, bytes_written: int)
```

```text
request(method: str, url: str, headers: list[Header] | None = None,
        body: bytes | None = None, timeout: float = 30.0,
        follow_redirects: bool = True, ca_file: str | None = None) -> Response

download(url: str, path: str, headers: list[Header] | None = None,
         timeout: float = 30.0, follow_redirects: bool = True,
         ca_file: str | None = None) -> Download

header(headers: list[Header], name: str) -> str | None
urlencode(values: dict[str, str]) -> str
```

Methods are nonempty ASCII HTTP tokens, sent as supplied; callers normally use
uppercase names. Outgoing header names are ASCII HTTP tokens; values must be
ASCII text or tab, with no CR, LF, NUL, or other controls. Host, Content-Length,
and Transfer-Encoding are managed by the transport and cannot be supplied.
Header lists preserve order and duplicate fields. Received non-ASCII header
bytes are mapped one-to-one to Unicode U+0080–U+00FF; header values are not decoded
as UTF-8. `header` returns the first case-insensitive name match, or `None`;
callers scan the list when repeated values matter.

`urlencode` emits dictionary entries in insertion order as form-style query pairs:
UTF-8 bytes are percent-encoded except ASCII letters, digits, `-`, `.`, `_`, and
`~`; spaces become `+`. It does not add `?` or merge with an existing query.
No implicit JSON conversion occurs: compose `json.dump(...).encode()` and
`json.parse(response.body.decode())` explicitly.

### Requests, redirects, and timeouts

A completed HTTP exchange returns its status, including 4xx and 5xx. Transport,
protocol, and TLS failures raise `OSError`; invalid arguments raise `ValueError`.
The body contains the received representation bytes with transport framing
removed. There is no automatic content decompression or content-type decoding,
no cookie jar, automatic retry, or ambient credentials or proxy configuration.
Each request is independent; backend user configuration must not alter behavior.

When enabled, redirects are followed only for GET and HEAD, for statuses 301,
302, 303, 307, and 308 with Location. Resolve relative targets against the current
URL, allow at most ten hops, and never follow HTTPS to HTTP. A forbidden downgrade,
invalid redirect target, or excess hops raises `OSError`. Other methods return the
redirect response. When origin (scheme, host, or effective port) changes, discard
all caller-supplied headers for subsequent hops, preventing credential leakage
through custom header names. Response metadata describes the final exchange.

The timeout is an inactivity limit: connection establishment and each wait for
network progress may take at most that duration. Progress renews the wait; it is
not a total download deadline. Redirects also get this limit. Expiry raises
`TimeoutError`. Hostname resolution uses the host resolver and may block beyond
this limit; that limitation must be stated in the library documentation.

HTTPS always verifies certificate chains and hostnames. `ca_file=None` uses the
platform's trusted certificates; a provided path selects an explicit PEM trust
bundle instead. There is no insecure verification switch.

### Downloads and deployment

`download` makes a GET request and streams a 2xx body into a temporary sibling of
`path`. Only after a successful flush and close does it replace the destination.
Existing content remains intact on errors. A non-2xx final response returns a
`Download` with zero bytes written and leaves the destination untouched; its body
is discarded. Temporary output is removed on failure. The byte count is the final
file size; a count outside the integer range raises `OverflowError`. Downloads
use bounded chunks rather than retaining the whole body.

The backend must use maintained HTTP/TLS libraries. Selection remains an
implementation gate: prove certificate lookup and dependency behavior on macOS
and Linux for `run`, compiled Lua, and standalone executables before adopting it.
Built applications must not require a separately installed command or Willow
checkout; compiled Lua must retain its documented LuaJIT-only runtime dependency.
Any necessary change to that deployment contract requires a separate explicit
scope decision. This specification does not claim a backend has met the gate.

## 23. TCP clients and simple services

The `net` module exposes blocking TCP connections and listeners with native
methods. Hostnames use the host resolver; literal IPv4 and IPv6 addresses are
accepted. Host strings must be ASCII (use an ASCII IDNA name when needed).
Ports are integers in 1–65535, except a listener may use zero for a host-selected
port. Invalid inputs raise `ValueError`; host network failures raise `OSError`.

```text
connect(host: str, port: int, timeout: float | None = 30.0) -> Connection
listen(host: str, port: int, backlog: int = 16) -> Listener

Connection.recv(size: int, timeout: float | None = None) -> bytes
Connection.sendall(data: bytes, timeout: float | None = None) -> None
Connection.close() -> None

Listener.accept(timeout: float | None = None) -> Connection
Listener.local_port() -> int
Listener.close() -> None
```

`listen` binds the specified address, with positive backlog. No wildcard default
is supplied: use an explicit loopback address for local services. If a hostname
resolves to multiple addresses, `connect` tries them in resolver order with one
shared connect-time budget; `listen` binds the first usable address and does not
promise dual-stack coverage. Name resolution precedes the connect-time budget
and is subject to §22's resolver limitation.

`recv` requires positive size and returns one available chunk of up to that many
bytes; empty bytes mean the peer closed its sending side. It does not wait to fill
the requested size. `sendall` completes the entire byte string or raises; empty
input returns immediately. Its timeout bounds the entire send, not each partial
write. After any send failure, the caller cannot know how much the peer received
and must close the connection before further I/O; subsequent I/O raises
`ValueError`. A receive or accept timeout leaves the handle usable.

Timeouts bound individual calls, never an application's multi-call message loop.
An application needing a total message deadline computes its remaining budget
with `time.monotonic()`. Stream framing is the application's responsibility;
a read may contain part of a message or several messages. Close is idempotent,
and broken-peer writes raise rather than terminating by SIGPIPE.

The initial service model is deliberately sequential. There is no scheduler,
nonblocking API, TLS socket wrapper, UDP, Unix-domain sockets, or HTTP server.
The delivery example shares framing code between a line/JSON client and server;
it handles split UTF-8 bytes before decoding a complete message. Integration tests
use the `WILLOW` launcher variable to start a server through `subprocess.spawn`.
The test passes a port-file path; after binding, the server publishes its selected
port by writing a sibling file and renaming it. The test polls with `time.sleep`
and a monotonic deadline, exchanges messages, and stops and reaps the child and
removes the port file in cleanup. No live subprocess pipe API is required.

## 24. Small projects and reusable modules

### Qualified imports

`import app.util` loads `app/util.wlo` under a search root and binds the qualified
name `app.util`. Each component is an identifier. References use
`app.util.function`, `app.util.Record`, or `app.util.Alias` wherever §12 permits a
module member. Importing a child does not execute or require a parent module;
directories are namespaces without `__init__` files or initialization code.

Multiple imports may share a namespace prefix. A module cannot also serve as a
namespace prefix: importing both `app` and `app.util` is an error. The root name
cannot conflict with another file-level declaration; a local of that name shadows
the entire qualified namespace. Imports are absolute from search roots, not
relative to the importing file's subdirectory. Privacy remains about member names
beginning with `_`, and cycles remain legal because modules contain declarations.

In explicit-file mode, the entry directory remains the first search root,
followed by the standard library. Qualified imports do not introduce automatic
project discovery or change the process working directory.

### Project configuration

An optional `willow.json` in the invocation directory describes a project:

```json
{
  "entry": "main.wlo",
  "source": "src",
  "dependencies": ["vendor/shared"],
  "tests": "tests"
}
```

The file is a JSON object. The only keys are `entry: str`, `source: str`,
`dependencies: list[str]`, and `tests: str`; omitted values default to `main.wlo`,
`.`, `[]`, and `tests`. Unknown keys and wrong types are configuration errors;
repeated keys use the last value, as in the existing JSON library. Entry is
relative to the source root; other paths are relative to the manifest directory.
Entry must stay within the source root, end in `.wlo`, and have identifier
components after removing the extension. Root paths are nonempty; absolute paths
and `..` are allowed for explicit local dependencies. These roots contain `.wlo`
modules, not manifests to resolve recursively. There is no package download, version solver, or lockfile.

A module is resolved from the source root first, then the explicit dependency
roots, then the standard library. More than one dependency match is an ambiguity
error, not an order-dependent choice. Source modules intentionally shadow
libraries. Missing modules are reported at their imports, and resolved physical
files load only once; two qualified names resolving to the same file are rejected.
The entry is registered under its source-relative qualified name, preventing a
second copy through an import. Private members retain their declaration module's
identity across all imports.

### Commands and tests

When the source argument is omitted, `willow check`, `run`, `compile`, and `build`
use the current directory's `willow.json`; there is no ancestor search. `run --`
passes following arguments to the project entry. Compile and build still require
`-o`. A missing manifest is an error. An explicit source file continues to use the
existing file workflow and ignores the manifest.

With a manifest and no explicit test path, `willow test` discovers `test_*.wlo`
recursively under the configured tests directory, using source/dependency/library
roots for imports. Directory symlinks are not traversed. Test entries need no
`main`; discovery order and process isolation follow §17. Test-only helper modules
belong under a source or dependency root; the tests directory is not an implicit
import root. With an explicit test path, that path narrows discovery while
retaining the project roots; directories are still searched recursively. Without a manifest,
§17's standalone discovery and roots apply. The same rules apply to
`willow test --check [path]`.

Commands retain the invoking working directory for application I/O; module paths
and test discovery are resolved using the roots above. Diagnostics identify actual
source files. Compile/build bundle all reachable Willow modules, including local
dependencies, and the overwrite check covers them all. Outputs must run outside
the source tree with the deployment dependencies stated in README and §22.

### Scope references

The familiar conventions above were checked against Python's documentation for
[sequence operations](https://docs.python.org/3/library/stdtypes.html),
[calls](https://docs.python.org/3/reference/expressions.html#calls),
[format specifications](https://docs.python.org/3/library/string.html#format-specification-mini-language),
[subprocesses](https://docs.python.org/3/library/subprocess.html), and
[sockets](https://docs.python.org/3/library/socket.html).
Unicode case data is specified by
[Unicode 17.0](https://www.unicode.org/versions/Unicode17.0.0/).
These are design references, not blanket incorporation of those APIs or semantics;
Willow's rules are the ones stated here.
