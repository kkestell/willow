-- Syntax tree nodes: plain tables with a kind, a span, and kind-specific fields.
local M = {}

function M.node(kind, span, fields)
  fields.kind = kind
  fields.span = span
  return fields
end

local function visit_targets(pattern, visit)
  if pattern.kind == "Name" then
    visit(pattern)
  else
    for _, element in ipairs(pattern.elements) do
      visit_targets(element, visit)
    end
  end
end

-- Calls `visit(node)` for each Assign, For, FunctionDef, named except handler,
-- and target of an Unpack or For pattern in `body` and its nested blocks, outer
-- before inner and left to right; `node.name` is the name it assigns. Nested
-- function bodies are scopes of their own and are not visited.
function M.assignments(body, visit)
  for _, statement in ipairs(body) do
    local kind = statement.kind
    if kind == "Unpack" or kind == "For" and statement.pattern then
      visit_targets(statement.pattern, visit)
    elseif kind == "Assign" or kind == "For" or kind == "FunctionDef" then
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
