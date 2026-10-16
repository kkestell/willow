# Willow Language Specification

Willow is a small, statically typed language with Python-like syntax. It compiles
to Lua and runs on LuaJIT. Source files use the `.wlo` extension.

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

A program consists of an entry file and the modules it imports (§12). A program
can also be organized as a project with a `willow.json` file (§12). A file
contains `import` statements followed by `def`, `class`, and `type` declarations
in any order. No other statements may appear at file scope.

The entry file must define exactly one `main` function, with the signature
`def main() -> None:`. In other modules, `main` is an ordinary function name. The
program reads its command-line arguments with `sys.args()` (§14).

Test files (§12) are entry files that have no `main` function. `willow test` runs
the test functions they define.

The whole program is checked before any of it runs, and an error in any module
prevents the program from running. When the program runs, it calls `main` once.
User code may also call `main`, and such a call behaves like any other function
call. Programs cannot access Lua globals or `require`.

The exit status is 0 when `main` returns and 1 when an exception propagates out
of `main` or the program fails in another way. When the program calls `sys.exit`
(§14), the exit status is the status passed to it.

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
False None True and as assert async await break case class continue def del
elif else except finally for from global if import in is lambda match nonlocal
not or pass raise return try type while with yield
```

The type names `int`, `float`, `bool`, `str`, `bytes`, `list`, and `dict` are
also reserved. Using a reserved word that does not begin one of the constructs in
this specification is an error.

### Numeric literals

An integer literal is a sequence of decimal digits with no leading zeros, except
for `0` itself. A minus sign before a literal is the unary minus operator, not
part of the literal. An integer literal outside the `int` range (§4) is an error.
Hexadecimal literals, binary literals, and underscores in literals are not
supported.

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

Every parameter and the return type must have a type annotation. A parameter may
have a default value after its annotation, as in `prefix: str = "Hello"`. A
default value must be `None`, `True`, `False`, a string literal, or an integer or
float literal with an optional `+` or `-` sign, and it must be assignable to the
parameter's type. A parameter without a default cannot follow a parameter that
has one. Variadic parameters, nested functions, and lambdas are not supported.
Parameter lists and argument lists may end with a trailing comma. A function may
call functions declared later in the file, and functions may be directly or
mutually recursive.

### Classes

A `class` declaration defines a class. The body of the declaration contains
field declarations followed by method declarations, and nothing else. It must
contain at least one of either:

```python
class Node:
    value: int
    next: Node | None
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
    verbose: bool = False

options = Options(verbose=True)
```

`p.x` reads the field `x`, and `p.x = v` replaces its value. The new value `v`
must be assignable to the field's type. Referring to a field that the class does
not have is an error.

A method is a function declared in a class body. Its first parameter is `self`,
which has no annotation and has the class's type. The other parameters and the
return type follow the rules for functions:

```python
class Counter:
    count: int = 0

    def add(self, amount: int = 1) -> int:
        self.count = self.count + amount
        return self.count

def main() -> None:
    counter = Counter()
    counter.add()
    print(counter.add(amount=5))    # 6
```

`v.m(arguments)` calls the method `m` of the class of `v`, binding `v` to `self`
and the arguments to the remaining parameters as in a function call (§5). The
value `v` is evaluated before the arguments. Method names must be unique within
a class and cannot be the same as a field name. Like functions, methods may be
recursive and may refer to classes declared later.

Exception classes (§10) are classes declared with the base class `Exception`.
Their first field is `message`, which has no default.

### Type aliases

```python
type Json = None | bool | int | float | str | list[Json] | dict[str, Json]
```

A `type` declaration gives a name to a type. The alias and the type it names are
the same type, and annotations may use either one. An alias may refer to classes
and aliases declared later, and to itself. An alias cannot expand to itself
except inside `list[...]` or `dict[...]`, so `type Loop = int | Loop` is an
error. An alias cannot be called and cannot be used in `isinstance`.

### Annotations

The forms of type annotations are:

```text
int  float  bool  str  None
list[T]  dict[K, V]
Class  module.Class
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
| `dict[K, V]` | Mutable maps from `K` to `V` that keep insertion order |
| Classes | Values of a declared class, including exception classes |
| Native types | Library values such as `io.File` (§14) |

