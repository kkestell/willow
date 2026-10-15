-- Runtime helpers, inlined by the emitter into every generated program. The
-- emitter defines __wlo_path before this text and assigns __wlo_sites and
-- __wlo_lines before calling __wlo_run.

local __wlo_source = debug.getinfo(1, "S").source
local __wlo_MAX_INT = 9007199254740991
local __wlo_MAX_FRAMES = 20

local function __wlo_fail(category, message, site)
  error({ category = category, message = message, location = __wlo_sites[site] }, 0)
end

-- Rejects results outside the integer range and normalizes -0.0 to 0.
local function __wlo_check(value, site)
  if value ~= value or value > __wlo_MAX_INT or value < -__wlo_MAX_INT then
    __wlo_fail("overflow", "integer overflow", site)
  end
  if value == 0 then
    return 0
  end
  return value
end

local function __wlo_add(a, b, site)
  return __wlo_check(a + b, site)
end

local function __wlo_sub(a, b, site)
  return __wlo_check(a - b, site)
end

local function __wlo_mul(a, b, site)
  return __wlo_check(a * b, site)
end

local function __wlo_neg(a, site)
  return __wlo_check(-a, site)
end

-- Flushes every line so a write failure is reported at the print that hit it.
local function __wlo_print(value, site)
  local text = value
  if value == nil then
    text = "None"
  elseif value == true then
    text = "True"
  elseif value == false then
    text = "False"
  elseif type(value) == "number" then
    text = string.format("%d", value)
  end
  local ok, err = io.stdout:write(text, "\n")
  if ok then
    ok, err = io.stdout:flush()
  end
  if not ok then
    __wlo_fail("io", "cannot write output: " .. tostring(err), site)
  end
end

local function __wlo_where(location)
  return __wlo_path .. ":" .. location[1] .. ":" .. location[2]
end

-- Formats a failure with its Willow frames, innermost first. Only lines of
-- translated Willow code are in __wlo_lines, so runtime and wrapper frames
-- drop out.
local function __wlo_report(err)
  local frames = {}
  local level = 1
  local info = debug.getinfo(level, "Sl")
  while info do
    local frame = info.source == __wlo_source and __wlo_lines[info.currentline]
    if frame then
      frames[#frames + 1] = frame
    end
    level = level + 1
    info = debug.getinfo(level, "Sl")
  end
  if type(err) ~= "table" then
    local message = tostring(err):gsub("^.-:%d+: ", "")
    err = { category = "vm", message = message, location = frames[1] }
  end
  local lines = { __wlo_where(err.location) .. ": error: " .. err.message }
  for i, frame in ipairs(frames) do
    if i > __wlo_MAX_FRAMES then
      lines[#lines + 1] = "  ... " .. (#frames - __wlo_MAX_FRAMES) .. " more frames"
      break
    end
    lines[#lines + 1] = (i == 1 and "  in " or "  called from ") .. frame[3] .. " at " .. __wlo_where(frame)
  end
  return table.concat(lines, "\n")
end

local function __wlo_run(main)
  local ok, report = xpcall(main, __wlo_report)
  if not ok then
    io.stderr:write(report, "\n")
    os.exit(1)
  end
end
