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
  iter = { params = { "any" } },
  next = { params = { "any" } },
  range = {},
  input = { params = {}, result = optional_str },
  ord = { params = { types.str }, result = types.int },
  chr = { params = { types.int }, result = types.str },
  isinstance = {},
  sorted = {
    params = { "any", types.bool, "any" },
    names = { "items", "reverse", "key" },
    defaults = { [2] = { kind = "Bool", value = false }, [3] = { kind = "None" } },
    keyword_only = { [3] = true },
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
for name in ("Exception AssertionError OverflowError ZeroDivisionError ValueError IndexError KeyError RuntimeError OSError TimeoutError StopIteration"):gmatch("%S+") do
  exceptions[name] = exception(name, name)
end

-- A built-in protocol with one type parameter `T`, resolved as bind resolves
-- a declared one. `methods` returns its { name, params, result } entries from
-- its self type and `T`, where `params` follow `self` as { name, type }.
local function standard_protocol(name, methods)
  local T = types.typevar("T")
  local decl = { kind = "Protocol", name = name, type_name = name, type_params = { { name = "T" } }, typevars = { T } }
  decl.self_type = types.protocol(decl, { T })
  decl.methods = {}
  for i, method in ipairs(methods(decl.self_type, T)) do
    local params = { { name = "self", type = decl.self_type } }
    for j, param in ipairs(method[2]) do
      params[j + 1] = { name = param[1], type = param[2] }
    end
    decl.methods[i] = { kind = "Function", name = method[1], params = params, return_type = method[3], class = decl }
  end
  return decl
end

-- The built-in standard protocols.
local optional_exception = types.union({ exceptions.Exception.type, types.None })
local iterator = standard_protocol("Iterator", function(self, T)
  return { { "iter", {}, self }, { "next", {}, T } }
end)
local function iterator_of(T)
  return types.protocol(iterator, { T })
end
-- types.lua gives built-in values `iter` methods returning iterators.
types.iterator = iterator_of
M.protocols = {
  Iterator = iterator,
  Iterable = standard_protocol("Iterable", function(_, T)
    return { { "iter", {}, iterator_of(T) } }
  end),
  ContextManager = standard_protocol("ContextManager", function(_, T)
    return { { "enter", {}, T }, { "exit", { { "error", optional_exception } }, types.None } }
  end),
  Generator = standard_protocol("Generator", function(self, T)
    return {
      { "iter", {}, iterator_of(T) }, { "next", {}, T }, { "close", {}, types.None }, { "enter", {}, self },
      { "exit", { { "error", optional_exception } }, types.None },
    }
  end),
}

-- `Coroutine[T]`, an opaque generic type with no methods. Values are created
-- only by calling async functions.
local coroutine_T = types.typevar("T")
M.coroutine = {
  kind = "Record", name = "Coroutine", type_name = "Coroutine", fields = {}, methods = {},
  native = true, native_methods = {}, type_params = { { name = "T" } }, typevars = { coroutine_T },
}
M.coroutine.self_type = types.generic(M.coroutine, { coroutine_T })

-- Whether `t` is a coroutine type or a union with a coroutine member.
function M.has_coroutine(t)
  for _, m in ipairs(types.members(t)) do
    if m.kind == "record" and m.record == M.coroutine then
      return true
    end
  end
  return false
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
-- built-in targets for `functions`, keyed by name, and the records, aliases,
-- and type forms in `records`. A program's own module of the same name shadows
-- it.
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

-- Gives native type `record` the context-manager methods: `enter` returns the
-- open handle and `exit` closes it.
local function scoped(record)
  record.native_methods.enter = { params = {}, result = record.type }
  record.native_methods.exit = { params = { optional_exception }, names = { "error" }, result = types.None }
end

local file = native_record("io", "File", "file", {
  read = { params = { types.int }, names = { "size" }, result = types.bytes },
  readline = { params = {}, result = optional_str },
  write = { params = { types.bytes }, names = { "data" }, result = types.None },
  write_text = { params = { types.str }, names = { "text" }, result = types.None },
  flush = { params = {}, result = types.None },
  close = { params = {}, result = types.None },
  iter = { params = {}, result = iterator_of(types.str) },
})
scoped(file)
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

-- `aio.Task[T]`, an opaque generic handle like `Coroutine[T]`. A native
-- method with `typevars` is generic in them.
local task_T = types.typevar("T")
local task = {
  kind = "Record", name = "Task", type_name = "aio.Task", fields = {}, methods = {},
  native = true, prefix = "aio_task", type_params = { { name = "T" } }, typevars = { task_T },
  native_methods = { result = { params = {}, result = task_T } },
}
task.self_type = types.generic(task, { task_T })
M.task = task
local start_T = types.typevar("T")
local task_group = native_record("aio", "TaskGroup", "aio_group", {
  start = {
    params = { types.generic(M.coroutine, { start_T }) }, names = { "coro" },
    result = types.generic(task, { start_T }), typevars = { start_T },
  },
  cancel = { params = {}, result = types.None },
})
M.task_group = task_group

-- `aio`'s TCP handles behave like `net`'s, but `recv`, `sendall`, and `accept`
-- return coroutines that wait by suspending their task.
local aio_connection = native_record("aio", "Connection", "aio_connection", {
  recv = {
    params = { types.int, optional_float },
    names = { "size", "timeout" },
    defaults = { [2] = { kind = "None" } },
    result = types.generic(M.coroutine, { types.bytes }),
  },
  sendall = {
    params = { types.bytes, optional_float },
    names = { "data", "timeout" },
    defaults = { [2] = { kind = "None" } },
    result = types.generic(M.coroutine, { types.None }),
  },
  close = { params = {}, result = types.None },
})
local aio_listener = native_record("aio", "Listener", "aio_listener", {
  accept = {
    params = { optional_float },
    names = { "timeout" },
    defaults = { { kind = "None" } },
    result = types.generic(M.coroutine, { aio_connection.type }),
  },
  local_port = { params = {}, result = types.int },
  close = { params = {}, result = types.None },
})
scoped(aio_connection)
scoped(aio_listener)

local aio = provided("aio", {
  sleep = {
    params = { types.float }, names = { "seconds" }, result = types.generic(M.coroutine, { types.None }),
    helper = "aio_sleep_coroutine",
  },
  task_group = { params = {}, result = task_group.type, helper = "aio_task_group" },
  connect = {
    params = { types.str, types.int, optional_float },
    names = { "host", "port", "timeout" },
    defaults = { [3] = { kind = "Float", value = 30.0 } },
    result = types.generic(M.coroutine, { aio_connection.type }),
    helper = "aio_connect_coroutine",
  },
  listen = {
    params = { types.str, types.int, types.int },
    names = { "host", "port", "backlog" },
    defaults = { [3] = { kind = "Int", value = 16 } },
    result = aio_listener.type,
    helper = "aio_listen",
  },
}, { Task = task, TaskGroup = task_group, Connection = aio_connection, Listener = aio_listener })

local math = provided("math", {
  sqrt = { params = { types.float }, names = { "x" }, result = types.float },
})

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
local reader = native_record("net", "Reader", "net_reader", {
  read_exactly = {
    params = { types.int, optional_float },
    names = { "size", "timeout" },
    defaults = { [2] = { kind = "None" } },
    result = types.bytes,
  },
  read_until = {
    params = { types.bytes, types.int, optional_float },
    names = { "separator", "max_bytes", "timeout" },
    defaults = { [2] = { kind = "Int", value = 1048576 }, [3] = { kind = "None" } },
    result = types.bytes,
  },
  close = { params = {}, result = types.None },
})
scoped(connection)
scoped(listener)
scoped(reader)
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
  reader = {
    params = { connection.type },
    names = { "connection" },
    result = reader.type,
    helper = "net_reader",
  },
}, { Connection = connection, Listener = listener, Reader = reader })

