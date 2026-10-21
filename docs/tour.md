# A Tour of Willow

Willow is a small programming language with Python-like syntax and a static type
system. The compiler checks your program before running it, catching type errors
such as passing a string to a function that expects an integer. You declare types
in function signatures; Willow can usually infer them for local variables.

Willow programs compile to Lua and run on LuaJIT. You can run them with the
`willow` command or build standalone executables.

This tour introduces Willow's main ideas through short examples, starting with a
complete program you can run and change. It assumes some programming experience.
The [language specification](spec.md) explains the details as you need them.

## Start with a function

Save this as `hello.wlo`:

```python
def greet(name: str, prefix: str = "Hello") -> str:
    return f"{prefix}, {name}!"

def main() -> None:
    print(greet("Willow"))
    print(greet("Ada", prefix="Welcome"))
```

After following the [setup instructions](../README.md#setup), run it from the
checkout with:

```sh
./willow run hello.wlo
```

It prints:

```text
Hello, Willow!
Welcome, Ada!
```

Every program starts in `main`. Files contain imports and declarations, with
executable statements inside functions. Four spaces introduce each indentation
level, and `#` starts a comment.

Function parameters and return values have explicit types. Here, `greet` takes
strings and returns a string, while `main` returns `None`. Default arguments and
keyword calls let a small function offer convenient variations. An f-string
inserts expressions into text with `{...}`.

## Types that stay out of the way

Inside a function, Willow usually learns a variable's type from its first
assignment:

```python
def total(numbers: list[int]) -> int:
    result = 0
    for number in numbers:
        result = result + number
    return result
```

`result` is an `int`, and `number` is an `int` because it comes from a
`list[int]`. You can update either variable with another integer. Assigning a
string to `result` would be a compile-time error.

Annotations help when the initial value alone doesn't say enough:

```python
names: list[str] = []
names.append("Ada")
names.append("Grace")
```

The same checking applies across function calls, return values, and module
boundaries. Willow checks every imported module before running any of the
program.

A few rules make the types predictable: conditions take `bool` values, so write
`if count > 0:`; numeric conversions are explicit, as in `float(count)`; and
integer arithmetic reports overflow. Ordinary `if`, `elif`, `else`, `while`, and
`for` statements provide the control flow.

## Text and collections

Willow has Unicode strings, mutable lists and dictionaries, and immutable tuples.
A small word counter brings several of them together:

```python
def main() -> None:
    counts: dict[str, int] = {}
    for word in "the cat and the hat".split(" "):
        previous = counts.get(word)
        if previous is None:
            counts[word] = 1
        else:
            counts[word] = previous + 1

    for word in sorted(counts):
        print(f"{word}: {counts[word]}")
```

Dictionaries keep insertion order, and iterating over one yields its keys.
`sorted` builds a sorted list from an iterable. Lists and strings support
zero-based indexing, negative indexes, and slices such as `items[1:4]`.
Iterating over a string yields Unicode code points as individual strings.

Tuples group a fixed number of values, each with its own type. They are useful
for returning several related results:

```python
def dimensions() -> tuple[int, int]:
    return (80, 24)

def main() -> None:
    width, height = dimensions()
    print(f"{width} columns, {height} rows")
```

For binary data, `bytes` is a separate type. Use `text.encode()` and
`data.decode()` to cross the UTF-8 text boundary explicitly.

## Make absence part of the type

The word counter's `counts.get(word)` returns an `int | None`: either a count
or the value `None` when the key is missing. This is an *optional type*. You can
use the same idea in your own functions:

```python
def find_name(names: list[str], prefix: str) -> str | None:
    for name in names:
        if name.startswith(prefix):
            return name
    return None

def main() -> None:
    name = find_name(["Ada", "Alan", "Grace"], "Gr")
    if name is None:
        print("Nobody found")
        return
    print(name.upper())
```

After the early return, Willow knows that `name` must be a string. This is
*narrowing*: control flow establishes which operations are valid. The caller
handles the possibility of absence, and the successful path can use the value
directly.

## Give your data a shape

A class declares its fields and methods. Willow supplies a constructor from the
fields, including any defaults:

```python
class Book:
    title: str
    pages: int
    finished: bool = False

    def label(self) -> str:
        return f"{self.title} ({self.pages} pages)"

    def finish(self) -> None:
        self.finished = True

def main() -> None:
    book = Book("A Field Guide", pages=120)
    book.finish()
    print(book.label())
```

Fields are mutable. Assigning a class value to another variable shares the
same object; lists and dictionaries are shared in the same way.

An `enum` expresses a closed set of choices:

```python
enum ReadingState:
    PLANNED
    READING
    FINISHED
```

You can use `ReadingState.READING` as a field value, a function argument, or a
dictionary key. Each enum is its own type.

When alternatives carry different data, combine classes with a union:

```python
class TextMessage:
    text: str

class ImageMessage:
    path: str
    caption: str

type Message = TextMessage | ImageMessage

def preview(message: Message) -> str:
    if isinstance(message, TextMessage):
        return message.text
    return f"{message.caption}: {message.path}"
```

`type` gives the union a name. The `isinstance` check narrows the first branch
to `TextMessage`; the remaining path has an `ImageMessage`. Each alternative
keeps its own fields and meaning.

## Pass behavior around

Functions are values: you can store them, pass them to other functions, and
return them. A callable type spells out the inputs and result:

```python
def threshold(minimum: int) -> (int) -> bool:
    return lambda score: score >= minimum

def main() -> None:
    passes = threshold(70)
    print(passes(85))    # True
    print(passes(60))    # False
```

The lambda captures `minimum`, so each call to `threshold` can create a
different test. Nested `def` functions let you write longer closures, and bound
methods such as `book.label` can also be passed around.

Callbacks fit naturally into collection operations. With a list of `Book`
values, you can write:

```python
by_length = sorted(books, key=lambda book: book.pages)
```

The expected callback type supplies the lambda parameter's type.

## Reuse code with generics and protocols

Type parameters let one definition work with different types while preserving
the relationship between its inputs and outputs:

```python
def singleton[T](value: T) -> list[T]:
    return [value]

class Box[T]:
    value: T

def main() -> None:
    numbers = singleton(42)          # list[int]
    words = singleton("Willow")     # list[str]
    box = Box[str]("a small gift")
    print(box.value)
```

Willow can infer type arguments from a call, or you can write them explicitly.
The generic body is checked using what its type parameters promise.

Protocols describe a shared capability through method signatures:

```python
protocol Labelled:
    def label(self) -> str

def print_label(item: Labelled) -> None:
    print(item.label())
```

The earlier `Book` class already satisfies `Labelled`. Any other class with a
compatible `label` method can be passed to `print_label`, without an inheritance
or registration step. Classes give data a distinct identity; protocols let code
work with the behavior it needs. Generics and protocols also combine: a bound
such as `[T: Labelled]` lets a generic function call `label` while retaining the
caller's concrete type.

## Produce values as you need them

A function containing `yield` is a generator. It produces one value at a time,
preserving its local state between steps:

```python
def countdown(start: int) -> Iterator[int]:
    current = start
    while current > 0:
        yield current
        current = current - 1

def main() -> None:
    for number in countdown(3):
        print(number)
```

Calling `countdown` creates an iterator. Its body starts when iteration asks for
the first value, and each `yield` suspends it until the next request. You can
process a stream of values without first building a list.

Iteration is based on the `Iterable[T]` and `Iterator[T]` protocols. Collections,
generators, files, and your own iterator classes can participate in the same
`for` loops.

## Keep cleanup close to the work

Use `with` to give a resource a clear lifetime:

```python
import io

def main() -> None:
    with io.open("notes.txt") as source:
        for line in source:
            print(line)
```

The file closes when control leaves the block, including through a `return` or
an exception. Your own classes can support `with` by providing `enter` and
`exit` methods.

Generators can own resources too. A generator annotated `Generator[T]` exposes
closing and context-manager methods. Using it in `with` ensures cleanup even
when a consumer breaks out of a loop early; a `for` loop alone leaves its
iterator open.

For recoverable failures, Willow has exceptions and `try`/`except`/`finally`:

```python
def main() -> None:
    try:
        count = int("several")
        print(count)
    except ValueError as error:
        print(f"Please enter a number: {error.message}")
```

You can define exception classes with additional fields, and use `finally` for
cleanup that must run as control leaves a `try` statement.

## Let waiting work overlap

Async functions use the same type annotations as ordinary functions. Calling
one creates a `Coroutine[T]`; awaiting it runs the computation and produces its
result. To run several computations concurrently, start them in a task group:

```python
import aio

async def message_after(text: str, seconds: float) -> str:
    await aio.sleep(seconds)
    return text

async def main() -> None:
    async with aio.task_group() as group:
        first = group.start(message_after("Hello", 0.2))
        second = group.start(message_after("Willow", 0.1))
    print(f"{first.result()}, {second.result()}!")
```

Both waits can make progress together. The group waits for its children before
leaving the block, so both results are ready afterward. If a child fails, the
group cancels the remaining children, waits for their cleanup, and propagates
the failure. This keeps concurrent work tied to a visible scope.

Tasks run cooperatively on one thread. Async socket operations in `aio` let
other tasks run while waiting for I/O; synchronous operations still block the
event loop. Directly awaiting two coroutines one after another runs them
sequentially. Task groups provide the concurrency.

## Put it together

Split a program into `.wlo` files and import their declarations by module name:

```python
import library.books

def main() -> None:
    book = library.books.Book("A Field Guide", 120)
    print(book.label())
```

Here, `library.books` names `library/books.wlo`. Larger programs can use a
`willow.json` project file to set their entry module, source root, local
dependency roots, and test directory.

The standard library provides practical building blocks: command-line parsing
with `cli`, files and directories with `io` and `fs`, structured data with
`json`, HTTP requests with `http`, TCP connections with `net` and `aio`, and
child processes with `subprocess`.

Tests are ordinary functions with assertions. Put this in `test_hello.wlo` next
to the first example's `hello.wlo`:

```python
import hello

def test_greeting() -> None:
    assert hello.greet("Ada") == "Hello, Ada!"
    assert hello.greet("Ada", prefix="Welcome") == "Welcome, Ada!"
```

Run it with `./willow test test_hello.wlo`. Async test functions work too. The
runner checks the tests and their imports, then runs each test in its own
process.

When you're ready to share a program, `./willow build hello.wlo -o hello`
creates a standalone executable. To see how Willow translates your program,
try `./willow compile hello.wlo -o hello.lua` and read the result.

For a next experiment, extend the word counter to read a file, turn the `Book`
class into a small reading-list tool, or write a server that handles connections
in a task group. The [feature examples](../examples/) offer small programs to
adapt, the [Rosetta Code examples](../examples/rosettacode/) show complete
algorithms, and the [specification](spec.md) explains the rules as you need them.
