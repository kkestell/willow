-- Syntax tree nodes: plain tables with a kind, a span, and kind-specific fields.
local M = {}

function M.node(kind, span, fields)
  fields.kind = kind
  fields.span = span
  return fields
end

-- Calls `visit(node)` for each Assign, For, and named except handler in
-- `body` and its nested blocks, outer before inner; `node.name` is the name
-- it assigns.
function M.assignments(body, visit)
  for _, statement in ipairs(body) do
    local kind = statement.kind
    if kind == "Assign" or kind == "For" then
      visit(statement)
    end
    if kind == "If" then
      M.assignments(statement.body, visit)
      if statement.else_body then
        M.assignments(statement.else_body, visit)
      end
    elseif kind == "While" or kind == "For" then
      M.assignments(statement.body, visit)
    elseif kind == "Try" then
      M.assignments(statement.body, visit)
      for _, handler in ipairs(statement.handlers) do
        if handler.name then
          visit(handler)
        end
        M.assignments(handler.body, visit)
      end
      if statement.finally_body then
        M.assignments(statement.finally_body, visit)
      end
    end
  end
end

return M