The scalar types are `int`, `float`, `bool`, `str`, `bytes`, and `None`. A type
is printable if it is a scalar type other than `bytes`, or a union of such types.
Lists, dictionaries, and class values are reference types. Assigning one or
passing it as an argument shares the same value instead of copying it.

### Assignability

Willow has no implicit conversions. In particular, `bool` is not a numeric type,
and an `int` is not assignable to `float`. A value is assignable to its own type.
In addition:

- A value is assignable to a union if it is assignable to one of the union's
  members. A union is assignable to a type if each of its members is assignable
  to that type.
- A value of any exception class is assignable to `Exception`.

Assignability rules apply to variable initializers, assignments, function
arguments, return values, elements of list and dict displays, and constructor
arguments. Collection types are invariant. For example, `list[int]` is not
assignable to `list[int | None]`, and `list[ParseError]` is not assignable to
`list[Exception]`.

### Unions

The members of a union may be written in any order, and two unions with the same
members are the same type. When a member is itself a union, such as an alias for
a union, its members become members of the enclosing union. No member may be
assignable to another member, and a union may have at most one `list` member and
at most one `dict` member. So `int | int`, `Exception | ParseError`, and
`list[int] | list[str]` are errors. A union that has `None` as a member, such as
`str | None`, is called an optional type.

A value of a union type can be assigned, passed as an argument, returned,
compared, and printed, and it can be tested with `is None`, `is not None`, and
`isinstance`. To use it in arithmetic, as a condition, or with indexing, field
access, or method calls, it must first be narrowed to a single member (§9).

`isinstance(value, C)` is `True` when `value` holds a value of type `C`. `C` must
be `int`, `float`, `bool`, `str`, `list`, `dict`, or the name of a class,
optionally qualified with a module name. `C` must name the type
of `value` or one of its members. `list` and `dict` refer to the union's list
member and dict member.

```python
def describe(value: int | str | None) -> str:
    if value is None:
        return "nothing"
    if isinstance(value, int):
        return f"number {value + 1}"
    return "text " + value
```

### `None`

Functions annotated `-> None` return `None`. A `return` statement with no value
returns `None`, and such a function may also return by reaching the end of its
body.

## 5. Expressions

The forms of expressions are literals, names, parenthesized expressions, list and
dict displays, calls, indexing, slicing, field access, and unary and binary
operations.

Operator precedence, from lowest to highest:

1. `or`
2. `and`
3. `not`
4. `==`, `!=`, `<`, `<=`, `>`, `>=`, `is`, `is not`, `in`, `not in`
5. Binary `+`, `-`
6. `*`, `/`, `//`, `%`
7. Unary `+`, `-`
8. Postfix operations: calls, indexing `a[i]`, slicing `a[i:j]`, and field or
   method access `a.name`
9. Literals, names, parenthesized expressions, and displays

Binary operators are left-associative. Postfix operations are applied from left
to right, as in `text.strip().split(",")`. The operands of a level 4 operator
must be expressions at level 5 or higher. As a result, `not a == b` means
`not (a == b)`, and `a == not b` is a syntax error. Chained comparisons such as
`0 <= x < 10` are errors.

### Calls

A call can name a function, built-in function, conversion, or class by its bare
name (`area(p)`), a member of a module (`geometry.area(p)`), or a method of a
value (`items.append(x)`, `counter.add(1)`). Functions and methods are not
values. Because of this, `(f)(x)`, `items[0](x)`, and `items.append` without a
call are errors. Every call produces exactly one value.

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
argument for a parameter that has no default, and too many arguments. Functions,
methods, class constructors, `fs.read_file`, `fs.write_file`, `sys.exit`,
`sorted`, and `list.sort` accept keyword arguments, using the parameter names
given in §7 and §14. Other built-in functions and methods accept only positional
arguments.

### Operators

- `and`, `or`, and `not` take `bool` operands and produce a `bool`. `and` and
  `or` evaluate their right operand only when needed.
- `==` and `!=` take two operands whose types are scalar types or unions of
  scalar types, where the type of one operand is assignable to the type of the
  other. For example, if `count` has type `int | None`, both `count == 3` and
  `count == None` are valid. Values of different types are never equal, so a
  union holding `1` is not equal to a union holding `1.0`. Bytes values are equal
  when their contents are equal. Lists, dictionaries, class values, and native
  values cannot be compared with `==`.
