local loader = require("compiler.loader")
local manifest = require("compiler.manifest")
local eq = require("tests.support").eq

-- Supply file contents or an open failure without depending on host permissions.
local function read_manifest(text, message, code)
  local read = loader.read
  loader.read = function()
    return text, message, code
  end
  local ok, project, err = pcall(manifest.read)
  loader.read = read
  assert(ok, project)
  return project, err
end

return {
  absolute_root_paths = function()
    local project = read_manifest('{"source":"/","dependencies":["/"],"tests":"/"}')
    eq("/main.wlo", project.entry)
    eq("/", project.source)
    eq("/", project.dependencies[1])
    eq("/", project.tests)
  end,

  open_errors_are_not_missing_manifests = function()
    local project, err = read_manifest(nil, "willow.json: Permission denied", 13)
    eq(false, project)
    eq("willow.json: Permission denied", err)
    eq(nil, read_manifest(nil, "willow.json: No such file or directory", 2))
  end,
}
