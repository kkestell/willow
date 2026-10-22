-- Build a standalone Willow compiler from the executable stub and Lua sources.
local stub_path, output_path = arg[1], arg[2]
assert(stub_path and output_path, "usage: bundle.lua <stub> <output>")

local function read(path)
  local file = assert(io.open(path, "rb"))
  local text = file:read("*a")
  file:close()
  return text
end

local function quote(text)
  return '"' .. text:gsub('[%z\1-\31\\"]', function(char)
    return string.format("\\%03d", char:byte())
  end) .. '"'
end

local files = assert(io.popen("find compiler runtime -type f -name '*.lua' | sort"))
local payload = {}
for path in files:lines() do
  local name = path:gsub("%.lua$", ""):gsub("/", ".")
  payload[#payload + 1] = "package.preload[" .. quote(name) .. "] = function()\n"
    .. read(path) .. "\nend\n"
  if name:sub(1, 8) == "runtime." then
    payload[#payload + 1] = "package.preload[" .. quote("willow.source." .. name) .. "] = function() return "
      .. quote(read(path)) .. " end\n"
  end
end
files:close()
payload[#payload + 1] = "package.preload[\"willow.stub\"] = function() return " .. quote(read(stub_path)) .. " end\n"
payload[#payload + 1] = "require('compiler.cli')\n"
payload = table.concat(payload)

local length, bytes = #payload, {}
for i = 1, 8 do
  bytes[i] = string.char(length % 256)
  length = math.floor(length / 256)
end
local output = assert(io.open(output_path, "wb"))
output:write(read(stub_path), payload, table.concat(bytes), "WILLOWLU")
assert(output:close())