- `<`, `<=`, `>`, and `>=` take two integers, two floats, or two strings.
- `is` may only be used as `e is None` or `e is not None`, where `e` has an
  optional type.
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

### Floats

Float arithmetic follows IEEE 754 with round-to-nearest. Results may be infinite
or NaN. `-0.0` and `0.0` are distinct values, but they compare equal. NaN is not
equal to any value, including itself, and every ordering comparison involving NaN
is `False`.

### Division

Both operands of a division operator must have the same numeric type:

| Operator | `int` operands | `float` operands |
| --- | --- | --- |
| `/` | `float` quotient | `float` quotient |
| `//` | `int`, floor of the quotient | `float`, floor of the quotient |
| `%` | `int` remainder | `float` remainder |

The remainder has the same sign as the divisor, and for integers
`(a // b) * b + a % b == a`. Dividing by zero, including by `-0.0`, raises
`ZeroDivisionError` with the message `division by zero`. Results are the same as
in Python: `7 // -2` is `-4`, `7 % -2` is `-1`, `-7.5 // 2.0` is `-4.0`, and
`1 / 3` is `0.3333333333333333`.

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
| `s.find(sub)` | `int` | Index of the first occurrence of `sub`, or `-1` |
| `s.replace(old, new)` | `str` | `s` with every non-overlapping occurrence of `old`, from left to right, replaced by `new` |
| `s.strip()` | `str` | `s` without leading and trailing ASCII whitespace |
| `s.split(sep)` | `list[str]` | The pieces of `s` between occurrences of `sep` |
| `s.lower()` | `str` | `s` converted to Unicode lowercase |
| `s.upper()` | `str` | `s` converted to Unicode uppercase |
| `s.ljust(width)` | `str` | `s` padded on the right with spaces to at least `width` code points |
| `s.rjust(width)` | `str` | `s` padded on the left with spaces to at least `width` code points |
| `sep.join(items)` | `str` | The items of a `list[str]` joined with `sep` |
| `str(value)` | `str` | The text `print` writes for a printable value, without the newline |
| `ord(c)` | `int` | The code point of `c`, which must be a single code point |
| `chr(n)` | `str` | The single-code-point string for code point `n` |

These operations return the same results as in Python, except that `strip`
removes only space, tab, LF, VT, FF, and CR. `split` with an empty separator
raises `ValueError` with the message `empty separator`. `ord` of a string whose
length is not 1 raises `ValueError` with the message `expected one character`.
`chr` of a surrogate, or of a value outside the range 0 through 0x10FFFF, raises
`ValueError` with the message `invalid code point`. An index outside the string
raises `IndexError` with the message `string index out of range`. Strings cannot
be modified by assigning to an index.

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
text = "café"
print(text[-1])       # é
print(text[1:3])      # af
items = [10, 20, 30]
items[-1] = 40
copy = items[:]
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
- A float is written as Python's `repr` writes it. This is the shortest decimal
  text that reads back as the same value. Scientific notation is used when the
  decimal exponent is less than -4 or at least 16. Otherwise fixed notation is
  used, with at least one digit after the decimal point. Non-finite values are
  written as `inf`, `-inf`, and `nan`.
- Booleans are written as `True` and `False`, and `None` is written as `None`.

### Displays

