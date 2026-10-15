-- Emits Lua text with an embedded source-location map from the lowered program.
local M = {}

local function read_runtime()
  local file = assert(io.open(assert(package.searchpath("runtime.core", package.path)), "rb"))
  local text = file:read("*a")
  file:close()
  return text
end

local runtime = read_runtime()

local lua_keywords = {}
for word in ([[
and break do else elseif end false for function goto if in local nil not or
repeat return then true until while
]]):gmatch("%S+") do
  lua_keywords[word] = true
end

local binary_ops = {
  ["=="] = "==",
  ["!="] = "~=",
  ["<"] = "<",
  ["<="] = "<=",
  [">"] = ">",
  [">="] = ">=",
  ["+"] = "+",
  ["-"] = "-",
  ["*"] = "*",
  ["and"] = "and",
  ["or"] = "or",
  concat = "..",
}

local escapes = { ["\\"] = "\\\\", ['"'] = '\\"', ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }

-- Returns a double-quoted Lua literal for `s`. Other control bytes use three
-- digits so a following digit cannot extend the escape; bytes from 128 up pass
-- through, so UTF-8 text stays readable.
function M.quote(s)
  return '"' .. s:gsub('[%c"\\]', function(c)
    return escapes[c] or string.format("\\%03d", c:byte())
  end) .. '"'
end

-- Appends "_" to names Lua cannot use or that could collide. Every changed
-- name ends in "_" and no unchanged one does, so the mapping is one-to-one, and
-- no internal __wlo_ name ends in "_".
function M.mangle(name)
  if lua_keywords[name] or name:sub(-1) == "_" or name:sub(1, 6) == "__wlo_" then
    return name .. "_"
  end
  return name
end

-- Integers print as integers; other numbers use the fewest significant digits
-- that read back as the same value.
local function number(value)
  if value == math.floor(value) and math.abs(value) <= 9007199254740991 then
    return string.format("%d", value)
  end
  for precision = 1, 17 do
    local text = string.format("%." .. precision .. "g", value)
    if tonumber(text) == value then
      return text
    end
  end
end

