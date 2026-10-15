-- Compile-time diagnostics. A pass reports invalid source by raising a list of
-- one or more diagnostics; the CLI treats any other raised value as an internal
-- compiler error.
local M = {}

local Diagnostics = {}

function M.raise(list)
  error(setmetatable(list, Diagnostics))
end

function M.error(span, message)
  M.raise({ { span = span, message = message } })
end

function M.is(value)
  return getmetatable(value) == Diagnostics
end

function M.format(d)
  return string.format("%s:%d:%d: error: %s", d.span.path, d.span.line, d.span.col, d.message)
end

return M