```python
numbers = [1, 2, 3]                     # list[int]
ages = {"ada": 36, "alan": 41}          # dict[str, int]
names: list[str] = []
scores: dict[str, int | None] = {"ada": None}
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
data = "café".encode()      # bytes([99, 97, 102, 195, 169])
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

Dictionary keys must be `int` or `str`. List elements and dictionary values can
have any type. A list or dictionary can store `None`. A stored `None` counts
toward the collection's length, and a key whose value is `None` is different from
a missing key.

| Expression | Type | Meaning |
| --- | --- | --- |
| `len(xs)` | `int` | Number of elements |
| `xs[i]` | `T` | Element at index `i` |
| `xs[i] = v` | | Replace the element at index `i` |
| `xs[i:j]` | `list[T]` | A new list of the elements from index `i` up to `j` |
| `xs.append(v)` | `None` | Add `v` to the end |
| `xs.pop()` | `T` | Remove and return the last element |
| `xs.sort(reverse)` | `None` | Sort the list in place |
| `v in xs` | `bool` | Some element equals `v` |
| `len(d)` | `int` | Number of entries |
| `d[k]` | `V` | Value for key `k` |
| `d[k] = v` | | Insert or replace the entry for `k` |
| `d.get(k)` | `V \| None` | Value for `k`, or `None` if `k` is missing |
| `d.pop(k)` | `V` | Remove the entry for `k` and return its value |
| `k in d` | `bool` | `k` is a key |

List indexes start at zero and may be negative (see Indexes and slices above). An
index outside the list raises `IndexError` with the message
`list index out of range`. `pop()` on an empty list raises `IndexError` with the
message `pop from empty list`. `d[k]` and `d.pop(k)` raise `KeyError` with the
message `key not found` when `k` is missing. When `V` is already an optional
type, `d.get(k)` has type `V`. `v in xs` requires an element type that supports
`==`.

Replacing the value of an existing key keeps the entry in its current position.
A key that is removed and then inserted again moves to the end.

`sorted(items, reverse)` returns a new sorted list containing the elements of
`items`, and `xs.sort(reverse)` sorts `xs` in place. `reverse` is a `bool` and
defaults to `False`. The element type must be exactly `int`, `float`, or `str`.
Sorting is stable in both directions and compares strings by code point.
Infinities and signed zeros are ordered by the usual comparisons. If the list
contains NaN, sorting raises `ValueError` with the message `cannot sort NaN`
before changing anything.

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

A block must contain at least one statement. Use `pass` for an empty block. The
only expressions that may be used as statements are calls. An assignment has
exactly one target and one value. Chained assignment, destructuring assignment,
augmented assignment such as `+=`, and assignment expressions are not supported.

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
each code point as a one-code-point string; or a call to `range`.

- `range(stop)`, `range(start, stop)`, and `range(start, stop, step)` take
  integers and produce the same sequence as in Python. A step of zero raises
  `ValueError` with the message `range step must not be zero`. `range` can only
  be used as the iterable of a `for` loop.
- The iterable and the arguments to `range` are evaluated once, before the first
  iteration.
- Assigning to the loop variable inside the body does not change the iteration.
  After the loop ends, the loop variable keeps the last value it had.
- Iteration over a list continues as long as the current index is less than the
  list's current length, so elements appended during the loop are visited.
- If keys are added to or removed from a dictionary while a loop iterates over
  it, the next step of the loop raises `RuntimeError` with the message
  `dictionary changed size during iteration`. Replacing the values of existing
  keys is allowed.

## 9. Names and static checking

### Scope

Each function has a single local scope. Parameters, assignment targets, `for`
loop variables, and names bound by `except ... as` are local to the whole
function, wherever in the function they appear. Blocks do not create scopes, and
there are no module-level variables or global variables.

The file scope contains functions, classes, aliases, and imports. These share a
single namespace with the built-in names (§11). It is an error to declare the
same name twice, to give two parameters the same name, or to declare a file-level
name that is also a built-in name. A local variable with the same name as a
function, class, alias, import, or built-in hides it throughout the function.
Calling a local variable is an error, even before the variable's first
assignment. Type annotations in the function still refer to the hidden class or
alias.

### Local types

The type of a local variable is set by its first assignment in the source text.
If that assignment has an annotation, the variable has the annotated type.
Otherwise it has the type of the assigned value. Every later assignment must be
assignable to that type. An annotation must have a value, and it may only appear
on a variable's first assignment. An assignment to a parameter cannot have an
annotation.

```python
count: int = 3
count = count + 1     # valid
count = "four"        # type error
best: str | None = None
```

A `for` loop or an `except ... as` clause assigns to its variable. The item type
or the handled exception type must be assignable to the variable's type. If the
clause is the variable's first assignment in the source text, it sets the
variable's type.

### Definite assignment

A local variable may only be read at points where it has been assigned on every
path that reaches that point. This is determined from the structure of the code:

- After an `if` statement, a variable is assigned if every branch that completes
  normally assigns it. An `if` without an `else` has an implicit empty `else`
  branch that completes normally.
- The body of a `while` or `for` loop may run zero times, so assignments in the
  body do not count as assignments after the loop.
- A variable bound by `except ... as` is assigned inside its `except` clause.

The checker does not evaluate conditions. Both branches of every `if` are
checked, and `if False:` and `while True:` are treated the same as any other
condition.

### Control transfer

`return`, `break`, `continue`, `raise`, and a statement that calls the standard
library function `sys.exit` (§14) transfer control. `assert` does not, even
`assert False`. An `if` statement with an `else` branch transfers control if all
of its branches do. A statement that follows a control transfer in the same block
is an unreachable-code error.

A function whose return type is not `None` must return a value on every path. The
checker never treats a loop as guaranteeing a return, so a final `return` is
required even after `while True:`.

### Narrowing

A local variable or parameter that has a union type is narrowed to a subset of
its members wherever a check proves that its value has one of those types. When
only one member remains, the variable has that member's type. Each condition
produces facts that hold when it is true and facts that hold when it is false:

- `name is not None`, when true, narrows `name` to its members other than
  `None`. `name is None` does the same when false.
- `isinstance(name, C)`, when true, narrows `name` to the member named by `C`.
  When false, it narrows `name` to its other members.
- `not C` swaps the true and false facts of `C`.
- `A and B`, when true, has the true facts of both `A` and `B`. `B` is checked
  with the true facts of `A`.
- `A or B`, when false, has the false facts of both `A` and `B`. `B` is checked
  with the false facts of `A`.
- Other conditions produce no facts.

Field access and index expressions are not narrowed. To narrow such a value,
assign it to a local variable first. Facts apply to statements as follows:

- An `if` or `elif` branch starts with the true facts of its condition and the
  false facts of all earlier conditions in the statement. An `else` branch, or
  the implicit empty `else` branch, starts with the false facts of every
  condition.
- After an `if` statement, a variable's possible members are those it has at the
  end of any branch that completes normally.
- A `while` body starts with the true facts of its condition.
- The statements after an `assert` have the true facts of its condition, and its
  message is checked with the false facts.
- Assigning a value whose type is a single member other than `None` narrows the
  variable to that member. Assigning any other value removes the variable's
  narrowing.
- At the start of a loop body and after the loop, narrowing established before
  the loop still applies only to variables that the body does not assign.

```python
def describe(name: str | None) -> str:
    if name is None:
        return "anonymous"
    return "user " + name
