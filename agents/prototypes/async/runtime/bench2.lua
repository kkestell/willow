io.stdout:setvbuf("no")
package.path = "./?.lua;" .. package.path
local A = require("proto")
local t0
A.run(function()
  local g = A.group_new()
  A.group_enter(g)
  local code, v = A.try(function()
    for i = 1, 100000 do A.group_start(g, A.coro(function() A.sleep(10) end)) end
    A.sleep(1)
    t0 = os.clock()
    A.group_cancel(g)
  end)
  code, v = A.group_exit(g, code, v)
  print(string.format("cancel 100k suspended children + join: %.3f s", os.clock() - t0), code)
end)
