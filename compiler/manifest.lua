-- Reads a project's willow.json.
local M = {}

-- Parses the JSON text `text`, returning the value or nil and a message. Objects
-- become { keys = ordered keys, values = { key = value } }, so later repeated
-- keys replace earlier values; `null` becomes `M.null`.
M.null = {}
local function parse_json(text)
  local pos = 1
  local fail

  local function skip()
    pos = text:find("[^ \t\r\n]", pos) or #text + 1
  end

  local function position()
    local line, col = 1, 1
    for i = 1, pos - 1 do
      if text:sub(i, i) == "\n" then
        line, col = line + 1, 1
      else
        col = col + 1
      end
    end
    return "line " .. line .. ", column " .. col
  end

  fail = function(problem)
    error({ message = problem .. " at " .. position() }, 0)
  end

  local value

  local function string_value()
    pos = pos + 1
    local parts = {}
    while true do
      local char = text:sub(pos, pos)
      if char == "" then
        fail("unterminated string")
      elseif char == '"' then
        pos = pos + 1
        return table.concat(parts)
      elseif char == "\\" then
        local escape = text:sub(pos + 1, pos + 1)
        local simple = ({ ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" })[escape]
        if simple then
          parts[#parts + 1] = simple
          pos = pos + 2
        elseif escape == "u" and text:sub(pos + 2, pos + 5):match("^%x%x%x%x$") then
          local code = tonumber(text:sub(pos + 2, pos + 5), 16)
          if code < 0x80 then
            parts[#parts + 1] = string.char(code)
          elseif code < 0x800 then
            parts[#parts + 1] = string.char(0xC0 + math.floor(code / 64), 0x80 + code % 64)
          else
            parts[#parts + 1] = string.char(0xE0 + math.floor(code / 4096), 0x80 + math.floor(code / 64) % 64, 0x80 + code % 64)
          end
          pos = pos + 6
        else
          fail("invalid escape")
        end
      elseif char:byte() < 32 then
        fail("control character in string")
      else
        parts[#parts + 1] = char
        pos = pos + 1
      end
    end
  end

  value = function()
    skip()
    local char = text:sub(pos, pos)
    if char == "{" then
      pos = pos + 1
      local object = { keys = {}, values = {} }
      skip()
      if text:sub(pos, pos) == "}" then
        pos = pos + 1
        return object
      end
      while true do
        skip()
        if text:sub(pos, pos) ~= '"' then
          fail("expected a string key")
        end
        local key = string_value()
        skip()
        if text:sub(pos, pos) ~= ":" then
          fail("expected ':'")
        end
        pos = pos + 1
        if object.values[key] == nil then
          object.keys[#object.keys + 1] = key
        end
        object.values[key] = value()
        skip()
        local next_char = text:sub(pos, pos)
        pos = pos + 1
        if next_char == "}" then
          return object
        elseif next_char ~= "," then
          pos = pos - 1
          fail("expected ',' or '}'")
        end
      end
    elseif char == "[" then
      pos = pos + 1
      local list = {}
      skip()
      if text:sub(pos, pos) == "]" then
        pos = pos + 1
        return list
      end
      while true do
        list[#list + 1] = value()
        skip()
        local next_char = text:sub(pos, pos)
        pos = pos + 1
        if next_char == "]" then
          return list
        elseif next_char ~= "," then
          pos = pos - 1
          fail("expected ',' or ']'")
        end
      end
    elseif char == '"' then
      return string_value()
    end
    for word, result in pairs({ ["true"] = true, ["false"] = false, null = M.null }) do
      if text:sub(pos, pos + #word - 1) == word then
        pos = pos + #word
        return result
      end
    end
    local literal = text:match("^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
    local number = literal and tonumber(literal)
    if number then
      pos = pos + #literal
      return number
    end
    fail("expected a value")
  end

  local ok, result = pcall(function()
    local parsed = value()
    skip()
    if pos <= #text then
      fail("unexpected text after the value")
    end
    return parsed
  end)
  if not ok then
    if type(result) == "table" then
      return nil, result.message
    end
    error(result, 0)
  end
  return result
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
  local file = io.open("willow.json", "rb")
  if not file then
    return nil
  end
  local text = file:read("*a")
  file:close()
  local data, err = parse_json(text)
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
      if type(value) ~= "table" or value.keys or value == M.null then
        return false, "willow.json: 'dependencies' must be a list of strings"
      end
      for _, item in ipairs(value) do
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