function M.emit(lowered, path)
  local lines = {}
  local map = {}
  local fn_name

  -- Adds one output line; a span maps it back to Willow source.
  local function line(depth, text, span)
    lines[#lines + 1] = string.rep("  ", depth) .. text
    if span then
      map[#lines] = { span.line, span.col, fn_name }
    end
  end

  local expr

  local function args(list, extra)
    local parts = {}
    for i, arg in ipairs(list) do
      parts[i] = expr(arg)
    end
    parts[#parts + 1] = extra
    return table.concat(parts, ", ")
  end

  local function table_text(list)
    return #list == 0 and "{}" or "{ " .. args(list) .. " }"
  end

  -- Nested binary operations are parenthesized so Lua precedence never matters.
  expr = function(e, nested)
    local kind = e.kind
    if kind == "Literal" then
      if type(e.value) == "number" then
        return number(e.value)
      elseif type(e.value) == "string" then
        return M.quote(e.value)
      end
      return tostring(e.value)
    elseif kind == "Local" then
      return M.mangle(e.symbol.name)
    elseif kind == "Temp" then
      return "__wlo_t" .. e.index
    elseif kind == "Not" then
      return "not " .. expr(e.operand, true)
    elseif kind == "Neg" then
      local text = "-" .. expr(e.operand, true)
      return nested and "(" .. text .. ")" or text
    elseif kind == "Binary" then
      local text = expr(e.left, true) .. " " .. binary_ops[e.op] .. " " .. expr(e.right, true)
      return nested and "(" .. text .. ")" or text
    elseif kind == "Call" then
      return M.mangle(e.target.name) .. "(" .. args(e.args) .. ")"
    elseif kind == "Helper" then
      return "__wlo_" .. e.name .. "(" .. args(e.args, e.site) .. ")"
    elseif kind == "Str" then
      return (e.float and "__wlo_str_float(" or "__wlo_str(") .. expr(e.value) .. ")"
    elseif kind == "Concat" then
      local parts = {}
      for i, part in ipairs(e.parts) do
        parts[i] = expr(part, true)
      end
      local text = table.concat(parts, " .. ")
      return nested and "(" .. text .. ")" or text
    elseif kind == "Field" then
      return expr(e.object) .. "." .. M.mangle(e.name)
    elseif kind == "Construct" then
      local parts = {}
      for i, name in ipairs(e.names) do
        parts[i] = M.mangle(name) .. " = " .. expr(e.values[i])
      end
      return "{ " .. table.concat(parts, ", ") .. " }"
    elseif kind == "List" then
      return "__wlo_list(" .. table_text(e.elements) .. ", " .. #e.elements .. ")"
    elseif kind == "Dict" then
      return "__wlo_dict(" .. table_text(e.entries) .. ", " .. #e.entries / 2 .. ")"
    end
  end

  local block

  local function loop_body(s, depth)
    if s.continues then
      -- The body may end in return or break, which Lua requires to close a
      -- block, so it gets its own block ahead of the continue label.
      line(depth, "do")
      block(s.body, depth + 1)
      line(depth, "end")
      line(depth, "::__wlo_continue_" .. s.label .. "::")
    else
      block(s.body, depth)
    end
  end

  local function statement(s, depth)
    local kind = s.kind
    if kind == "Set" then
      line(depth, expr(s.target) .. " = " .. expr(s.value), s.span)
    elseif kind == "Eval" then
      line(depth, expr(s.value), s.span)
    elseif kind == "Return" then
      line(depth, s.value and "return " .. expr(s.value) or "return", s.span)
    elseif kind == "Break" then
      line(depth, "break", s.span)
    elseif kind == "Continue" then
      line(depth, "goto __wlo_continue_" .. s.label, s.span)
    elseif kind == "If" then
      line(depth, "if " .. expr(s.condition) .. " then", s.span)
      block(s.body, depth + 1)
      local else_body = s.else_body
      while else_body and #else_body == 1 and else_body[1].kind == "If" do
        local inner = else_body[1]
        line(depth, "elseif " .. expr(inner.condition) .. " then", inner.span)
        block(inner.body, depth + 1)
        else_body = inner.else_body
      end
      if else_body then
        line(depth, "else")
        block(else_body, depth + 1)
      end
      line(depth, "end")
    elseif kind == "While" then
      if #s.setup == 0 then
        line(depth, "while " .. expr(s.condition) .. " do", s.span)
      else
        line(depth, "while true do", s.span)
        block(s.setup, depth + 1)
        line(depth + 1, "if not " .. expr(s.condition, true) .. " then break end", s.span)
      end
      loop_body(s, depth + 1)
      line(depth, "end")
    elseif kind == "For" then
      line(depth, "for _, __wlo_item in " .. expr(s.iterator) .. " do", s.iterator.span)
      line(depth + 1, expr(s.target) .. " = __wlo_item", s.span)
      loop_body(s, depth + 1)
      line(depth, "end")
    end
  end

  block = function(body, depth)
    for _, s in ipairs(body) do
      statement(s, depth)
    end
  end

  line(0, "-- Generated by willow; requires LuaJIT 2.1.")
  line(0, "local __wlo_path = " .. M.quote(path))
  line(0, "local __wlo_sites, __wlo_lines")
  for text in runtime:gmatch("([^\n]*)\n") do
    line(0, text)
  end

  local names = {}
  for i, fn in ipairs(lowered.functions) do
    names[i] = M.mangle(fn.name)
  end
  line(0, "")
  line(0, "local " .. table.concat(names, ", "))

  for _, fn in ipairs(lowered.functions) do
    fn_name = fn.name
    local params = {}
    for i, symbol in ipairs(fn.params) do
      params[i] = M.mangle(symbol.name)
    end
    line(0, "")
    line(0, "function " .. M.mangle(fn.name) .. "(" .. table.concat(params, ", ") .. ")", fn.span)
    local locals = {}
    for _, symbol in ipairs(fn.locals) do
      locals[#locals + 1] = M.mangle(symbol.name)
    end
    for i = 1, fn.temps do
      locals[#locals + 1] = "__wlo_t" .. i
    end
    if #locals > 0 then
      line(1, "local " .. table.concat(locals, ", "), fn.span)
    end
    block(fn.body, 1)
    line(0, "end")
  end

  local mapped = #lines
  line(0, "")
  line(0, "__wlo_sites = {")
  for _, span in ipairs(lowered.sites) do
    line(1, "{" .. span.line .. ", " .. span.col .. "},")
  end
  line(0, "}")
  line(0, "__wlo_lines = {")
  for n = 1, mapped do
    local entry = map[n]
    if entry then
      line(1, "[" .. n .. "] = {" .. entry[1] .. ", " .. entry[2] .. ", " .. M.quote(entry[3]) .. "},")
    end
  end
  line(0, "}")
  line(0, "__wlo_run(" .. M.mangle("main") .. ")")
  return table.concat(lines, "\n") .. "\n"
end

return M
