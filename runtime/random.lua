-- Random number helpers, inlined after runtime/core.lua into programs that use
-- them. The helpers are the functions declared without `local`. A generator is
-- { "random.Random", s0, s1, s2, s3 }, with the state of xoshiro128**, which is not
-- suitable for security.

local __wlo_bit = require("bit")

-- Multiplies two unsigned 32-bit numbers modulo 2^32. A double holds only the
-- 16-bit halves' partial products exactly.
local function __wlo_random_mul(a, b)
  return __wlo_bit.tobit(a * __wlo_bit.band(b, 0xffff) + __wlo_bit.lshift(__wlo_bit.tobit(a * __wlo_bit.rshift(b, 16)), 16))
end

local function __wlo_random_rotl(x, k)
  return __wlo_bit.rol(x, k)
end

-- The next unsigned 32-bit output of `generator`.
local function __wlo_random_next(generator)
  local s0, s1, s2, s3 = generator[2], generator[3], generator[4], generator[5]
  local result = __wlo_random_rotl(__wlo_bit.tobit(s1 * 5), 7)
  result = __wlo_bit.tobit(result * 9)
  local t = __wlo_bit.lshift(s1, 9)
  s2 = __wlo_bit.bxor(s2, s0)
  s3 = __wlo_bit.bxor(s3, s1)
  s1 = __wlo_bit.bxor(s1, s2)
  s0 = __wlo_bit.bxor(s0, s3)
  s2 = __wlo_bit.bxor(s2, t)
  s3 = __wlo_random_rotl(s3, 11)
  generator[2], generator[3], generator[4], generator[5] = s0, s1, s2, s3
  return result % 4294967296
end

-- A uniform integer in [0, n], by rejection sampling from the smallest
-- covering bit mask. `n` is an int64 below 2^54.
local function __wlo_random_below(generator, n)
  local mask = n
  for shift = 0, 5 do
    mask = __wlo_bit.bor(mask, __wlo_bit.rshift(mask, 2 ^ shift))
  end
  while true do
    local high, low = __wlo_random_next(generator), __wlo_random_next(generator)
    local r = __wlo_bit.band(__wlo_bit.bor(__wlo_bit.lshift(__wlo_ffi.new("int64_t", high), 32), low), mask)
    if r <= n then
      return r
    end
  end
end

-- A generator seeded from `seed`: its low and high 32-bit halves are mixed by
-- a splitmix32-style hash into the four state words, so distinct seeds start
-- distinct streams.
function __wlo_random_generator(seed, site)
  local state = __wlo_bit.tobit(seed % 4294967296)
  local high = __wlo_bit.tobit(math.floor(seed / 4294967296))
  local generator = { "random.Random" }
  for i = 1, 4 do
    state = __wlo_bit.tobit(state + 0x9e3779b9)
    local z = state
    z = __wlo_random_mul(__wlo_bit.bxor(z, __wlo_bit.rshift(z, 16)), 0x85ebca6b)
    z = __wlo_random_mul(__wlo_bit.bxor(z, __wlo_bit.rshift(z, 13)), 0xc2b2ae35)
    generator[i + 1] = __wlo_bit.bxor(z, __wlo_bit.rshift(z, 16))
    if i == 1 then
      state = __wlo_bit.tobit(state + high)
    end
  end
  if generator[2] == 0 and generator[3] == 0 and generator[4] == 0 and generator[5] == 0 then
    generator[2] = 1
  end
  return generator
end

-- A float in [0, 1) with 53 random bits.
function __wlo_random_random(generator, site)
  local high, low = __wlo_random_next(generator) % 2 ^ 27, __wlo_random_next(generator) % 2 ^ 26
  return (high * 2 ^ 26 + low) / 2 ^ 53
end

function __wlo_random_randint(generator, a, b, site)
  if a > b then
    __wlo_fail("ValueError", "randint range is empty", site)
  end
  local n = __wlo_ffi.new("int64_t", b) - __wlo_ffi.new("int64_t", a)
  return tonumber(__wlo_ffi.new("int64_t", a) + __wlo_random_below(generator, n))
end

function __wlo_random_choice(generator, items, site)
  if items.n == 0 then
    __wlo_fail("ValueError", "cannot choose from an empty list", site)
  end
  return items[tonumber(__wlo_random_below(generator, __wlo_ffi.new("int64_t", items.n - 1))) + 1]
end

-- Fisher-Yates.
function __wlo_random_shuffle(generator, items, site)
  for i = items.n, 2, -1 do
    local j = tonumber(__wlo_random_below(generator, __wlo_ffi.new("int64_t", i - 1))) + 1
    items[i], items[j] = items[j], items[i]
  end
end

function __wlo_random_secure_bytes(size, site)
  if size < 0 then
    __wlo_fail("ValueError", "size must be nonnegative", site)
  end
  local file, err = io.open("/dev/urandom", "rb")
  if not file then
    __wlo_fail("OSError", "cannot read random bytes: " .. __wlo_open_reason(err, "/dev/urandom"), site)
  end
  local octets
  octets, err = file:read(size)
  file:close()
  if size == 0 then
    octets = ""
  elseif not octets or #octets < size then
    __wlo_fail("OSError", "cannot read random bytes: " .. (err or "unexpected end of file"), site)
  end
  return { __wlo_octets = octets }
end
