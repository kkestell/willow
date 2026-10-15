local lexer = require("compiler.lexer")
local parser = require("compiler.parser")
local bind = require("compiler.bind")
local check = require("compiler.check")
local lower = require("compiler.lower")

local function eq(expected, actual)
  if expected ~= actual then
    error(string.format("expected %q, got %q", tostring(expected), tostring(actual)), 2)
  end
end

local function lower_source(source)
  local program = parser.parse(lexer.lex(source))
  bind.bind(program)
  check.check(program)
  return lower.lower(program)
end

local show_expr, show_block

local function show_list(nodes, show, separator)
  local parts = {}
  for i, node in ipairs(nodes) do
    parts[i] = show(node)
  end
  return table.concat(parts, separator)
end

show_expr = function(e)
  local kind = e.kind
  if kind == "Literal" then
    if e.value == nil then
      return "None"
    elseif type(e.value) == "string" then
      return string.format("%q", e.value)
    elseif type(e.value) == "number" then
      return string.format(e.value == math.floor(e.value) and "%d" or "%.17g", e.value)
    end
    return tostring(e.value)
  elseif kind == "Local" then
    return e.symbol.name
  elseif kind == "Temp" then
    return "t" .. e.index
  elseif kind == "Not" then
    return "(not " .. show_expr(e.operand) .. ")"
  elseif kind == "Neg" then
    return "(-" .. show_expr(e.operand) .. ")"
  elseif kind == "Binary" then
    return "(" .. show_expr(e.left) .. " " .. e.op .. " " .. show_expr(e.right) .. ")"
  elseif kind == "Call" then
    return e.target.name .. "(" .. show_list(e.args, show_expr, ", ") .. ")"
  elseif kind == "Helper" then
    return e.name .. "(" .. show_list(e.args, show_expr, ", ") .. ")#" .. e.site
  end
  error("unknown expression kind " .. tostring(kind))
end

-- Prints statements joined by "; " and blocks in braces.
local function show_statement(s)
  local kind = s.kind
  if kind == "Set" then
    return show_expr(s.target) .. " = " .. show_expr(s.value)
  elseif kind == "Eval" then
    return show_expr(s.value)
  elseif kind == "Return" then
    return s.value and "return " .. show_expr(s.value) or "return"
  elseif kind == "If" then
    return "if " .. show_expr(s.condition) .. " " .. show_block(s.body)
      .. (s.else_body and " else " .. show_block(s.else_body) or "")
  elseif kind == "While" then
    return "while#" .. s.label .. " " .. show_block(s.setup) .. " " .. show_expr(s.condition) .. " " .. show_block(s.body)
  elseif kind == "Break" then
    return "break"
  elseif kind == "Continue" then
    return "continue#" .. s.label
  end
  error("unknown statement kind " .. tostring(kind))
end

show_block = function(body)
  if #body == 0 then
    return "{}"
  end
  return "{ " .. show_list(body, show_statement, "; ") .. " }"
end

local function show_body(fn)
  return show_list(fn.body, show_statement, "; ")
end

-- Lowers `main` with the statements indented in, followed by any helpers.
local function lower_main(statements, helpers)
  local source = "def main() -> None:\n" .. statements:gsub("[^\n]+", "    %0") .. "\n" .. (helpers or "")
  return show_body(lower_source(source).functions[1])
end

local MAIN = "def main() -> None:\n    pass\n"
local INT_HELPERS = "def f(n: int) -> int:\n    return n\ndef g(n: int) -> int:\n    return n\n"
local BOOL_HELPERS = "def f(n: int) -> bool:\n    return True\ndef g(n: int) -> bool:\n    return False\n"

