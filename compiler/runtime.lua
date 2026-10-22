-- The runtime Lua that generated programs embed, which the compiler and tools
-- also load to use its functions.
local M = {}

local function read_runtime(name)
  local embedded = package.preload["willow.source." .. name]
  if embedded then
    return embedded()
  end
  local file = assert(io.open(assert(package.searchpath(name, package.path)), "rb"))
  local text = file:read("*a")
  file:close()
  return text
end

local core = read_runtime("runtime.core")
local optional_helpers = {}
-- Runtime files that only programs using their helpers get: the case
-- conversion data is large, and the host helpers declare C structures. Each
-- file runs in a function of its own and exports its helpers through one
-- table, so its locals count toward that function's limit of 200 rather than
-- the chunk's, which also holds the core helpers.
local function optional_runtime(text)
  local names, helpers, exports = {}, {}, {}
  for name in text:gmatch("\nfunction __wlo_([%w_]+)") do
    names[#names + 1] = "__wlo_" .. name
    helpers[name] = true
    optional_helpers[name] = true
    exports[#exports + 1] = "__wlo_runtime." .. name .. " = __wlo_" .. name .. "\n"
  end
  return {
    text = "do\nlocal function __wlo_load()\nlocal " .. table.concat(names, ", ") .. "\n" .. text
      .. table.concat(exports) .. "end\n__wlo_load()\nend\n",
    helpers = helpers,
  }
end

local host_runtime = optional_runtime(read_runtime("runtime.host"))
local aio_runtime = optional_runtime(read_runtime("runtime.aio"))
-- `aio`'s TCP handles wait through host.lua's socket bodies.
local aio_net_runtime = optional_runtime(read_runtime("runtime.aio_net"))
aio_net_runtime.needs = { aio_runtime, host_runtime }
-- `net.Reader` receives through host.lua's `net` operations.
local net_reader_runtime = optional_runtime(read_runtime("runtime.net_reader"))
net_reader_runtime.needs = { host_runtime }

local optional_runtimes = {
  optional_runtime(read_runtime("runtime.case_data") .. read_runtime("runtime.case")),
  host_runtime,
  optional_runtime(read_runtime("runtime.bytes")),
  optional_runtime(read_runtime("runtime.io")),
  optional_runtime(read_runtime("runtime.cli")),
  optional_runtime(read_runtime("runtime.http")),
  optional_runtime(read_runtime("runtime.json")),
  aio_runtime,
  aio_net_runtime,
  net_reader_runtime,
}

-- The generated reference to a helper named without its __wlo_ prefix.
function M.reference(name)
  return (optional_helpers[name] and "__wlo_runtime." or "__wlo_") .. name
end

-- The runtime text for a program that uses the helpers named in the set
-- `helpers`. It expects __wlo_paths, __wlo_sites, and __wlo_lines declared
-- before it.
function M.text(helpers)
  local text = "local __wlo_runtime = {}\n" .. core
  local written = {}
  local function write(optional)
    if not written[optional] then
      written[optional] = true
      text = text .. optional.text
      for _, needed in ipairs(optional.needs or {}) do
        write(needed)
      end
    end
  end
  for _, optional in ipairs(optional_runtimes) do
    for name in pairs(helpers) do
      if optional.helpers[name] then
        write(optional)
        break
      end
    end
  end
  return text
end

-- Loads the runtime for `helpers` and returns its values named in `names`.
-- Loading has no effect on the process beyond declaring C functions and types.
function M.load(helpers, names)
  local references = {}
  for i, name in ipairs(names) do
    references[i] = M.reference(name:sub(7))
  end
  return assert(load("local __wlo_paths, __wlo_sites, __wlo_lines = {}, {}, {}\n" .. M.text(helpers)
    .. "return " .. table.concat(references, ", "), "=runtime"))()
end

return M
