-- Helpers shared by the unit test files.
local M = {}

function M.eq(expected, actual)
  if expected ~= actual then
    error(string.format("expected %q, got %q", tostring(expected), tostring(actual)), 2)
  end
end

return M