return {
  operands_left_to_right_in_temporaries = function()
    eq("t1 = f(1); t2 = g(2); x = add(t1, t2)#1", lower_main("x = f(1) + g(2)", INT_HELPERS))
  end,

  temporaries_are_recycled = function()
    local lowered = lower_source("def main() -> None:\n    x = f(f(f(1)))\n" .. INT_HELPERS)
    eq("t1 = f(1); t1 = f(t1); x = f(t1)", show_body(lowered.functions[1]))
    eq(1, lowered.functions[1].temps)
    lowered = lower_source("def main() -> None:\n    x = f(1) + f(2) + f(3)\n" .. INT_HELPERS)
    eq("t1 = f(1); t2 = f(2); t1 = add(t1, t2)#1; t2 = f(3); x = add(t1, t2)#2", show_body(lowered.functions[1]))
    eq(2, lowered.functions[1].temps)
  end,

  pure_operands_stay_inline = function()
    eq('a = 1; b = 2; c = "st"; x = ((not (a < b)) and (c == ("s" concat "t")))',
      lower_main("a = 1\nb = 2\nc = 'st'\nx = not (a < b) and c == 's' + 't'"))
  end,

  short_circuit_branches = function()
    eq("a = true; t1 = a; if t1 { t1 = f(1) }; x = t1", lower_main("a = True\nx = a and f(1)", BOOL_HELPERS))
    eq("t1 = f(1); if (not t1) { t1 = g(2) }; x = t1", lower_main("x = f(1) or g(2)", BOOL_HELPERS))
  end,

  integer_helpers_carry_sites = function()
    local lowered = lower_source("def main() -> None:\n    a = 1\n    b = 2\n    x = -a * (b - 1)\n    y = +a\n")
    eq("a = 1; b = 2; t1 = neg(a)#1; t2 = sub(b, 1)#2; x = mul(t1, t2)#3; y = a", show_body(lowered.functions[1]))
    eq(3, #lowered.sites)
    eq("4:9", lowered.sites[1].line .. ":" .. lowered.sites[1].col)
    eq("4:17", lowered.sites[2].line .. ":" .. lowered.sites[2].col)
    eq("4:12", lowered.sites[3].line .. ":" .. lowered.sites[3].col)
  end,

  string_plus_is_concat = function()
    local lowered = lower_source("def main() -> None:\n    s = 'a'\n    x = s + '!'\n")
    eq('s = "a"; x = (s concat "!")', show_body(lowered.functions[1]))
    eq(0, #lowered.sites)
  end,

  returns_never_return_calls = function()
    local lowered = lower_source(table.concat({
      "def h(a: int) -> int:",
      "    if a > 0:",
      "        return f(1)",
      "    if a < 0:",
      "        return a + 1",
      "    return a",
      "def k() -> None:",
      "    return",
    }, "\n") .. "\n" .. MAIN .. INT_HELPERS)
    eq("if (a > 0) { t1 = f(1); return t1 }; if (a < 0) { t1 = add(a, 1)#1; return t1 }; return a",
      show_body(lowered.functions[1]))
    eq("return", show_body(lowered.functions[2]))
  end,

  print_is_a_helper = function()
    eq("t1 = f(1); print(t1)#1", lower_main("print(f(1))", INT_HELPERS))
  end,

  float_operations = function()
    eq("a = 1.5; x = ((a + (-a)) - 0.5); t1 = float_mul(a, 2)#1; y = (x < t1)",
      lower_main("a = 1.5\nx = a + -a - 0.5\ny = x < a * 2.0"))
    eq("x = div(7, 2)#1; t1 = floordiv(1.5, 0.5)#2; t2 = mod(1.5, 0.5)#3; y = (t1 + t2)",
      lower_main("x = 7 / 2\ny = 1.5 // 0.5 + 1.5 % 0.5"))
    eq("t1 = int_floordiv(7, 2)#1; t2 = int_mod(7, 2)#2; x = add(t1, t2)#3", lower_main("x = 7 // 2 + 7 % 2"))
  end,

  conversions = function()
    eq("x = f(1); y = int(1.5)#1", lower_main("x = float(f(1))\ny = int(1.5)", INT_HELPERS))
    eq("f(1)", lower_main("float(f(1))", INT_HELPERS))
    eq("print_float(1)#1; print(1)#2", lower_main("print(float(1))\nprint(1)"))
  end,

  loops_and_transfers = function()
    local source = table.concat({
      "def main() -> None:",
      "    i = 0",
      "    while f(i) < 10:",
      "        i = i + 1",
      "        if i == 5:",
      "            continue",
      "        while True:",
      "            break",
      "        break",
    }, "\n") .. "\n" .. INT_HELPERS
    local body = lower_source(source).functions[1].body
    eq("i = 0; while#1 { t1 = f(i) } (t1 < 10) { i = add(i, 1)#1; if (i == 5) { continue#1 }; "
      .. "while#2 {} true { break }; break }", show_list(body, show_statement, "; "))
    eq(true, body[2].continues)
    eq(nil, body[2].body[3].continues)
  end,

  elif_setup_stays_in_else = function()
    eq("t1 = f(1); if t1 {} else { t1 = f(2); if t1 {} }",
      lower_main("if f(1):\n    pass\nelif f(2):\n    pass", BOOL_HELPERS))
  end,

  program_shape = function()
    local lowered = lower_source(table.concat({
      "def f(n: int) -> int:",
      "    m = n * 2",
      "    return m",
      "def main() -> None:",
      "    k = f(1) + 1",
      "    print(k)",
    }, "\n"))
    local f, main = lowered.functions[1], lowered.functions[2]
    eq("f", f.name)
    eq("n", f.params[1].name)
    eq(1, #f.locals)
    eq("m", f.locals[1].name)
    eq(0, f.temps)
    eq("m = mul(n, 2)#1; return m", show_body(f))
    eq("t1 = f(1); k = add(t1, 1)#2; print(k)#3", show_body(main))
    eq(1, main.temps)
    eq(2, lowered.sites[1].line)
    eq(5, lowered.sites[2].line)
  end,
}