```

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

`Exception` is a built-in class with one field, `message: str`. A class declared
with `Exception` as its base is an exception class. Its fields are `message`
followed by the fields it declares, and its constructor takes them in that order.
The body of an exception class may be `pass` instead of field and method
declarations. None of its declared fields or methods may be named `message`. The
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
| `RuntimeError` | Dictionary size changes during iteration |
| `OSError` | Failed filesystem and host operations |
| `TimeoutError` | Expired time limits |

Programs can construct and raise these classes in the same way as their own
exception classes.

### `raise`

`raise expression` raises a value of an exception type. The exception records the
source location of the `raise` statement and the Willow call frames that are
active. When an exception is raised by a failing runtime operation, it records the
location of that operation instead.

A `raise` statement with no expression may only appear inside an `except` clause.
It raises the exception handled by that clause again, keeping the exception's
original location and frames. `raise ... from ...` is an error.

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

The following failures end the program with exit status 1 and cannot be caught:
running out of stack space or memory, failing to write to stdout or stderr
through `print`, `sys.eprint`, or the final flush (§14), and failing to read
stdin through `input`. Writing to a closed pipe is one of these failures; it does
not deliver a signal to the program.

## 11. Built-in functions

| Function | Meaning |
| --- | --- |
| `print(value) -> None` | Write a printable value and `\n` to stdout |
| `input() -> str \| None` | The next line of stdin without its line ending, or `None` at end of input |
| `len`, `range`, `int`, `float`, `str`, `bytes`, `ord`, `chr`, `isinstance`, `sorted` | See §4, §6, §7, and §8 |

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

- `import name` loads the file `name.wlo`, and `import app.util` loads
  `app/util.wlo`, from the search roots described below. Each component of a
  module name is an identifier, and each import names one module. Directories
  serve only as namespaces, so importing `app.util` does not require or load a
  file named `app.wlo`.
- An import binds its first component as a name in the importing file's
  namespace (§9). Several imports may share the same first component, but that
  name cannot also be used for a function, class, or alias. A name cannot be
  both a module and a namespace, so importing both `app` and `app.util` is an
  error. A local variable with the same name hides the whole namespace.
- `module.name`, written with the module's full name, as in `app.util.name`,
  refers to a function, class, or alias declared in that module. It can be used
  in calls, constructors, annotations, `except` clauses, and `isinstance`.
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

When no source file is given, `willow check`, `willow run`,
`willow compile -o <output>`, and `willow build -o <output>` use the project in
the current directory, and `willow run -- <args>` passes `<args>` to the program.
If there is no `willow.json`, these commands report
`no source file given and no willow.json in the current directory`. When a
source file is given, the commands search only that file's directory and the
standard library, whether or not a `willow.json` exists. Programs run in the
current directory, and their file operations are relative to it. Compiled and
built output contains every module the program uses, from all roots.

### Tests

```python
# test_cart.wlo, next to cart.wlo
import cart

