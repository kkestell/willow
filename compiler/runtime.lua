-- The runtime Lua that generated programs embed, which the compiler and tools
-- also load to use its functions.
local M = {}

local function read_runtime(name)
  local file = assert(io.open(assert(package.searchpath(name, package.path)), "rb"))
  local text = file:read("*a")
  file:close()
  return text
end

local core = read_runtime("runtime.core")
-- Runtime files that only programs using their helpers get: the case
-- conversion data is large, and the host helpers declare C structures. Each
-- runs in its own block so that its internal locals do not count toward the
-- chunk's limit of 200 locals; the helpers it defines without `local` are
-- declared before the block.
local function optional_runtime(text)
  local names, helpers = {}, {}
  for name in text:gmatch("\nfunction __wlo_([%w_]+)") do
    names[#names + 1] = "__wlo_" .. name
    helpers[name] = true
  end
  return { text = "local " .. table.concat(names, ", ") .. "\ndo\n" .. text .. "end\n", helpers = helpers }
end

local optional_runtimes = {
  optional_runtime(read_runtime("runtime.case_data") .. read_runtime("runtime.case")),
  optional_runtime(read_runtime("runtime.host")),
  optional_runtime(read_runtime("runtime.bytes")),
  optional_runtime(read_runtime("runtime.io")),
  optional_runtime(read_runtime("runtime.cli")),
  optional_runtime(read_runtime("runtime.http")),
  optional_runtime(read_runtime("runtime.json")),
}

-- The runtime text for a program that uses the helpers named in the set
-- `helpers`. It expects __wlo_paths, __wlo_sites, and __wlo_lines declared
-- before it.
function M.text(helpers)
  local text = core
  for _, optional in ipairs(optional_runtimes) do
    for name in pairs(helpers) do
      if optional.helpers[name] then
        text = text .. optional.text
        break
      end
    end
  end
  return text
end

-- Loads the runtime for `helpers` and returns its values named in `names`.
-- Loading has no effect on the process beyond declaring C functions and types.
function M.load(helpers, names)
  return assert(load("local __wlo_paths, __wlo_sites, __wlo_lines = {}, {}, {}\n" .. M.text(helpers)
    .. "return " .. table.concat(names, ", "), "=runtime"))()
end

return M
