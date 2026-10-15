-- Compile-time diagnostics. A pass reports invalid source by raising one with
-- diag.error; the CLI treats any other raised value as an internal compiler error.
local M = {}

local Diagnostic = {}

function M.error(span, message)
  error(setmetatable({ span = span, message = message }, Diagnostic))
end

function M.is(value)
  return getmetatable(value) == Diagnostic
end

function M.format(path, d)
  return string.format("%s:%d:%d: error: %s", path, d.span.line, d.span.col, d.message)
end

return M