def test_empty_cart_totals_zero() -> None:
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
return `None`.

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

Each location includes the name of its file. Diagnostics are written to stderr.

## 14. Standard library

The standard library consists of modules that are included with Willow. They are
imported in the same way as a program's own modules (§12).

### `cli`

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

| Declaration | Meaning |
| --- | --- |
| `parser(prog: str, description: str = "") -> Parser` | A new parser for the program named `prog` |
| `class Parser` | A native type that declares arguments and parses them |
| `class Args` | A native type that holds the values from one parse |
| `class UsageError(Exception)` | Arguments that do not match the declarations |
| `class HelpRequested(Exception)` | `-h` or `--help` was given; the message is the help text |

| `Parser` method | Meaning |
| --- | --- |
| `add_str(name: str, default: str, help: str = "", short: str \| None = None, required: bool = False) -> None` | Declare a text option `--name VALUE` |
| `add_int(name: str, default: int, help: str = "", short: str \| None = None, required: bool = False) -> None` | Declare an integer option |
| `add_float(name: str, default: float, help: str = "", short: str \| None = None, required: bool = False) -> None` | Declare a number option |
| `add_flag(name: str, help: str = "", short: str \| None = None) -> None` | Declare an option that takes no value and is false unless given |
| `add_positional(name: str, help: str = "") -> None` | Declare a required positional argument |
| `add_rest(name: str, help: str = "") -> None` | Declare zero or more remaining positional arguments |
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
| `write_file(path: str, text: str) -> None` | Create the file, or replace its contents, with `text` |
| `join(a: str, b: str) -> str` | `a` and `b` joined with `/`; if `b` is absolute, the result is `b` |
| `basename(path: str) -> str` | The text after the last `/`, or empty if the path ends with `/` |
| `dirname(path: str) -> str` | The text before the last `/`, or empty if there is no `/` |
| `listdir(path: str) -> list[str]` | The names of the entries in the directory, excluding `.` and `..`, sorted by code point |
| `stat(path: str, follow_symlinks: bool = True) -> Stat` | Metadata for the file |
| `exists(path: str) -> bool` | Whether the path exists, following symlinks |
| `mkdir(path: str, parents: bool = False, exist_ok: bool = False) -> None` | Create a directory |
| `remove(path: str) -> None` | Remove a file or symlink |
| `rmdir(path: str) -> None` | Remove an empty directory |
| `rename(source: str, destination: str) -> None` | Rename a file or directory, replacing the destination where POSIX allows it |
| `class Stat` | A class with the fields `kind: str`, `size: int`, and `modified: float` |

Paths are strings. A relative path is relative to the working directory.
`read_file` and `write_file` read and write text exactly as it is, without
translating line endings. `write_file` does not replace the file atomically.

`join`, `basename`, and `dirname` operate only on the text of the path, in the
same way as Python's `posixpath`. They do not access the filesystem, follow
symlinks, or resolve `..`. For example, `join("a", "")` is `a/`, `join("", "b")`
is `b`, and a leading sequence of slashes is kept together, so `dirname("//a")`
is `//`.

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
`cannot write <path>: <reason>`, `cannot list <path>: <reason>`, and
`cannot remove directory <path>: <reason>`.

### `http`

```python
import http
import json

def main() -> None:
    response = http.request("GET", "https://example.com/api/items?" + http.urlencode({"q": "tea"}))
    if response.status == 200:
        items = json.parse(response.body.decode())
    body = json.dump({"name": "tea"}).encode()
    headers = [http.Header("Content-Type", "application/json")]
    created = http.request("POST", "https://example.com/api/items", headers=headers, body=body)
    print(created.status)
```

