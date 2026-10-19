-- Emits Lua text with an embedded source-location map from the lowered program.
local runtime = require("compiler.runtime")

local M = {}

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
  if value == 0 and 1 / value < 0 then
    return "-0.0"
  end
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

function M.emit(lowered)
  local lines = {}
  local map = {}
  local fn_name, fn_module
  local entry = lowered.modules[1]

  -- Source paths are numbered in order of first use.
  local paths, path_indexes = {}, {}
  local function path_index(path)
    if not path_indexes[path] then
      paths[#paths + 1] = path
      path_indexes[path] = #paths
    end
    return path_indexes[path]
  end

  -- Adds one output line; a span maps it back to Willow source.
  local function line(depth, text, span)
    lines[#lines + 1] = string.rep("  ", depth) .. text
    if span then
      map[#lines] = { span.line, span.col, path_index(span.path), fn_name }
    end
  end

  -- Functions of the entry module are locals. Every other module keeps its
  -- functions in a table, and so does the entry module when imported (including
  -- by itself), so that a caller's local cannot shadow a qualified call.
  -- Escaping `_` as `_1` and `.` as `_0` keeps distinct module names distinct,
  -- and no escaped name ends in `_`, so no mangled local can match one.
  local function escape(name)
    return (name:gsub("_", "_1"):gsub("%.", "_0"))
  end

  local function module_table(module)
    return "__wlo_module_" .. escape(module.name)
  end

  -- Each class with methods keeps them in its own table, which no Willow
  -- local can shadow.
  local function class_table(record)
    return "__wlo_class_" .. escape(record.type_name)
  end

  -- Each enum keeps its members in a table. A member is a table of its own,
  -- so it differs from strings and from members of other enums.
  local function enum_table(enum)
    return "__wlo_enum_" .. escape(enum.type_name)
  end

  local entry_imported = false
  for _, module in ipairs(lowered.modules) do
    for _, imported in pairs(module.imported) do
      if imported == entry then
        entry_imported = true
      end
    end
  end

  local function function_name(fn, qualified)
    if fn.class then
      return class_table(fn.class) .. "." .. M.mangle(fn.name)
    elseif fn.module == entry and fn_module == entry and not qualified then
      return M.mangle(fn.name)
    end
    return module_table(fn.module) .. "." .. M.mangle(fn.name)
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

  -- A conversion step from lowering: `float` first, then the tuple positions
  -- it converts, in order.
  local function step_text(step)
    local parts, last = {}, 0
    if step.float then
      parts[1] = "float = " .. M.quote(step.float)
    end
    for i in pairs(step) do
      if type(i) == "number" and i > last then
        last = i
      end
    end
    for i = 1, last do
      if step[i] then
        parts[#parts + 1] = "[" .. i .. "] = " .. step_text(step[i])
      end
    end
    return "{ " .. table.concat(parts, ", ") .. " }"
  end

  -- Nested binary operations are parenthesized so Lua precedence never matters.
  expr = function(e, nested)
    local kind = e.kind
    if kind == "Literal" then
      if type(e.value) == "number" then
        return number(e.value)
      elseif type(e.value) == "string" then
        return M.quote(e.value)
      elseif type(e.value) == "table" then
        return step_text(e.value)
      end
      return tostring(e.value)
    elseif kind == "Local" then
      return M.mangle(e.symbol.name)
    elseif kind == "Temp" then
      return "__wlo_t" .. e.index
    elseif kind == "TryValue" then
      return "__wlo_value" .. e.index
    elseif kind == "Not" then
      return "not " .. expr(e.operand, true)
    elseif kind == "Neg" then
      local text = "-" .. expr(e.operand, true)
      return nested and "(" .. text .. ")" or text
    elseif kind == "Binary" then
      local text = expr(e.left, true) .. " " .. binary_ops[e.op] .. " " .. expr(e.right, true)
      return nested and "(" .. text .. ")" or text
    elseif kind == "Call" then
      return function_name(e.target, e.qualified) .. "(" .. args(e.args) .. ")"
    elseif kind == "Helper" then
      return runtime.reference(e.name) .. "(" .. args(e.args, e.site) .. ")"
    elseif kind == "Pure" then
      return runtime.reference(e.name) .. "(" .. args(e.args) .. ")"
    elseif kind == "Item" then
      return "__wlo_item"
    elseif kind == "Str" then
      return (e.float and "__wlo_str_float(" or "__wlo_str(") .. expr(e.value) .. ")"
    elseif kind == "Concat" then
      local parts = {}
      for i, part in ipairs(e.parts) do
        parts[i] = expr(part, true)
      end
      local text = table.concat(parts, " .. ")
      return nested and "(" .. text .. ")" or text
    elseif kind == "EnumMember" then
      return enum_table(e.enum) .. "." .. M.mangle(e.name)
    elseif kind == "Field" then
      return expr(e.object) .. "." .. M.mangle(e.name)
    elseif kind == "Construct" then
      -- Exceptions carry their class in __wlo_class and other records in
      -- __wlo_record, so that `isinstance(e, Exception)` tests one field.
      local parts = { (e.exception and "__wlo_class = " or "__wlo_record = ") .. M.quote(e.class) }
      for i, name in ipairs(e.names) do
        parts[#parts + 1] = M.mangle(name) .. " = " .. expr(e.values[i])
      end
      return "{ " .. table.concat(parts, ", ") .. " }"
    elseif kind == "List" then
      return "__wlo_list(" .. table_text(e.elements) .. ", " .. #e.elements .. ")"
    elseif kind == "Dict" then
      return "__wlo_dict(" .. table_text(e.entries) .. ", " .. #e.entries / 2 .. ")"
    elseif kind == "Tuple" then
      local elements = #e.elements > 0 and ", " .. args(e.elements) or ""
      return "{ __wlo_tuple = " .. #e.elements .. elements .. " }"
    elseif kind == "Position" then
      return expr(e.object) .. "[" .. e.position .. "]"
    end
  end

  local block

  local function temp_locals(count, depth)
    local temps = {}
    for i = 1, count do
      temps[i] = "__wlo_t" .. i
    end
    if count > 0 then
      line(depth, "local " .. table.concat(temps, ", "))
    end
  end

  -- Emits a protected block as a closure passed to __wlo_try, which returns
  -- the block's departure code and value into the try's locals.
  local function protected(target, block_node, depth)
    line(depth, target .. " = __wlo_try(function()")
    temp_locals(block_node.temps, depth + 1)
    block(block_node.body, depth + 1)
    line(depth, "end)")
  end

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
    elseif kind == "Return" and s.exits then
      line(depth, 'return "return"' .. (s.value and ", " .. expr(s.value) or ""), s.span)
    elseif kind == "Return" then
      line(depth, s.value and "return " .. expr(s.value) or "return", s.span)
    elseif kind == "Break" then
      line(depth, s.exits and 'return "break"' or "break", s.span)
    elseif kind == "Continue" then
      line(depth, s.exits and 'return "continue"' or "goto __wlo_continue_" .. s.label, s.span)
    elseif kind == "Try" then
      local code, value = "__wlo_code" .. s.index, "__wlo_value" .. s.index
      line(depth, "do")
      protected("local " .. code .. ", " .. value, s.body, depth + 1)
      if #s.handlers > 0 then
        line(depth + 1, "if " .. code .. ' == "raise" then')
        for i, handler in ipairs(s.handlers) do
          if handler.class then
            local test = value .. ".__wlo_class == " .. M.quote(handler.class)
            line(depth + 2, (i == 1 and "if " or "elseif ") .. test .. " then")
          else
            line(depth + 2, i == 1 and "do" or "else")
          end
          if handler.target then
            line(depth + 3, expr(handler.target) .. " = " .. value)
          end
          protected(code .. ", " .. value, handler.body, depth + 3)
        end
        line(depth + 2, "end")
        line(depth + 1, "end")
      end
      if s.finally_body then
        block(s.finally_body, depth + 1)
      end
      line(depth + 1, "if " .. code .. ' == "raise" then')
      line(depth + 2, "__wlo_reraise(" .. value .. ")")
      line(depth + 1, "end")
      for _, resume in ipairs(s.resume) do
        line(depth + 1, "if " .. code .. " == " .. M.quote(resume.kind:lower()) .. " then")
        statement(resume, depth + 2)
        line(depth + 1, "end")
      end
      line(depth, "end")
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
      if s.target then
        line(depth + 1, expr(s.target) .. " = " .. expr(s.value), s.span)
      end
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
  line(0, "local __wlo_paths, __wlo_sites, __wlo_lines")
  for runtime_line in runtime.text(lowered.helpers):gmatch("([^\n]*)\n") do
    line(0, runtime_line)
  end
  if entry.tests then
    line(0, "local __wlo_test_open = io.open")
  end

  local names, classes = {}, {}
  for _, fn in ipairs(lowered.functions) do
    if fn.class then
      if not classes[fn.class] then
        classes[fn.class] = true
        classes[#classes + 1] = fn.class
      end
    elseif fn.module == entry then
      names[#names + 1] = M.mangle(fn.name)
    end
  end
  line(0, "")
  if #names > 0 then
    line(0, "local " .. table.concat(names, ", "))
  end
  for _, module in ipairs(lowered.modules) do
    if module ~= entry or entry_imported then
      line(0, "local " .. module_table(module) .. " = {}")
    end
  end
  for _, record in ipairs(classes) do
    line(0, "local " .. class_table(record) .. " = {}")
  end
  for _, module in ipairs(lowered.modules) do
    for _, enum in ipairs(module.enums) do
      line(0, "local " .. enum_table(enum) .. " = {")
      for _, member in ipairs(enum.members) do
        line(1, M.mangle(member.name) .. " = { __wlo_enum = " .. M.quote(enum.type_name)
          .. ", __wlo_text = " .. M.quote(enum.name .. "." .. member.name) .. " },")
      end
      line(0, "}")
    end
  end

  for _, fn in ipairs(lowered.functions) do
    fn_name, fn_module = fn.class and fn.class.name .. "." .. fn.name or fn.name, fn.module
    local params = {}
    for i, symbol in ipairs(fn.params) do
      params[i] = M.mangle(symbol.name)
    end
    line(0, "")
    line(0, "function " .. function_name(fn) .. "(" .. table.concat(params, ", ") .. ")", fn.span)
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
  if entry_imported then
    line(0, "")
    for _, fn in ipairs(lowered.functions) do
      if fn.module == entry and not fn.class then
        line(0, module_table(entry) .. "." .. M.mangle(fn.name) .. " = " .. M.mangle(fn.name))
      end
    end
  end
  line(0, "")
  line(0, "__wlo_sites = {")
  for _, span in ipairs(lowered.sites) do
    line(1, "{" .. span.line .. ", " .. span.col .. ", " .. path_index(span.path) .. "},")
  end
  line(0, "}")
  line(0, "__wlo_lines = {")
  for n = 1, mapped do
    local location = map[n]
    if location then
      line(1, "[" .. n .. "] = {" .. location[1] .. ", " .. location[2] .. ", " .. location[3] .. ", "
        .. M.quote(location[4]) .. "},")
    end
  end
  line(0, "}")
  local quoted = {}
  for i, path in ipairs(paths) do
    quoted[i] = M.quote(path)
  end
  line(0, "__wlo_paths = { " .. table.concat(quoted, ", ") .. " }")
  local tests = entry.tests
  if tests then
    -- A test chunk takes the test's name and a path to create once the test
    -- returns, which neither an exception nor sys.exit does.
    line(0, "local __wlo_tests = {")
    for _, fn in ipairs(tests) do
      line(1, "[" .. M.quote(fn.name) .. "] = " .. M.mangle(fn.name) .. ",")
    end
    line(0, "}")
    line(0, "local __wlo_name, __wlo_result = ...")
    line(0, "__wlo_run(__wlo_tests[__wlo_name])")
    line(0, 'assert(__wlo_test_open(__wlo_result, "wb")):close()')
  else
    -- The program arguments arrive as the chunk's varargs.
    line(0, "__wlo_run(" .. M.mangle("main") .. ", ...)")
  end
  return table.concat(lines, "\n") .. "\n"
end

return M
