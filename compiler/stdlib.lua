-- The built-in functions and exception classes and the compiler-provided
-- modules, as the binder sees them.
local types = require("compiler.types")

local M = {}

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
  bytes = { params = { types.list(types.int) }, result = types.bytes },
})
M.builtins = builtins

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

-- A native type: a provided record with no fields that only its module's
-- functions create. Its methods lower to helpers named after `prefix`.
local function native_record(module, name, prefix, methods)
  local record = {
    kind = "Record", name = name, type_name = module .. "." .. name, fields = {},
    native = true, prefix = prefix, native_methods = methods,
  }
  record.type = types.record(record)
  return record
end

local file = native_record("io", "File", "file", {
  read = { params = { types.int }, names = { "size" }, result = types.bytes },
  readline = { params = {}, result = optional_str },
  write = { params = { types.bytes }, names = { "data" }, result = types.None },
  write_text = { params = { types.str }, names = { "text" }, result = types.None },
  flush = { params = {}, result = types.None },
  close = { params = {}, result = types.None },
})
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
  eprint = { params = { "any" }, names = { "value" }, result = types.None },
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

local process = native_record("subprocess", "Process", "process", {
  poll = { params = {}, result = optional_int },
  wait = {
    params = { optional_float },
    names = { "timeout" },
    defaults = { { kind = "None" } },
    result = types.int,
  },
  terminate = { params = {}, result = types.None },
  kill = { params = {}, result = types.None },
})

local optional_env = types.union({ types.dict(types.str, types.str), types.None })
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

local args = native_record("cli", "Args", "cli_args", {
  get_str = getter(types.str),
  get_int = getter(types.int),
  get_float = getter(types.float),
  get_bool = getter(types.bool),
  get_list = getter(types.list(types.str)),
})

local described = {
  params = { types.str, types.str },
  names = { "name", "help" },
  defaults = { [2] = { kind = "String", value = "" } },
  result = types.None,
}
local parser = native_record("cli", "Parser", "cli_parser", {
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
})

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

local connection = native_record("net", "Connection", "net_connection", {
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
})
local listener = native_record("net", "Listener", "net_listener", {
  accept = {
    params = { optional_float },
    names = { "timeout" },
    defaults = { { kind = "None" } },
    result = connection.type,
  },
  local_port = { params = {}, result = types.int },
  close = { params = {}, result = types.None },
})
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

return M
