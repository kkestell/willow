-- Reads a project's willow.json.
local loader = require("compiler.loader")
local runtime = require("compiler.runtime")

local M = {}

-- Parses the JSON text `text` with the json module's runtime, returning the
-- value or nil and a message. Values have their Willow representation: objects
-- are { keys, values }, lists have `n`, and `null` is nil.
local function parse_json(text)
  local parse = runtime.load({ json_parse = true }, { "__wlo_json_parse" })
  local ok, result = pcall(parse, text)
  if ok then
    return result
  elseif type(result) == "table" and result.__wlo_class == "json.JsonError" then
    return nil, result.message
  end
  error(result, 0)
end

local DEFAULTS = { entry = "main.wlo", source = ".", dependencies = {}, tests = "tests" }

-- `path` relative to the manifest directory, as a prefix-free path.
local function under(path)
  return path == "." and "" or path:gsub("/+$", "")
end

-- A directory prefix for `path`: empty for the manifest directory.
local function prefix(path)
  local dir = under(path)
  return dir == "" and "" or dir .. "/"
end

-- Reads `willow.json` in the current directory. Returns nil when there is
-- none, or the project, or false and an error message.
function M.read()
  local text, err, code = loader.read("willow.json")
  if code then
    return nil
  elseif not text then
    return false, err
  end
  local data
  data, err = parse_json(text)
  if not data then
    return false, "willow.json: " .. err
  end
  if type(data) ~= "table" or not data.keys then
    return false, "willow.json: expected an object"
  end
  local settings = {}
  for _, key in ipairs(data.keys) do
    local value = data.values[key]
    if DEFAULTS[key] == nil then
      return false, "willow.json: unknown key '" .. key .. "'"
    elseif key == "dependencies" then
      if type(value) ~= "table" or not value.n then
        return false, "willow.json: 'dependencies' must be a list of strings"
      end
      for i = 1, value.n do
        local item = value[i]
        if type(item) ~= "string" then
          return false, "willow.json: 'dependencies' must be a list of strings"
        elseif item == "" then
          return false, "willow.json: 'dependencies' cannot contain an empty path"
        end
      end
    elseif type(value) ~= "string" then
      return false, "willow.json: '" .. key .. "' must be a string"
    elseif value == "" then
      return false, "willow.json: '" .. key .. "' cannot be empty"
    end
    settings[key] = value
  end
  for key, default in pairs(DEFAULTS) do
    if settings[key] == nil then
      settings[key] = default
    end
  end

  local entry = settings.entry
  local stem = entry:match("^(.*)%.wlo$")
  local valid = stem and entry:sub(1, 1) ~= "/"
  if valid then
    for component in (stem .. "/"):gmatch("([^/]*)/") do
      if not component:match("^[%a_][%w_]*$") then
        valid = false
      end
    end
  end
  if not valid then
    return false, "willow.json: 'entry' must be a .wlo path inside the source root with identifier components"
  end
  local dependencies = {}
  for i, dependency in ipairs(settings.dependencies) do
    dependencies[i] = prefix(dependency)
  end
  return {
    entry = prefix(settings.source) .. entry,
    entry_name = stem:gsub("/", "."),
    source = prefix(settings.source),
    dependencies = dependencies,
    tests = under(settings.tests) == "" and "." or under(settings.tests),
  }
end

return M
