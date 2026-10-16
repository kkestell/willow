-- Resolves names and collects function signatures, annotating the tree in place.
local diag = require("compiler.diag")
local types = require("compiler.types")

local M = {}

-- The functions of `module` followed by the methods of its classes.
function M.functions(module)
  local result = {}
  for _, fn in ipairs(module.functions) do
    result[#result + 1] = fn
  end
  for _, record in ipairs(module.records) do
    for _, method in ipairs(record.methods) do
      result[#result + 1] = method
    end
  end
  return result
end

local optional_str = types.union({ types.str, types.None })
local optional_int = types.union({ types.int, types.None })
local optional_float = types.union({ types.float, types.None })
local optional_bytes = types.union({ types.bytes, types.None })

-- Gives each entry of `signatures`, keyed by function name, the fields of a
-- built-in function target. A signature's `params` holds the parameter types,
-- where "any" is checked separately by name. A built-in with `names` accepts
-- keyword arguments; `defaults` holds the literal nodes of its optional
-- parameters; `helper` names its runtime helper when that is not its name.
local function builtins_of(signatures)
  for name, signature in pairs(signatures) do
    signature.kind, signature.name = "Builtin", name
  end
  return signatures
end

-- range is checked only as a `for` iterable, and isinstance is its own node.
local builtins = builtins_of({
  print = { params = { "any" }, result = types.None },
  str = { params = { "any" }, result = types.str },
  int = { params = { "any" }, result = types.int },
  float = { params = { "any" }, result = types.float },
  len = { params = { "any" }, result = types.int },
  range = {},
  input = { params = {}, result = optional_str },
  ord = { params = { types.str }, result = types.int },
  chr = { params = { types.int }, result = types.str },
  isinstance = {},
  sorted = {
    params = { "any", types.bool },
    names = { "items", "reverse" },
    defaults = { [2] = { kind = "Bool", value = false } },
  },
  bytes = { params = { types.list(types.int) }, names = { "values" }, result = types.bytes },
})

-- An exception class: a record with only a `message` field.
local function exception(name, type_name)
  local record = {
    kind = "Record",
    name = name,
    type_name = type_name,
    exception = true,
    fields = { { name = "message", type = types.str } },
    methods = {},
  }
  record.type = types.record(record)
  return record
end

-- The built-in exception classes.
local exceptions = {}
M.exceptions = exceptions
for name in ("Exception AssertionError OverflowError ZeroDivisionError ValueError IndexError KeyError RuntimeError OSError TimeoutError"):gmatch("%S+") do
  exceptions[name] = exception(name, name)
end

-- An ordinary record of a provided module with `fields` as { name, type }.
local function provided_record(module, name, fields)
  local record = { kind = "Record", name = name, type_name = module .. "." .. name, fields = {}, methods = {} }
  for i, field in ipairs(fields) do
    record.fields[i] = { name = field[1], type = field[2] }
  end
  record.type = types.record(record)
  return record
end

-- A compiler-provided module. It has no source: its declarations are the
-- built-in targets for `functions`, keyed by name, and the records and aliases
-- in `records`. A program's own module of the same name shadows it.
local function provided(name, functions, records)
  local declarations = records or {}
  for function_name, target in pairs(builtins_of(functions)) do
    declarations[function_name] = target
  end
  return { name = name, declarations = declarations }
end

-- A native type is a provided record with no fields that only its module's
-- functions create. Its methods lower to helpers named after `prefix`.
local file = {
  kind = "Record",
  name = "File",
  type_name = "io.File",
  fields = {},
  native = true,
  prefix = "file",
  native_methods = {
    read = { params = { types.int }, names = { "size" }, result = types.bytes },
    readline = { params = {}, result = optional_str },
    write = { params = { types.bytes }, names = { "data" }, result = types.None },
    write_text = { params = { types.str }, names = { "text" }, result = types.None },
    flush = { params = {}, result = types.None },
    close = { params = {}, result = types.None },
  },
}
file.type = types.record(file)
local optional_file = types.union({ file.type, types.None })

local io = provided("io", {
  open = {
    params = { types.str, types.str },
    names = { "path", "mode" },
    defaults = { [2] = { kind = "String", value = "r" } },
    result = file.type,
  },
  stdin = { params = {}, result = file.type },
  stdout = { params = {}, result = file.type },
  stderr = { params = {}, result = file.type },
}, { File = file })

local sys = provided("sys", {
  args = { params = {}, result = types.list(types.str) },
  eprint = { params = { "any" }, result = types.None },
  exit = { params = { types.int }, names = { "status" }, result = types.None },
  getenv = { params = { types.str }, names = { "name" }, result = optional_str },
  environ = { params = {}, result = types.dict(types.str, types.str) },
  getcwd = { params = {}, result = types.str },
})

local stat = provided_record("fs", "Stat", { { "kind", types.str }, { "size", types.int }, { "modified", types.float } })
local fs = provided("fs", {
  read_file = { params = { types.str }, names = { "path" }, result = types.str },
  write_file = { params = { types.str, types.str }, names = { "path", "text" }, result = types.None },
  join = { params = { types.str, types.str }, names = { "a", "b" }, result = types.str },
  basename = { params = { types.str }, names = { "path" }, result = types.str },
  dirname = { params = { types.str }, names = { "path" }, result = types.str },
  listdir = { params = { types.str }, names = { "path" }, result = types.list(types.str) },
  stat = {
    params = { types.str, types.bool },
    names = { "path", "follow_symlinks" },
    defaults = { [2] = { kind = "Bool", value = true } },
    result = stat.type,
  },
  exists = { params = { types.str }, names = { "path" }, result = types.bool },
  mkdir = {
    params = { types.str, types.bool, types.bool },
    names = { "path", "parents", "exist_ok" },
    defaults = { [2] = { kind = "Bool", value = false }, [3] = { kind = "Bool", value = false } },
    result = types.None,
  },
  remove = { params = { types.str }, names = { "path" }, result = types.None },
  rmdir = { params = { types.str }, names = { "path" }, result = types.None },
  rename = { params = { types.str, types.str }, names = { "source", "destination" }, result = types.None },
}, { Stat = stat })

local time = provided("time", {
  time = { params = {}, result = types.float },
  monotonic = { params = {}, result = types.float },
  sleep = { params = { types.float }, names = { "seconds" }, result = types.None },
  utc = { params = { types.float }, names = { "timestamp" }, result = types.str },
})

local terminal = provided("terminal", {
  isatty = { params = { file.type }, names = { "file" }, result = types.bool },
  color_enabled = { params = { file.type }, names = { "file" }, result = types.bool },
  style = {
    params = { types.str, types.str, types.bool, types.bool },
    names = { "text", "color", "bold", "enabled" },
    defaults = {
      [2] = { kind = "String", value = "default" },
      [3] = { kind = "Bool", value = false },
      [4] = { kind = "Bool", value = true },
    },
    result = types.str,
  },
  progress = { params = { types.str }, names = { "message" }, result = types.None },
  finish_progress = {
    params = { types.str },
    names = { "message" },
    defaults = { [1] = { kind = "String", value = "" } },
    result = types.None,
  },
})

local result = provided_record("subprocess", "Result", {
  { "returncode", types.int }, { "stdout", optional_bytes }, { "stderr", optional_bytes },
})

local process = {
  kind = "Record",
  name = "Process",
  type_name = "subprocess.Process",
  fields = {},
  native = true,
  prefix = "process",
  native_methods = {
    poll = { params = {}, result = optional_int },
    wait = {
      params = { optional_float },
      names = { "timeout" },
      defaults = { { kind = "None" } },
      result = types.int,
    },
    terminate = { params = {}, result = types.None },
    kill = { params = {}, result = types.None },
  },
}
process.type = types.record(process)

local optional_env = types.union({ types.dict(types.str, types.str), types.None })
-- A runtime helper named `run` would replace the one that runs `main`.
local subprocess = provided("subprocess", {
  run = {
    params = { types.list(types.str), optional_bytes, types.bool, optional_str, optional_env, optional_float },
    names = { "args", "input", "capture_output", "cwd", "env", "timeout" },
    defaults = {
      [2] = { kind = "None" },
      [3] = { kind = "Bool", value = false },
      [4] = { kind = "None" },
      [5] = { kind = "None" },
      [6] = { kind = "None" },
    },
    result = result.type,
    helper = "process_run",
  },
  spawn = {
    params = { types.list(types.str), optional_str, optional_env, optional_file, optional_file, optional_file },
    names = { "args", "cwd", "env", "stdin", "stdout", "stderr" },
    defaults = {
      [2] = { kind = "None" },
      [3] = { kind = "None" },
      [4] = { kind = "None" },
      [5] = { kind = "None" },
      [6] = { kind = "None" },
    },
    result = process.type,
    helper = "process_spawn",
  },
}, { Result = result, Process = process })

local function value_option(kind)
  return {
    params = { types.str, kind, types.str, optional_str, types.bool },
    names = { "name", "default", "help", "short", "required" },
    defaults = { [3] = { kind = "String", value = "" }, [4] = { kind = "None" }, [5] = { kind = "Bool", value = false } },
    result = types.None,
  }
end
local function getter(kind)
  return { params = { types.str }, names = { "name" }, result = kind }
end

local args = {
  kind = "Record",
  name = "Args",
  type_name = "cli.Args",
  fields = {},
  native = true,
  prefix = "cli_args",
  native_methods = {
    get_str = getter(types.str),
    get_int = getter(types.int),
    get_float = getter(types.float),
    get_bool = getter(types.bool),
    get_list = getter(types.list(types.str)),
  },
}
args.type = types.record(args)

local described = {
  params = { types.str, types.str },
  names = { "name", "help" },
  defaults = { [2] = { kind = "String", value = "" } },
  result = types.None,
}
local parser = {
  kind = "Record",
  name = "Parser",
  type_name = "cli.Parser",
  fields = {},
  native = true,
  prefix = "cli_parser",
  native_methods = {
    add_str = value_option(types.str),
    add_int = value_option(types.int),
    add_float = value_option(types.float),
    add_flag = {
      params = { types.str, types.str, optional_str },
      names = { "name", "help", "short" },
      defaults = { [2] = { kind = "String", value = "" }, [3] = { kind = "None" } },
      result = types.None,
    },
    add_positional = described,
    add_rest = described,
    parse = { params = { types.list(types.str) }, names = { "args" }, result = args.type },
    help = { params = {}, result = types.str },
  },
}
parser.type = types.record(parser)

local cli = provided("cli", {
  parser = {
    params = { types.str, types.str },
    names = { "prog", "description" },
    defaults = { [2] = { kind = "String", value = "" } },
    result = parser.type,
    helper = "cli_parser_new",
  },
}, {
  Parser = parser,
  Args = args,
  UsageError = exception("UsageError", "cli.UsageError"),
  HelpRequested = exception("HelpRequested", "cli.HelpRequested"),
})

local header = provided_record("http", "Header", { { "name", types.str }, { "value", types.str } })
local headers = types.list(header.type)
local optional_headers = types.union({ headers, types.None })
local response = provided_record("http", "Response", {
  { "status", types.int }, { "headers", headers }, { "body", types.bytes }, { "url", types.str },
})
local download = provided_record("http", "Download", {
  { "status", types.int }, { "headers", headers }, { "url", types.str }, { "bytes_written", types.int },
})
local http = provided("http", {
  request = {
    params = { types.str, types.str, optional_headers, optional_bytes, types.float, types.bool, optional_str },
    names = { "method", "url", "headers", "body", "timeout", "follow_redirects", "ca_file" },
    defaults = {
      [3] = { kind = "None" },
      [4] = { kind = "None" },
      [5] = { kind = "Float", value = 30.0 },
      [6] = { kind = "Bool", value = true },
      [7] = { kind = "None" },
    },
    result = response.type,
    helper = "http_request",
  },
  download = {
    params = { types.str, types.str, optional_headers, types.float, types.bool, optional_str },
    names = { "url", "path", "headers", "timeout", "follow_redirects", "ca_file" },
    defaults = {
      [3] = { kind = "None" },
      [4] = { kind = "Float", value = 30.0 },
      [5] = { kind = "Bool", value = true },
      [6] = { kind = "None" },
    },
    result = download.type,
    helper = "http_download",
  },
  header = {
    params = { headers, types.str },
    names = { "headers", "name" },
    result = optional_str,
    helper = "http_header",
  },
  urlencode = {
    params = { types.dict(types.str, types.str) },
    names = { "values" },
    result = types.str,
    helper = "http_urlencode",
  },
}, { Header = header, Response = response, Download = download })

-- `type Json = None | bool | int | float | str | list[Json] | dict[str, Json]`,
-- built as bind builds a recursive alias.
local json_value = { kind = "union", name = "json.Json" }
local json_element = { kind = "lazy", name = "json.Json", type = json_value }
json_value.members = {
  types.None, types.bool, types.int, types.float, types.str,
  types.list(json_element), types.dict(types.str, json_element),
}
local json = provided("json", {
  parse = { params = { types.str }, names = { "text" }, result = json_value, helper = "json_parse" },
  dump = { params = { json_value }, names = { "value" }, result = types.str, helper = "json_dump" },
}, {
  Json = { kind = "Alias", name = "Json", type_name = "json.Json", type = json_value },
  JsonError = exception("JsonError", "json.JsonError"),
})

local connection = {
  kind = "Record",
  name = "Connection",
  type_name = "net.Connection",
  fields = {},
  native = true,
  prefix = "net_connection",
  native_methods = {
    recv = {
      params = { types.int, optional_float },
      names = { "size", "timeout" },
      defaults = { [2] = { kind = "None" } },
      result = types.bytes,
    },
    sendall = {
      params = { types.bytes, optional_float },
      names = { "data", "timeout" },
      defaults = { [2] = { kind = "None" } },
      result = types.None,
    },
    close = { params = {}, result = types.None },
  },
}
connection.type = types.record(connection)
local listener = {
  kind = "Record",
  name = "Listener",
  type_name = "net.Listener",
  fields = {},
  native = true,
  prefix = "net_listener",
  native_methods = {
    accept = {
      params = { optional_float },
      names = { "timeout" },
      defaults = { { kind = "None" } },
      result = connection.type,
    },
    local_port = { params = {}, result = types.int },
    close = { params = {}, result = types.None },
  },
}
listener.type = types.record(listener)
local net = provided("net", {
  connect = {
    params = { types.str, types.int, optional_float },
    names = { "host", "port", "timeout" },
    defaults = { [3] = { kind = "Float", value = 30.0 } },
    result = connection.type,
    helper = "net_connect",
  },
  listen = {
    params = { types.str, types.int, types.int },
    names = { "host", "port", "backlog" },
    defaults = { [3] = { kind = "Int", value = 16 } },
    result = listener.type,
    helper = "net_listen",
  },
}, { Connection = connection, Listener = listener })

M.modules = {
  cli = cli,
  fs = fs,
  http = http,
  io = io,
  json = json,
  net = net,
  subprocess = subprocess,
  sys = sys,
  terminal = terminal,
  time = time,
}

-- Gives the function one symbol per parameter and per assigned or loop name,
-- recording non-parameter symbols in `fn.locals` in order of first assignment.
local function collect_symbols(fn)
  local scope = {}
  for _, param in ipairs(fn.params) do
    param.symbol = { name = param.name, span = param.span, param = true }
    scope[param.name] = param.symbol
  end

  fn.locals = {}
  local function walk(body)
    for _, statement in ipairs(body) do
      local kind = statement.kind
      if (kind == "Assign" or kind == "For") and not scope[statement.name] then
        local symbol = { name = statement.name, span = statement.span }
        scope[statement.name] = symbol
        fn.locals[#fn.locals + 1] = symbol
      end
      if kind == "If" then
        walk(statement.body)
        if statement.else_body then
          walk(statement.else_body)
        end
      elseif kind == "While" or kind == "For" then
        walk(statement.body)
      elseif kind == "Try" then
        walk(statement.body)
        for _, handler in ipairs(statement.handlers) do
          if handler.name and not scope[handler.name] then
            local symbol = { name = handler.name, span = handler.span }
            scope[handler.name] = symbol
            fn.locals[#fn.locals + 1] = symbol
          end
          walk(handler.body)
        end
        if statement.finally_body then
          walk(statement.finally_body)
        end
      end
    end
  end
  walk(fn.body)
  return scope
end

local SCALARS = {
  int = types.int,
  float = types.float,
  bool = types.bool,
  str = types.str,
  bytes = types.bytes,
  None = types.None,
}

-- Returns declaration `name` of `module` as seen from module `from`. Names that
-- begin with `_` are private to their module.
local function lookup(from, module, name, span)
  local declaration = module.declarations[name]
  if not declaration then
    diag.error(span, "module '" .. module.name .. "' has no function, class, or alias '" .. name .. "'")
  end
  if name:sub(1, 1) == "_" and module ~= from then
    diag.error(span, "'" .. name .. "' is private to module '" .. module.name .. "'")
  end
  return declaration
end

-- Returns the record or alias that `ref`, a `{ name, module, span }` in a type,
-- an `except` clause, or `isinstance`, names. These are found through
-- file-level declarations, imports, and built-in exception classes, which
-- locals never shadow.
local function resolve_named(ref, module)
  local declaration
  if ref.module then
    local imported = module.imported[ref.module]
    if not imported then
      diag.error(ref.span, "unknown module '" .. ref.module .. "'")
    end
    declaration = lookup(module, imported, ref.name, ref.span)
  else
    declaration = module.declarations[ref.name] or exceptions[ref.name]
  end
  if not (declaration and (declaration.kind == "Record" or declaration.kind == "Alias")) then
    diag.error(ref.span, "unknown type '" .. (ref.module and ref.module .. "." or "") .. ref.name .. "'")
  end
  return declaration
end

-- Lazy list elements and dict values waiting to be resolved.
local pending = {}

-- The source text of type `node`, with declarations named by their type_name.
local function type_text(node, module)
  if node.kind == "UnionType" then
    local names = {}
    for i, member in ipairs(node.members) do
      names[i] = type_text(member, module)
    end
    return table.concat(names, " | ")
  elseif node.name == "list" then
    return "list[" .. type_text(node.args[1], module) .. "]"
  elseif node.name == "dict" then
    return "dict[" .. type_text(node.args[1], module) .. ", " .. type_text(node.args[2], module) .. "]"
  elseif SCALARS[node.name] then
    return node.name
  end
  return resolve_named(node, module).type_name
end

local resolve_type

local function lazy(node, module)
  local t = { kind = "lazy", name = type_text(node, module), node = node, module = module }
  pending[#pending + 1] = t
  return t
end

-- Resolves every lazy type; resolving one may queue more.
local function force_pending()
  while #pending > 0 do
    local t = table.remove(pending)
    t.type = resolve_type(t.node, t.module)
  end
end

-- Sets `decl.type` to the type alias `decl` names. Its list elements and dict
-- values are lazy, so only other positions can reach an alias being resolved.
local function resolve_alias(decl)
  if not decl.type then
    decl.resolving = true
    local name = decl.value.kind == "UnionType" and decl.type_name or nil
    decl.type = resolve_type(decl.value, decl.module, name)
    decl.resolving = nil
  end
  return decl.type
end

-- Returns the type object for type node `node`. `name` names a union.
resolve_type = function(node, module, name)
  if node.kind == "UnionType" then
    local members = {}
    for _, member in ipairs(node.members) do
      for _, m in ipairs(types.members(resolve_type(member, module))) do
        local message = types.conflict(members, m)
        if message then
          diag.error(member.span, message)
        end
        members[#members + 1] = m
      end
    end
    return types.union(members, name)
  elseif node.name == "list" then
    return types.list(lazy(node.args[1], module))
  elseif node.name == "dict" then
    local key = resolve_type(node.args[1], module)
    if key ~= types.int and key ~= types.str then
      diag.error(node.args[1].span, "dictionary keys must be int or str")
    end
    return types.dict(key, lazy(node.args[2], module))
  elseif SCALARS[node.name] then
    return SCALARS[node.name]
  end
  local declaration = resolve_named(node, module)
  if declaration.kind == "Alias" then
    if declaration.resolving then
      diag.error(node.span, "alias '" .. declaration.name .. "' expands to itself")
    end
    return resolve_alias(declaration)
  end
  return declaration.type
end

-- The dotted module name `node` spells, a `Name` or `Field`s on one, or nil.
local function qualified_name(node)
  if node.kind == "Name" then
    return node.name, node.name
  elseif node.kind == "Field" then
    local path, root = qualified_name(node.object)
    return path and path .. "." .. node.name, root
  end
end

local function resolve_function(fn, scope, module)
  local declarations, imports, roots = module.declarations, module.imported, module.roots

  -- The module name a method call's object spells when it starts with an
  -- import's root that no local shadows, or nil.
  local function module_path(object)
    local path, root = qualified_name(object)
    if path and not scope[root] and roots[root] then
      return path
    end
  end

  local function resolve_expression(node)
    local kind = node.kind
    if kind == "Name" then
      node.symbol = scope[node.name]
      if not node.symbol then
        local declaration = declarations[node.name]
        if roots[node.name] then
          diag.error(node.span, "module '" .. node.name .. "' cannot be used as a value")
        elseif declaration and declaration.kind == "Record" or exceptions[node.name] then
          diag.error(node.span, "class '" .. node.name .. "' cannot be used as a value")
        elseif declaration and declaration.kind == "Alias" then
          diag.error(node.span, "alias '" .. node.name .. "' cannot be used as a value")
        elseif declaration or builtins[node.name] then
          diag.error(node.span, "function '" .. node.name .. "' cannot be used as a value")
        end
        diag.error(node.span, "unknown name '" .. node.name .. "'")
      end
    elseif kind == "Call" then
      if scope[node.name] then
        diag.error(node.span, "cannot call local variable '" .. node.name .. "'")
      end
      node.target = declarations[node.name] or builtins[node.name] or exceptions[node.name]
      if not node.target then
        diag.error(node.span, "unknown function '" .. node.name .. "'")
      elseif node.target.kind == "Alias" then
        diag.error(node.span, "alias '" .. node.name .. "' cannot be called")
      end
      for _, arg in ipairs(node.args) do
        resolve_expression(arg)
      end
    elseif kind == "MethodCall" and module_path(node.object) then
      -- `module.name(...)` calls a function or constructs a record of that module.
      local path = module_path(node.object)
      local imported = imports[path]
      if not imported then
        diag.error(node.object.span, "unknown module '" .. path .. "'")
      end
      node.kind = "Call"
      node.target = lookup(module, imported, node.name, node.span)
      node.name = path .. "." .. node.name
      if node.target.kind == "Alias" then
        diag.error(node.span, "alias '" .. node.name .. "' cannot be called")
      end
      node.object = nil
      for _, arg in ipairs(node.args) do
        resolve_expression(arg)
      end
    elseif kind == "Unary" or kind == "Is" then
      resolve_expression(node.operand)
    elseif kind == "IsInstance" then
      if scope.isinstance then
        diag.error(node.span, "cannot call local variable 'isinstance'")
      end
      resolve_expression(node.operand)
      local class = node.class
      if class.module or not SCALARS[class.name] and class.name ~= "list" and class.name ~= "dict" then
        local declaration = resolve_named(class, module)
        if declaration.kind == "Alias" then
          diag.error(class.span, "alias '" .. class.name .. "' cannot be used in isinstance")
        end
        class.record = declaration
      end
    elseif kind == "Binary" then
      resolve_expression(node.left)
      resolve_expression(node.right)
    elseif kind == "Index" then
      resolve_expression(node.object)
      resolve_expression(node.index)
    elseif kind == "Slice" then
      resolve_expression(node.object)
      if node.start then
        resolve_expression(node.start)
      end
      if node.stop then
        resolve_expression(node.stop)
      end
    elseif kind == "Keyword" then
      resolve_expression(node.value)
    elseif kind == "Field" then
      resolve_expression(node.object)
    elseif kind == "FString" then
      for _, part in ipairs(node.parts) do
        resolve_expression(part)
      end
    elseif kind == "MethodCall" then
      resolve_expression(node.object)
      for _, arg in ipairs(node.args) do
        resolve_expression(arg)
      end
    elseif kind == "ListDisplay" then
      for _, element in ipairs(node.elements) do
        resolve_expression(element)
      end
    elseif kind == "DictDisplay" then
      for _, entry in ipairs(node.entries) do
        resolve_expression(entry.key)
        resolve_expression(entry.value)
      end
    end
  end

  -- `handling` is the innermost `try` with an `except` clause enclosing `body`.
  local function resolve_block(body, handling)
    for _, statement in ipairs(body) do
      local kind = statement.kind
      if kind == "Assign" then
        resolve_expression(statement.value)
        statement.symbol = scope[statement.name]
        if statement.annotation then
          statement.annotation = resolve_type(statement.annotation, module)
        end
      elseif kind == "FieldAssign" then
        resolve_expression(statement.value)
        resolve_expression(statement.object)
      elseif kind == "IndexAssign" then
        resolve_expression(statement.value)
        resolve_expression(statement.object)
        resolve_expression(statement.index)
      elseif kind == "CallStmt" then
        resolve_expression(statement.call)
      elseif kind == "Return" then
        if statement.value then
          resolve_expression(statement.value)
        end
      elseif kind == "If" then
        resolve_expression(statement.condition)
        resolve_block(statement.body, handling)
        if statement.else_body then
          resolve_block(statement.else_body, handling)
        end
      elseif kind == "While" then
        resolve_expression(statement.condition)
        resolve_block(statement.body, handling)
      elseif kind == "For" then
        resolve_expression(statement.iterable)
        statement.symbol = scope[statement.name]
        resolve_block(statement.body, handling)
      elseif kind == "Assert" then
        resolve_expression(statement.condition)
        if statement.message then
          resolve_expression(statement.message)
        end
      elseif kind == "Raise" then
        if statement.value then
          resolve_expression(statement.value)
        elseif not handling then
          diag.error(statement.span, "bare 'raise' is only allowed in an 'except' clause")
        end
        statement.try = handling
      elseif kind == "Try" then
        resolve_block(statement.body, handling)
        for _, handler in ipairs(statement.handlers) do
          handler.record = resolve_named(handler.class, module)
          if not handler.record.exception then
            diag.error(handler.class.span, "'" .. handler.record.name .. "' is not an exception class")
          end
          handler.symbol = handler.name and scope[handler.name]
          resolve_block(handler.body, statement)
        end
        if statement.finally_body then
          resolve_block(statement.finally_body, handling)
        end
      end
    end
  end

  resolve_block(fn.body)
end

-- Checks names that must be unique within a function's parameters or a
-- class's fields.
local function check_unique(items, what)
  local seen = {}
  for _, item in ipairs(items) do
    if seen[item.name] then
      diag.error(item.span, "duplicate " .. what .. " '" .. item.name .. "'")
    end
    seen[item.name] = true
  end
end

-- Collects one module's imports, functions, records, and aliases, which share one
-- namespace; clashes are reported in source order.
local function declare(module, modules_by_name, entry)
  local ordered = {}
  for _, import in ipairs(module.imports) do
    import.kind = "Import"
    ordered[#ordered + 1] = import
  end
  for _, fn in ipairs(module.functions) do
    ordered[#ordered + 1] = fn
  end
  for _, record in ipairs(module.records) do
    ordered[#ordered + 1] = record
  end
  for _, alias in ipairs(module.aliases) do
    ordered[#ordered + 1] = alias
  end
  table.sort(ordered, function(a, b)
    return a.span.first < b.span.first
  end)

  -- An import takes its root name, which several qualified imports may share.
  module.declarations, module.imported, module.roots = {}, {}, {}
  local taken = {}
  for _, declaration in ipairs(ordered) do
    local import = declaration.kind == "Import"
    local name = import and declaration.root or declaration.name
    if builtins[name] then
      diag.error(declaration.span, "cannot redefine built-in function '" .. name .. "'")
    elseif exceptions[name] then
      diag.error(declaration.span, "cannot redefine built-in class '" .. name .. "'")
    end
    if import then
      local full = declaration.name
      for other in pairs(module.imported) do
        local short, long = other, full
        if #short > #long then
          short, long = long, short
        end
        if long:sub(1, #short + 1) == short .. "." then
          diag.error(declaration.span, "'" .. short .. "' is imported as a module and as a namespace")
        end
      end
      if module.imported[full] or taken[name] and not module.roots[name] then
        diag.error(declaration.span, "duplicate import '" .. full .. "'")
      end
    elseif taken[name] then
      local noun = declaration.kind == "Record" and "class" or declaration.kind:lower()
      diag.error(declaration.span, "duplicate " .. noun .. " '" .. name .. "'")
    end
    taken[name] = true
    if import then
      module.roots[name] = true
      module.imported[declaration.name] = modules_by_name[declaration.name] or M.modules[declaration.name]
    else
      declaration.module = module
      module.declarations[name] = declaration
    end
    if declaration.kind == "Record" or declaration.kind == "Alias" then
      declaration.type_name = module == entry and name or module.name .. "." .. name
    end
    if declaration.kind == "Record" then
      declaration.type = types.record(declaration)
    end
  end
end

local literal_types = {
  Int = types.int,
  Float = types.float,
  String = types.str,
  Bool = types.bool,
  None = types.None,
}

-- Checks that the default of `decl`, a parameter or field, fits its type.
local function check_default(decl)
  local default = decl.default
  local type = literal_types[default.kind]
  if not types.assignable(decl.type, type) then
    diag.error(default.span, "expected " .. decl.type.name .. ", received " .. type.name)
  end
end

-- Binds `modules`, the entry module first. A test entry needs no `main`;
-- instead `entry.tests` lists its `test_*` functions by name.
function M.bind(modules, test)
  local entry = modules[1]
  local modules_by_name = {}
  for _, module in ipairs(modules) do
    modules_by_name[module.name or ""] = module
  end
  for _, module in ipairs(modules) do
    declare(module, modules_by_name, entry)
  end

  pending = {}
  for _, module in ipairs(modules) do
    for _, alias in ipairs(module.aliases) do
      resolve_alias(alias)
    end
  end
  -- A method's `self` has the type of its class.
  local function resolve_signature(fn, module)
    check_unique(fn.params, "parameter")
    for i, param in ipairs(fn.params) do
      param.type = fn.class and i == 1 and fn.class.type or resolve_type(param.type, module)
    end
    fn.return_type = resolve_type(fn.return_type, module)
  end
  for _, module in ipairs(modules) do
    for _, record in ipairs(module.records) do
      check_unique(record.fields, "field")
      check_unique(record.methods, "method")
      for _, field in ipairs(record.fields) do
        field.type = resolve_type(field.type, module)
      end
      for _, method in ipairs(record.methods) do
        for _, field in ipairs(record.fields) do
          if field.name == method.name then
            diag.error(method.span, "method '" .. method.name .. "' has the same name as a field")
          end
        end
        method.class, method.module = record, module
        resolve_signature(method, module)
      end
    end
    for _, fn in ipairs(module.functions) do
      resolve_signature(fn, module)
    end
  end
  force_pending()
  for _, module in ipairs(modules) do
    for _, record in ipairs(module.records) do
      for _, field in ipairs(record.fields) do
        if field.default then
          check_default(field)
        end
      end
    end
    for _, fn in ipairs(M.functions(module)) do
      for _, param in ipairs(fn.params) do
        if param.default then
          check_default(param)
        end
      end
    end
  end

  if test then
    entry.tests = {}
    for _, fn in ipairs(entry.functions) do
      if fn.name:sub(1, 5) == "test_" then
        if #fn.params > 0 or fn.return_type ~= types.None then
          diag.error(fn.span, "test function '" .. fn.name .. "' must take no parameters and return None")
        end
        entry.tests[#entry.tests + 1] = fn
      end
    end
    table.sort(entry.tests, function(a, b)
      return a.name < b.name
    end)
  else
    local main = entry.declarations.main
    if not (main and main.kind == "Function") then
      diag.error(entry.span, "program has no main function")
    end
    if #main.params > 0 or main.return_type ~= types.None then
      diag.error(main.span, "main must take no parameters and return None")
    end
  end

  for _, module in ipairs(modules) do
    for _, fn in ipairs(M.functions(module)) do
      resolve_function(fn, collect_symbols(fn), module)
    end
  end
  force_pending()
end

return M
