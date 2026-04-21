local M = {}

local MOD = 2^32
local has_bit, bit = pcall(require, 'bit')

local function normalize(value)
  return value % MOD
end

local band, bor, bxor, bnot, rshift, lshift, rrotate

if has_bit then
  band = function(a, b) return normalize(bit.band(a, b)) end
  bor = function(a, b) return normalize(bit.bor(a, b)) end
  bxor = function(a, b) return normalize(bit.bxor(a, b)) end
  bnot = function(a) return normalize(bit.bnot(a)) end
  rshift = function(a, n) return normalize(bit.rshift(a, n)) end
  lshift = function(a, n) return normalize(bit.lshift(a, n)) end
  rrotate = function(a, n) return normalize(bit.ror(a, n)) end
else
  band = function(a, b)
    local result, bit_value = 0, 1
    a, b = normalize(a), normalize(b)

    for _ = 1, 32 do
      local abit = a % 2
      local bbit = b % 2

      if abit == 1 and bbit == 1 then
        result = result + bit_value
      end

      a = (a - abit) / 2
      b = (b - bbit) / 2
      bit_value = bit_value * 2
    end

    return result
  end

  bor = function(a, b)
    return normalize(a + b - band(a, b))
  end

  bxor = function(a, b)
    return normalize(a + b - 2 * band(a, b))
  end

  bnot = function(a)
    return MOD - 1 - normalize(a)
  end

  rshift = function(a, n)
    return math.floor(normalize(a) / 2^n)
  end

  lshift = function(a, n)
    return normalize(a * 2^n)
  end

  rrotate = function(a, n)
    n = n % 32
    return normalize(rshift(a, n) + lshift(a, 32 - n))
  end
end

local function add(...)
  local sum = 0
  for i = 1, select('#', ...) do
    sum = normalize(sum + (select(i, ...) or 0))
  end
  return sum
end

local function ch(x, y, z)
  return bxor(band(x, y), band(bnot(x), z))
end

local function maj(x, y, z)
  return bxor(bxor(band(x, y), band(x, z)), band(y, z))
end

local function sigma0(x)
  return bxor(bxor(rrotate(x, 7), rrotate(x, 18)), rshift(x, 3))
end

local function sigma1(x)
  return bxor(bxor(rrotate(x, 17), rrotate(x, 19)), rshift(x, 10))
end

local function Sigma0(x)
  return bxor(bxor(rrotate(x, 2), rrotate(x, 13)), rrotate(x, 22))
end

local function Sigma1(x)
  return bxor(bxor(rrotate(x, 6), rrotate(x, 11)), rrotate(x, 25))
end

local function to_u32_be(value)
  value = normalize(value)
  return string.char(
    math.floor(value / 2^24) % 256,
    math.floor(value / 2^16) % 256,
    math.floor(value / 2^8) % 256,
    value % 256
  )
end

local function from_u32_be(chunk, index)
  local a, b, c, d = chunk:byte(index, index + 3)
  return add((a or 0) * 2^24, (b or 0) * 2^16, (c or 0) * 2^8, d or 0)
end

local K = {
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
  0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
  0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
  0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
  0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
  0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
  0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
  0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
  0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

function M.hash256(message)
  local length = #message
  local bit_length = length * 8
  local high = math.floor(bit_length / MOD)
  local low = bit_length % MOD
  local padding_length = (56 - (length + 1) % 64) % 64
  local padded = message
    .. string.char(0x80)
    .. string.rep('\0', padding_length)
    .. to_u32_be(high)
    .. to_u32_be(low)

  local h0 = 0x6a09e667
  local h1 = 0xbb67ae85
  local h2 = 0x3c6ef372
  local h3 = 0xa54ff53a
  local h4 = 0x510e527f
  local h5 = 0x9b05688c
  local h6 = 0x1f83d9ab
  local h7 = 0x5be0cd19

  for offset = 1, #padded, 64 do
    local w = {}
    local a, b, c, d, e, f, g, h

    for i = 0, 15 do
      w[i] = from_u32_be(padded, offset + i * 4)
    end

    for i = 16, 63 do
      w[i] = add(sigma1(w[i - 2]), w[i - 7], sigma0(w[i - 15]), w[i - 16])
    end

    a, b, c, d = h0, h1, h2, h3
    e, f, g, h = h4, h5, h6, h7

    for i = 0, 63 do
      local t1 = add(h, Sigma1(e), ch(e, f, g), K[i + 1], w[i])
      local t2 = add(Sigma0(a), maj(a, b, c))

      h = g
      g = f
      f = e
      e = add(d, t1)
      d = c
      c = b
      b = a
      a = add(t1, t2)
    end

    h0 = add(h0, a)
    h1 = add(h1, b)
    h2 = add(h2, c)
    h3 = add(h3, d)
    h4 = add(h4, e)
    h5 = add(h5, f)
    h6 = add(h6, g)
    h7 = add(h7, h)
  end

  return ('%08x%08x%08x%08x%08x%08x%08x%08x'):format(
    h0, h1, h2, h3, h4, h5, h6, h7
  )
end

return M