| Declaration | Meaning |
| --- | --- |
| `request(method: str, url: str, headers: list[Header] \| None = None, body: bytes \| None = None, timeout: float = 30.0, follow_redirects: bool = True, ca_file: str \| None = None) -> Response` | Make a request and read the whole response |
| `download(url: str, path: str, headers: list[Header] \| None = None, timeout: float = 30.0, follow_redirects: bool = True, ca_file: str \| None = None) -> Download` | Send a `GET` request and save the response body to the file at `path` |
| `header(headers: list[Header], name: str) -> str \| None` | The value of the first header named `name`, compared case-insensitively, or `None` |
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
| `open(path: str, mode: str = "r") -> File` | Open a file for reading (`r`), for writing after creating or truncating it (`w`), or for appending after creating it if needed (`a`) |
| `stdin() -> File` | A handle for standard input, open for reading |
| `stdout() -> File` | A handle for standard output, open for writing |
| `stderr() -> File` | A handle for standard error, open for writing |
| `class File` | A native type with the methods below |

| `File` method | Meaning |
| --- | --- |
| `read(size: int) -> bytes` | Read up to `size` octets; the result is empty only at end of input |
| `readline() -> str \| None` | Read the next line the same way `input` does, or return `None` at end of input |
| `write(data: bytes) -> None` | Write all of `data` |
| `write_text(text: str) -> None` | Write the UTF-8 encoding of `text`, without adding a newline |
| `flush() -> None` | Write any buffered data |
| `close() -> None` | Flush and close the file |

A native type is a library class that has methods and no fields. Its values can
only be created by functions in its module. A native type can be used in
annotations, aliases, unions, and `isinstance`, and its values can be stored and
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
programs should close such files in a `try`/`finally` statement.

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
| `class JsonError(Exception)` | Invalid JSON text, or a value that `dump` cannot encode |
| `parse(text: str) -> Json` | The value represented by the JSON text `text` |
| `dump(value: Json) -> str` | The JSON text for `value` |

`parse` accepts JSON as defined by RFC 8259. A number with no fraction or
exponent that is within the `int` range becomes an `int`. Any other number
becomes the nearest `float`. If an object contains the same key more than once,
the entry keeps the position of the first occurrence and the value of the last.
Text that is not valid JSON, including an escape for an unpaired surrogate,
raises `JsonError` with a message that describes the problem and gives its line
and column.

`dump` writes no whitespace and keeps the order of dictionary entries. Floats are
written the same way `str` writes them, so `2.0` is parsed back as a `float`.
Strings escape `"`, `\`, and control characters. Control characters use `\b`,
`\f`, `\n`, `\r`, and `\t` where those escapes exist and `\u00XX` otherwise. All
other characters are written unchanged. NaN and infinities raise `JsonError` with
the message `cannot encode <value>`, as in `cannot encode inf`.

### `net`

```python
import net

def main() -> None:
    listener = net.listen("127.0.0.1", 0)
    client = net.connect("127.0.0.1", listener.local_port())
    server = listener.accept(timeout=5.0)
    client.sendall("ping\n".encode())
    print(server.recv(1024).decode())       # ping
    client.close()
    server.close()
    listener.close()
```

| Declaration | Meaning |
| --- | --- |
| `connect(host: str, port: int, timeout: float \| None = 30.0) -> Connection` | Open a TCP connection |
| `listen(host: str, port: int, backlog: int = 16) -> Listener` | Listen for TCP connections on `host` |
| `class Connection` | A native type with the methods below |
| `class Listener` | A native type with the methods below |

| Method | Meaning |
| --- | --- |
| `Connection.recv(size: int, timeout: float \| None = None) -> bytes` | Return up to `size` bytes as soon as any arrive, or empty bytes when the peer has closed its side |
| `Connection.sendall(data: bytes, timeout: float \| None = None) -> None` | Send all of `data` |
| `Connection.close() -> None` | Close the connection |
| `Listener.accept(timeout: float \| None = None) -> Connection` | Wait for the next connection |
| `Listener.local_port() -> int` | The port the listener is bound to |
| `Listener.close() -> None` | Stop listening |

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

### `subprocess`

```python
import subprocess

def main() -> None:
    result = subprocess.run(["printf", "%s", "hello"], capture_output=True)
    output = result.stdout
    if output is not None:
        print(output.decode())          # hello
