local lexer = require("compiler.lexer")
local parser = require("compiler.parser")
local bind = require("compiler.bind")
local check = require("compiler.check")
local diag = require("compiler.diag")

local eq = require("tests.support").eq

local function check_source(statements)
  local program = parser.parse(lexer.lex("def main():\n" .. statements:gsub("[^\n]+", "    %0") .. "\n"))
  bind.bind({ program })
  check.check({ program })
  return program.functions[1].body
end

-- The first diagnostic of `statements`, as line:column: message, where line 1
-- is the first statement.
local function check_error(statements)
  local ok, err = pcall(check_source, statements)
  if ok then
    error("expected a check error", 2)
  end
  if not diag.is(err) then
    error(err, 0)
  end
  return string.format("%d:%d: %s", err[1].span.line - 1, err[1].span.col, err[1].message)
end

-- The type name of the last statement's value.
local function type_of(statements)
  local body = check_source(statements)
  return body[#body].value.type.name
end

return {
  result_types = function()
    eq("int", type_of("x = abs(-1)"))
    eq("float", type_of("x = abs(-1.5)"))
    eq("int", type_of("x = round(1.5)"))
    eq("tuple[int, str]", type_of("x = min((1, 'a'), (2, 'b'))"))
    eq("str", type_of("x = max(['a'])"))
    eq("float", type_of("x = sum([1.5])"))
    eq("bool", type_of("x = any([True])"))
    eq("list[str]", type_of("x = list('ab')"))
    eq("Iterator[tuple[int, str]]", type_of("x = enumerate(['a'], start=1)"))
    eq("Iterator[tuple[int, float]]", type_of("x = zip([1], [1.5])"))
    eq("Iterator[tuple[str, int]]", type_of("d = {'a': 1}\nx = d.items()"))
    eq("Iterator[str]", type_of("d = {'a': 1}\nx = d.keys()"))
    eq("Iterator[int]", type_of("d = {'a': 1}\nx = d.values()"))
    eq("None", type_of("x = [1]\ny = x.reverse()"))
  end,

  dictionary_get_defaults = function()
    eq("int | None", type_of("d = {'a': 1}\nx = d.get('a')"))
    eq("int", type_of("d = {'a': 1}\nx = d.get('a', 0)"))
    eq("int | None", type_of("d = {'a': 1}\nx = d.get('a', None)"))
    eq("int | None", type_of("d: dict[str, int | None] = {'a': 1}\nx = d.get('a', 0)"))
    eq("2:20: expected int | None, received str", check_error("d = {'a': 1}\nx = d.get('a', 'b')"))
  end,

  argument_errors = function()
    eq("1:9: 'abs' cannot be applied to str", check_error("x = abs('a')"))
    eq("1:15: expected float, received int", check_error("x = round(1)"))
    eq("1:9: 'min' cannot be applied to int and float", check_error("x = min(1, 2.0)"))
    eq("1:9: 'min' cannot be applied to list[bool]", check_error("x = min([True])"))
    eq("1:9: 'max' expects 1 to 2 arguments, received 3", check_error("x = max(1, 2, 3)"))
    eq("1:16: 'max' does not accept keyword arguments", check_error("x = max(1, key=2)"))
    eq("1:9: 'sum' cannot be applied to list[str]", check_error("x = sum(['a'])"))
    eq("1:9: 'all' cannot be applied to list[int]", check_error("x = all([1])"))
    eq("1:14: cannot iterate over int", check_error("x = list(3)"))
    eq("1:9: 'zip' expects 2 arguments, received 1", check_error("x = zip([1])"))
  end,

  extend_keeps_element_type = function()
    check_source("x = [1]\nx.extend([2])\nx.extend(x)\nx.extend((3, 4))")
    eq("2:15: expected int, received str", check_error("x = [1]\nx.extend(['a'])"))
    eq("2:14: cannot iterate over int", check_error("x = [1]\nx.extend(3)"))
    eq("3:14: expected Iterable[int | float], received list[float]",
      check_error("x: list[int | float] = [1]\ny = [1.5]\nx.extend(y)"))
  end,

  built_ins_as_callables = function()
    check_source("f: (float) -> float = abs\ng: (list[int]) -> int = sum\nh: (int, int) -> int = min")
    check_source("x = sorted([-2.5, 1.0], key=abs)")
    eq("1:23: 'abs' cannot be applied to str", check_error("f: (str) -> int = abs"))
    eq("1:25: expected float, received int", check_error("f: (int) -> float = abs"))
    eq("1:33: 'min' expects 1 to 2 arguments, received 3", check_error("f: (int, int, int) -> int = min"))
    eq("1:34: 'sum' expects 1 argument, received 2", check_error("f: (list[int], int) -> int = sum"))
  end,
}