-- Run-time types of built-in values that protocol dispatch finds converters
-- for, by their dispatch tags, which no class can have. Programs cannot name
-- them: built-in values are typed by their own kinds, and built-in iterators
-- and generators by protocols. Their methods lower to helpers named after
-- `prefix`. `extra` gives methods beyond `iter` from the item type parameter.
local function dispatched(tag, prefix, extra)
  local T = types.typevar("T")
  local methods = extra and extra(T) or {}
  methods.iter = { params = {}, result = iterator_of(T) }
  local record = { kind = "Record", name = tag, type_name = tag, fields = {}, native = true, prefix = prefix, native_methods = methods }
  record.type = types.record(record)
  return record
end
M.dispatched = {}
for i, name in ipairs({ "list", "dict", "str", "bytes", "tuple", "range" }) do
  M.dispatched[i] = dispatched(name, name)
end
M.dispatched[#M.dispatched + 1] = dispatched("<iterator>", "iterator", function(T)
  return { next = { params = {}, result = T } }
end)
M.dispatched[#M.dispatched + 1] = dispatched("<generator>", "generator", function(T)
  return {
    next = { params = {}, result = T },
    close = { params = {}, result = types.None },
    enter = { params = {}, result = types.protocol(M.protocols.Generator, { T }) },
    exit = { params = { optional_exception }, names = { "error" }, result = types.None },
  }
end)

M.modules = {
  aio = aio,
  cli = cli,
  fs = fs,
  http = http,
  io = io,
  json = json,
  math = math,
  net = net,
  subprocess = subprocess,
  sys = sys,
  terminal = terminal,
  time = time,
}

return M
