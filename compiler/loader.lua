-- Loads the entry file and every module it imports.
local ffi = require("ffi")
local diag = require("compiler.diag")
local lexer = require("compiler.lexer")
local parser = require("compiler.parser")
local bind = require("compiler.bind")

ffi.cdef([[char *realpath(const char *path, char *resolved);]])

local M = {}

local ENOENT = 2

-- The canonical path of an existing file, which identifies it.
local function real_path(path)
  local buffer = ffi.new("char[4096]")
  local result = ffi.C.realpath(path, buffer)
  return result ~= nil and ffi.string(result) or path
end

local function read(path)
  local file, err, code = io.open(path, "rb")
  if not file then
    return nil, err, code
  end
  local text, read_err = file:read("*a")
  file:close()
  if not text then
    return nil, path .. ": " .. read_err
  end
  return text
end

-- Returns the program nodes of the entry file at `path`, whose text is
-- `source`, and of every module it reaches, ordered by first import depth first
-- with the entry first. Each node gets its module `name` and `path`.
--
-- `roots` gives where module `a.b` (file `a/b.wlo`) is looked for, in order:
-- `primary`, a directory prefix ending in a slash or empty; each prefix in
-- `dependencies`, where more than one match is an error; the compiler-provided
-- modules; and `library`. The entry is registered as `roots.entry_name`.
function M.load(path, source, roots)
  local modules, by_name, by_file = {}, {}, {}

  -- The path and text of module `name`, or nil for a provided module.
  local function find(import)
    local name = import.name
    local relative = name:gsub("%.", "/") .. ".wlo"
    local primary_path = roots.primary .. relative
    local text, err, code = read(primary_path)
    if text or code ~= ENOENT then
      if not text then
        diag.error(import.span, "cannot load module '" .. name .. "': " .. err)
      end
      return primary_path, text
    end
    local found = {}
    for _, dependency in ipairs(roots.dependencies or {}) do
      local candidate = dependency .. relative
      local candidate_text, candidate_err, candidate_code = read(candidate)
      if candidate_text then
        found[#found + 1] = { candidate, candidate_text }
      elseif candidate_code ~= ENOENT then
        diag.error(import.span, "cannot load module '" .. name .. "': " .. candidate_err)
      end
    end
    if #found > 1 then
      diag.error(import.span, "module '" .. name .. "' is ambiguous: found in " .. found[1][1] .. " and " .. found[2][1])
    elseif #found == 1 then
      return found[1][1], found[1][2]
    elseif bind.modules[name] then
      return nil
    end
    local library_path = roots.library .. relative
    local library_text = read(library_path)
    if library_text then
      return library_path, library_text
    end
    diag.error(import.span, "cannot load module '" .. name .. "': " .. err)
  end

  local function visit(name, module_path, text, span)
    local file = real_path(module_path)
    if by_file[file] then
      diag.error(span, "module '" .. name .. "' is the same file as module '" .. by_file[file] .. "'")
    end
    by_name[name], by_file[file] = true, name
    local program = parser.parse(lexer.lex(text, module_path))
    program.name, program.path = name, module_path
    modules[#modules + 1] = program
    for _, import in ipairs(program.imports) do
      if not by_name[import.name] then
        local import_path, import_text = find(import)
        if import_path then
          visit(import.name, import_path, import_text, import.span)
        end
      end
    end
  end

  visit(roots.entry_name, path, source)
  return modules
end

return M
