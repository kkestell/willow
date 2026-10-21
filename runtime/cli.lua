-- Command-line parsers, inlined after runtime/core.lua into programs that use
-- them. A parser lists its entries in declaration order. The helpers are the
-- functions declared without `local`.

local __wlo_TYPE_NAMES = { str = "str", int = "int", float = "float", flag = "bool", positional = "str", rest = "list" }

function __wlo_cli_parser_new(prog, description, site)
  return { "cli.Parser", prog = prog, description = description, entries = {}, by_name = {}, by_short = {} }
end

local function __wlo_cli_add(parser, entry, site)
  local name, short = entry.name, entry.short
  if not name:match("^%a[%w]*$") and not name:match("^%a[%w]*%-[%w%-]*[%w]$") or name:find("--", 1, true) then
    __wlo_fail("ValueError", "invalid name '" .. name .. "'", site)
  elseif short and not short:match("^%a$") then
    __wlo_fail("ValueError", "invalid short option '" .. short .. "'", site)
  elseif name == "help" or short == "h" then
    __wlo_fail("ValueError", "'help' and 'h' are reserved", site)
  elseif parser.by_name[name] then
    __wlo_fail("ValueError", "duplicate name '" .. name .. "'", site)
  elseif short and parser.by_short[short] then
    __wlo_fail("ValueError", "duplicate short option '-" .. short .. "'", site)
  end
  if entry.kind == "positional" or entry.kind == "rest" then
    if parser.rest then
      __wlo_fail("ValueError", entry.kind == "rest" and "only one rest argument is allowed"
        or "positional '" .. name .. "' follows the rest argument", site)
    end
    parser.rest = entry.kind == "rest" and entry or nil
  end
  parser.entries[#parser.entries + 1] = entry
  parser.by_name[name] = entry
  if short then
    parser.by_short[short] = entry
  end
end

local function __wlo_cli_add_value(parser, kind, name, default, help, short, required, site)
  __wlo_cli_add(parser, { name = name, kind = kind, default = default, help = help, short = short, required = required }, site)
end

function __wlo_cli_parser_add_str(parser, name, default, help, short, required, site)
  __wlo_cli_add_value(parser, "str", name, default, help, short, required, site)
end

function __wlo_cli_parser_add_int(parser, name, default, help, short, required, site)
  __wlo_cli_add_value(parser, "int", name, default, help, short, required, site)
end

function __wlo_cli_parser_add_float(parser, name, default, help, short, required, site)
  __wlo_cli_add_value(parser, "float", name, default, help, short, required, site)
end

function __wlo_cli_parser_add_flag(parser, name, help, short, site)
  __wlo_cli_add(parser, { name = name, kind = "flag", default = false, help = help, short = short }, site)
end

function __wlo_cli_parser_add_positional(parser, name, help, site)
  __wlo_cli_add(parser, { name = name, kind = "positional", help = help }, site)
end

function __wlo_cli_parser_add_rest(parser, name, help, site)
  __wlo_cli_add(parser, { name = name, kind = "rest", help = help }, site)
end

local function __wlo_cli_is_option(entry)
  return entry.kind ~= "positional" and entry.kind ~= "rest"
end

local function __wlo_cli_usage(parser)
  local parts = { "usage: " .. parser.prog .. " [options]" }
  for _, entry in ipairs(parser.entries) do
    if entry.kind == "positional" then
      parts[#parts + 1] = entry.name
    elseif entry.kind == "rest" then
      parts[#parts + 1] = "[" .. entry.name .. " ...]"
    end
  end
  return table.concat(parts, " ")
end

local function __wlo_cli_metavar(entry)
  return (entry.name:upper():gsub("%-", "_"))
end

local function __wlo_cli_default_text(entry)
  if entry.kind == "float" then
    return __wlo_format_float(entry.default)
  elseif entry.kind == "int" then
    return string.format("%d", entry.default)
  end
  return entry.default
end

-- Formats `rows` of { left, help } with the help column aligned.
local function __wlo_cli_rows(lines, title, rows)
  local width = 0
  for _, row in ipairs(rows) do
    width = math.max(width, #row[1])
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = title
  for _, row in ipairs(rows) do
    local line = "  " .. row[1]
    if row[2] ~= "" then
      line = line .. (" "):rep(width - #row[1] + 2) .. row[2]
    end
    lines[#lines + 1] = line
  end
end

function __wlo_cli_parser_help(parser, site)
  local lines = { __wlo_cli_usage(parser) }
  if parser.description ~= "" then
    lines[#lines + 1] = ""
    lines[#lines + 1] = parser.description
  end
  local arguments, options = {}, { { "-h, --help", "show this help and exit" } }
  for _, entry in ipairs(parser.entries) do
    if entry.kind == "positional" then
      arguments[#arguments + 1] = { entry.name, entry.help }
    elseif entry.kind == "rest" then
      arguments[#arguments + 1] = { entry.name .. " ...", entry.help }
    else
      local left = (entry.short and "-" .. entry.short .. ", " or "") .. "--" .. entry.name
      local help = entry.help
      if entry.kind ~= "flag" then
        left = left .. " " .. __wlo_cli_metavar(entry)
        local note
        if entry.required then
          note = "(required)"
        elseif __wlo_cli_default_text(entry) ~= "" then
          note = "(default: " .. __wlo_cli_default_text(entry) .. ")"
        end
        if note then
          help = help == "" and note or help .. " " .. note
        end
      end
      options[#options + 1] = { left, help }
    end
  end
  if #arguments > 0 then
    __wlo_cli_rows(lines, "arguments:", arguments)
  end
  __wlo_cli_rows(lines, "options:", options)
  return table.concat(lines, "\n") .. "\n"
end

local function __wlo_cli_usage_error(parser, problem, site)
  __wlo_fail("cli.UsageError", __wlo_cli_usage(parser) .. "\n" .. parser.prog .. ": error: " .. problem, site)
end

-- Converts `text` for value option `entry`.
local function __wlo_cli_convert(parser, entry, text, site)
  if entry.kind == "str" then
    return text
  end
  local ok, value = pcall(entry.kind == "int" and __wlo_parse_int or __wlo_parse_float, text, site)
  if not ok then
    __wlo_cli_usage_error(parser, "option '--" .. entry.name .. "' expects "
      .. (entry.kind == "int" and "an integer" or "a number") .. ", received '" .. text .. "'", site)
  end
  return value
end

function __wlo_cli_parser_parse(parser, args, site)
  local values, seen, positionals = {}, {}, {}
  local options_done = false
  local i = 1
  while i <= args.n do
    local arg = args[i]
    i = i + 1
    if options_done or arg == "-" or arg:sub(1, 1) ~= "-" then
      positionals[#positionals + 1] = arg
    elseif arg == "--" then
      options_done = true
    elseif arg == "--help" or arg == "-h" then
      __wlo_fail("cli.HelpRequested", __wlo_cli_parser_help(parser, site), site)
    else
      local entry, value
      if arg:sub(1, 2) == "--" then
        local name, rest = arg:match("^%-%-([^=]*)=(.*)$")
        entry = parser.by_name[name or arg:sub(3)]
        value = rest
      elseif #arg == 2 then
        entry = parser.by_short[arg:sub(2)]
      end
      if not entry or not __wlo_cli_is_option(entry) then
        __wlo_cli_usage_error(parser, "unknown option '" .. arg .. "'", site)
      end
      if entry.kind == "flag" then
        if value then
          __wlo_cli_usage_error(parser, "option '--" .. entry.name .. "' takes no value", site)
        end
        values[entry.name] = true
      else
        if not value then
          if i > args.n then
            __wlo_cli_usage_error(parser, "option '--" .. entry.name .. "' needs a value", site)
          end
          value = args[i]
          i = i + 1
        end
        values[entry.name] = __wlo_cli_convert(parser, entry, value, site)
      end
      seen[entry.name] = true
    end
  end
  local next_positional = 1
  for _, entry in ipairs(parser.entries) do
    if entry.kind == "positional" then
      if not positionals[next_positional] then
        __wlo_cli_usage_error(parser, "missing argument '" .. entry.name .. "'", site)
      end
      values[entry.name] = positionals[next_positional]
      next_positional = next_positional + 1
    elseif entry.kind == "rest" then
      local rest = {}
      for k = next_positional, #positionals do
        rest[#rest + 1] = positionals[k]
      end
      values[entry.name] = rest
      next_positional = #positionals + 1
    elseif entry.required and not seen[entry.name] then
      __wlo_cli_usage_error(parser, "option '--" .. entry.name .. "' is required", site)
    elseif not seen[entry.name] then
      values[entry.name] = entry.default
    end
  end
  if positionals[next_positional] then
    __wlo_cli_usage_error(parser, "unexpected argument '" .. positionals[next_positional] .. "'", site)
  end
  local kinds = {}
  for _, entry in ipairs(parser.entries) do
    kinds[entry.name] = __wlo_TYPE_NAMES[entry.kind]
  end
  return { "cli.Args", values = values, kinds = kinds }
end

local function __wlo_cli_get(args, name, kind, site)
  local actual = args.kinds[name]
  if not actual then
    __wlo_fail("ValueError", "no argument named '" .. name .. "'", site)
  elseif actual ~= kind then
    local article = kind == "int" and "an " or "a "
    __wlo_fail("ValueError", "'" .. name .. "' is not " .. article .. kind .. " argument", site)
  end
  return args.values[name]
end

function __wlo_cli_args_get_str(args, name, site)
  return __wlo_cli_get(args, name, "str", site)
end

function __wlo_cli_args_get_int(args, name, site)
  return __wlo_cli_get(args, name, "int", site)
end

function __wlo_cli_args_get_float(args, name, site)
  return __wlo_cli_get(args, name, "float", site)
end

function __wlo_cli_args_get_bool(args, name, site)
  return __wlo_cli_get(args, name, "bool", site)
end

function __wlo_cli_args_get_list(args, name, site)
  local items = __wlo_cli_get(args, name, "list", site)
  local copy = {}
  for k, item in ipairs(items) do
    copy[k] = item
  end
  return __wlo_list(copy, #items)
end
