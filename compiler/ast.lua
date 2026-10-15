-- Syntax tree nodes: plain tables with a kind, a span, and kind-specific fields.
local M = {}

function M.node(kind, span, fields)
  fields.kind = kind
  fields.span = span
  return fields
end

return M
