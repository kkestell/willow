-- Source spans: the file path, one-based line, code-point column, and inclusive
-- byte offsets, so source:sub(span.first, span.last) is the spanned text.
local M = {}

function M.new(line, col, first, last, path)
  return { line = line, col = col, first = first, last = last, path = path }
end

return M
