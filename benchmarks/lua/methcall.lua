local Toggle = {}
Toggle.__index = Toggle
function Toggle.new(state) return setmetatable({ state = state }, Toggle) end
function Toggle:activate() self.state = not self.state; return self end
function Toggle:value() return self.state end
local NthToggle = setmetatable({}, { __index = Toggle })
NthToggle.__index = NthToggle
function NthToggle.new(state, count_max)
  return setmetatable({ state = state, count_max = count_max, counter = 0 }, NthToggle)
end
function NthToggle:activate()
  self.counter = self.counter + 1
  if self.counter >= self.count_max then
    self.state = not self.state
    self.counter = 0
  end
  return self
end
local function run(switch, n)
  local value = true
  for _ = 1, n do value = switch:activate():value() end
  io.write(value and "true" or "false", "\n")
end
local n = tonumber(arg[1])
run(Toggle.new(true), n)
run(NthToggle.new(true, 3), n)
