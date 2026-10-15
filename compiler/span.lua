-- Source spans: one-based line, code-point column, and inclusive byte offsets,
-- so source:sub(span.first, span.last) is the spanned text.
local M = {}

function M.new(line, col, first, last)
  return { line = line, col = col, first = first, last = last }
end

return M
