-- Loads the entry file and every module it imports.
local diag = require("compiler.diag")
local lexer = require("compiler.lexer")
local parser = require("compiler.parser")

local M = {}

local ENOENT = 2

-- Returns the program nodes of the entry file at `path`, whose text is
-- `source`, and of every module it reaches, ordered by first import depth first
-- with the entry first. Each node gets its module `name` and `path`. Imports
-- missing from the entry file's directory come from `library`, a directory
-- path ending in a slash.
function M.load(path, source, library)
  local directory = path:match("^(.*/)") or ""
  local modules, seen = {}, {}

  local function visit(name, module_path, text)
    seen[name] = true
    local program = parser.parse(lexer.lex(text, module_path))
    program.name, program.path = name, module_path
    modules[#modules + 1] = program
    for _, import in ipairs(program.imports) do
      if not seen[import.name] then
        local import_path = directory .. import.name .. ".wlo"
        local file, err, code = io.open(import_path, "rb")
        if not file and code == ENOENT then
          local library_path = library .. import.name .. ".wlo"
          local library_file = io.open(library_path, "rb")
          if library_file then
            file, import_path = library_file, library_path
          end
        end
        if not file then
          diag.error(import.span, "cannot load module '" .. import.name .. "': " .. err)
        end
        local import_source, read_err = file:read("*a")
        file:close()
        if not import_source then
          diag.error(import.span, "cannot load module '" .. import.name .. "': " .. import_path .. ": " .. read_err)
        end
        visit(import.name, import_path, import_source)
      end
    end
  end

  visit((path:match("([^/]*)$"):gsub("%.wlo$", "")), path, source)
  return modules
end

return M
