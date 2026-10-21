package.path = "./?.lua;" .. package.path
local A = require("proto")
local log = {}
local function say(...) log[#log + 1] = table.concat({ ... }, " ") end

local function async_with(g, body)
  A.group_enter(g)
  local code, value = A.try(body)
  code, value = A.group_exit(g, code, value)
  if code == "raise" or code == "cancel" then error(value, 0) end
  return code, value
end

local function scenario(name, main)
  log = {}
  local ok, err = pcall(A.run, A.coro(main).body)
  if not ok then say("RUN ERROR", tostring(err)) end
  print("== " .. name)
  for _, line in ipairs(log) do print("  " .. line) end
end

-- 1. Inner and outer cancelled at the same time. Inner must not absorb outer.
scenario("simultaneous inner/outer cancel", function()
  local outer = A.group_new()
  local code = async_with(outer, function()
    local inner = A.group_new()
    A.group_start(outer, A.coro(function()
      A.sleep(1)
      A.group_cancel(inner); A.group_cancel(outer)
      say("child cancelled both")
    end))
    async_with(inner, function()
      A.group_start(inner, A.coro(function()
        A.try_finally(function() A.sleep(10) end, function() say("inner child cleanup"); A.sleep(1) end)
      end))
      A.sleep(5)
      say("NOT REACHED inner body")
    end)
    say("NOT REACHED after inner")
  end)
  say("after outer, clock", A.clock())
end)

-- 2. First request arrives during cleanup entered by ordinary return.
scenario("request during finally of a return", function()
  local g = A.group_new()
  local result = { async_with(g, function()
    A.group_start(g, A.coro(function() A.sleep(1); A.group_cancel(g); say("cancel sent") end))
    local code, value = A.try_finally(function() return "return", 42 end, function()
      A.sleep(3)                         -- protected: not interrupted
      say("finally completed")
    end)
    return code, value
  end) }
  say("group departed with", tostring(result[1]), tostring(result[2]))
end)

-- 3. Group created inside protected cleanup; outer request must not cancel its children,
-- but its own stop works; outer request is delivered after protection is left.
scenario("group inside protected cleanup", function()
  local outer = A.group_new()
  async_with(outer, function()
    A.group_start(outer, A.coro(function() A.sleep(1); A.group_cancel(outer); say("outer cancelled") end))
    A.try_finally(function() end, function()
      local inner = A.group_new()
      async_with(inner, function()
        A.group_start(inner, A.coro(function() A.sleep(5); say("protected child finished normally at", A.clock()) end))
        A.group_start(inner, A.coro(function()
          A.sleep(7); A.group_cancel(inner); say("inner cancelled itself")
        end))
        A.sleep(100)
        say("NOT REACHED")
      end)
      say("inner group absorbed its own stop at", A.clock())
    end)
    say("after finally, before checkpoint")
    A.sleep(1)
    say("NOT REACHED after checkpoint")
  end)
  say("outer absorbed at", A.clock())
end)

-- 4. Inner failure while outer request pending: failure propagates as an
-- exception; the outer flag survives a catch and is delivered at the next await.
scenario("inner failure with outer pending", function()
  local outer = A.group_new()
  async_with(outer, function()
    local code, err = A.try(function()
      local inner = A.group_new()
      async_with(inner, function()
        A.group_start(inner, A.coro(function()
          A.try_finally(function() A.sleep(10) end, function() A.sleep(1); error({ class = "ValueError", message = "boom" }, 0) end)
        end))
        A.sleep(1)
        A.group_cancel(outer)
        A.sleep(1)
      end)
    end)
    say("caught", code, err and err.message or "")
    A.sleep(1)
    say("NOT REACHED")
  end)
  say("outer absorbed; done at", A.clock())
end)

-- 5. Await of an already consumed coroutine; await on a cancelled task.
scenario("consumed and cancelled", function()
  local g = A.group_new()
  local c = A.coro(function() return 1 end)
  local t
  async_with(g, function()
    t = A.group_start(g, c)
    A.group_cancel(g)
  end)
  local code, err = A.try(function() A.await(c) end)
  say(code, err.message)
  local code2, v = A.try(function() return "return", A.await(t) end)
  say("await task:", code2, tostring(v), "state=" .. t.state)
end)