```

| Declaration | Meaning |
| --- | --- |
| `run(args: list[str], input: bytes \| None = None, capture_output: bool = False, cwd: str \| None = None, env: dict[str, str] \| None = None, timeout: float \| None = None) -> Result` | Run a command and wait for it to finish |
| `spawn(args: list[str], cwd: str \| None = None, env: dict[str, str] \| None = None, stdin: io.File \| None = None, stdout: io.File \| None = None, stderr: io.File \| None = None) -> Process` | Start a command and return without waiting for it |
| `class Result` | A class with the fields `returncode: int`, `stdout: bytes \| None`, and `stderr: bytes \| None` |
| `class Process` | A native type with the methods below |

| `Process` method | Meaning |
| --- | --- |
| `poll() -> int \| None` | The exit status if the child has exited, otherwise `None` |
| `wait(timeout: float \| None = None) -> int` | Wait for the child to exit and return its status |
| `terminate() -> None` | Send `SIGTERM` to the child |
| `kill() -> None` | Send `SIGKILL` to the child |

`args` contains the program followed by its arguments. They are passed to the
program directly, without a shell. A program name that contains `/` is treated as
a path. Any other program name is searched for in the `PATH` of the child's
environment, or in `/usr/bin:/bin` if that environment has no `PATH`. `cwd` sets
the child's working directory and `env` replaces its environment. When either is
`None`, the child inherits the parent's. A process's status is its exit code, or
the negative of the signal number if a signal ended it. A nonzero status is
returned normally and does not raise an exception.

When `run` is given `input`, it writes the input to the child's stdin and then
closes it. Empty input gives the child an immediate end of input. If the child
does not read all of the input, the rest is discarded without an error. Without
`input`, the child inherits stdin. With `capture_output`, `run` collects the
child's stdout and stderr as bytes while it writes the input, so full pipes
cannot deadlock. Without `capture_output`, the child inherits stdout and
stderr, and both fields of the result are `None`. Captured output is held in
memory. `run` returns as soon as the child exits, even if processes started by
the child are still running.

`timeout` limits how long `run` waits, starting when the child starts. When the
time limit expires, `run` kills the child, waits for it to exit, and raises
`TimeoutError` with the message `command timed out after <timeout> seconds`.
Processes started by the child are not killed.

`spawn` connects the child's standard streams to the given `io.File` handles.
The `stdin` handle must be open for reading, and the `stdout` and `stderr`
handles must be open for writing. When a handle is `None`, the child inherits
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
| `args() -> list[str]` | A new list of the program's arguments in order, not including the program or source file name |
| `eprint(value) -> None` | Write a printable value and `\n` to stderr |
| `exit(status: int) -> None` | End the program with exit status `status` |
| `getenv(name: str) -> str \| None` | The value of the environment variable `name`, or `None` if it is not set |
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
| `style(text: str, color: str = "default", bold: bool = False, enabled: bool = True) -> str` | `text` wrapped in ANSI escape sequences for the color and bold setting, or `text` unchanged when `enabled` is false |
| `progress(message: str) -> None` | Replace the progress line on stderr with `message` |
| `finish_progress(message: str = "") -> None` | Clear the progress line, then write `message` and a newline to stderr if `message` is not empty |

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
| `sleep(seconds: float) -> None` | Wait for at least `seconds` seconds |
| `utc(timestamp: float) -> str` | The UTC time `timestamp`, formatted as `YYYY-MM-DDTHH:MM:SSZ` |

`sleep` raises `ValueError` with the message
`sleep length must be finite and nonnegative` if the duration is negative or not
finite. `utc` rounds down to whole seconds and supports years 0001 through 9999.
Timestamps outside that range raise `ValueError` with the message
`timestamp out of range`.

## References

- Python documentation:
  [sequence operations](https://docs.python.org/3/library/stdtypes.html),
  [calls](https://docs.python.org/3/reference/expressions.html#calls),
  [format specifications](https://docs.python.org/3/library/string.html#format-specification-mini-language),
  [subprocesses](https://docs.python.org/3/library/subprocess.html), and
  [sockets](https://docs.python.org/3/library/socket.html)
- [Unicode 17.0](https://www.unicode.org/versions/Unicode17.0.0/), for case
  mappings
