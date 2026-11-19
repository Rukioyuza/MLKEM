-- Keccak sponge functions (FIPS 202): SHA3-256, SHA3-512, SHAKE128, SHAKE256.
-- The state is 200 bytes: 25 little-endian 64-bit lanes, lane (x, y) at index x + 5y.
-- Luau has no 64-bit integers, so a lane is handled as a (low, high) pair of 32-bit halves.

local band, bnot, bor, bxor = bit32.band, bit32.bnot, bit32.bor, bit32.bxor
local ROUNDS = 24

local function readLane(source: buffer, index: number): (number, number)
	return buffer.readu32(source, 8 * index), buffer.readu32(source, 8 * index + 4)
end

local function writeLane(target: buffer, index: number, low: number, high: number)
	buffer.writeu32(target, 8 * index, low)
	buffer.writeu32(target, 8 * index + 4, high)
end

local function rotate(amount: number, low: number, high: number): (number, number) -- 64-bit left rotation
	if amount >= 32 then
		amount, low, high = amount - 32, high, low
	end
	if amount == 0 then return low, high end
	return bor(bit32.lshift(low, amount), bit32.rshift(high, 32 - amount)),
		bor(bit32.lshift(high, amount), bit32.rshift(low, 32 - amount))
end

---- Constants ----

local roundConstants = buffer.create(8 * ROUNDS) -- ι: bits 2ʲ − 1 of each constant, from the LFSR x⁸ + x⁶ + x⁵ + x⁴ + 1
local rotations = { [0] = 0 } -- ρ: left rotation of lane x + 5y
do
	local register = 1
	for round = 0, ROUNDS - 1 do
		for j = 0, 6 do
			if register % 2 == 1 then buffer.writebits(roundConstants, 64 * round + 2 ^ j - 1, 1, 1) end
			register = bxor(2 * register, if register >= 128 then 0x171 else 0)
		end
	end

	local x, y = 1, 0
	for step = 1, 24 do
		rotations[x + 5 * y] = step * (step + 1) // 2 % 64
		x, y = y, (2 * x + 3 * y) % 5
	end
end

---- Keccak-f[1600] ----

local function permute(state: buffer)
	local parity, moved = buffer.create(40), buffer.create(200)
	for round = 0, ROUNDS - 1 do
		for offset = 0, 36, 4 do -- θ: parity of each column (half-lanes are independent here)
			local word = 0
			for row = 0, 160, 40 do word = bxor(word, buffer.readu32(state, row + offset)) end
			buffer.writeu32(parity, offset, word)
		end
		for x = 0, 4 do
			local leftLow, leftHigh = readLane(parity, (x + 4) % 5)
			local rightLow, rightHigh = rotate(1, readLane(parity, (x + 1) % 5))
			local mixLow, mixHigh = bxor(leftLow, rightLow), bxor(leftHigh, rightHigh)
			for y = 0, 4 do -- θ: mix in the neighbours' parity; ρ: rotate; π: move lane (x, y) to (y, 2x + 3y)
				local low, high = readLane(state, x + 5 * y)
				local target = y + 5 * ((2 * x + 3 * y) % 5)
				writeLane(moved, target, rotate(rotations[x + 5 * y], bxor(low, mixLow), bxor(high, mixHigh)))
			end
		end
		for y = 0, 4 do -- χ: lane ^= ~next & afterNext, along each row
			for x = 0, 4 do
				local low, high = readLane(moved, x + 5 * y)
				local nextLow, nextHigh = readLane(moved, (x + 1) % 5 + 5 * y)
				local afterLow, afterHigh = readLane(moved, (x + 2) % 5 + 5 * y)
				writeLane(state, x + 5 * y, bxor(low, band(bnot(nextLow), afterLow)), bxor(high, band(bnot(nextHigh), afterHigh)))
			end
		end
		local low, high = readLane(state, 0) -- ι
		local constantLow, constantHigh = readLane(roundConstants, round)
		writeLane(state, 0, bxor(low, constantLow), bxor(high, constantHigh))
	end
end

---- Sponge ----

local Sponge = {}
Sponge.__index = Sponge

local function xorByte(state: buffer, position: number, byte: number)
	buffer.writeu8(state, position, bxor(buffer.readu8(state, position), byte))
end

function Sponge.new(rate: number, suffix: number) -- rate in bytes; suffix = domain-separation bits plus first padding bit
	return setmetatable({ state = buffer.create(200), rate = rate, suffix = suffix, position = 0, squeezing = false }, Sponge)
end

function Sponge:absorb(...: buffer | number) -- parts are concatenated; a number is a single byte
	assert(not self.squeezing, "cannot absorb after squeezing")
	for _, part in { ... } do
		local bytes = if type(part) == "number" then buffer.fromstring(string.char(part)) else part
		for index = 0, buffer.len(bytes) - 1 do
			xorByte(self.state, self.position, buffer.readu8(bytes, index))
			self.position += 1
			if self.position == self.rate then
				permute(self.state)
				self.position = 0
			end
		end
	end
	return self
end

function Sponge:squeeze(length: number): buffer -- the next `length` output bytes
	if not self.squeezing then -- pad the final block; the first output byte then triggers the permutation
		xorByte(self.state, self.position, self.suffix)
		xorByte(self.state, self.rate - 1, 0x80)
		self.position, self.squeezing = self.rate, true
	end
	local output = buffer.create(length)
	for index = 0, length - 1 do
		if self.position == self.rate then
			permute(self.state)
			self.position = 0
		end
		buffer.writeu8(output, index, buffer.readu8(self.state, self.position))
		self.position += 1
	end
	return output
end

return {
	sha3_256 = function(...): buffer return Sponge.new(136, 0x06):absorb(...):squeeze(32) end,
	sha3_512 = function(...): buffer return Sponge.new(72, 0x06):absorb(...):squeeze(64) end,
	shake128 = function(...) return Sponge.new(168, 0x1F):absorb(...) end, -- returns the sponge; call :squeeze(n)
	shake256 = function(...) return Sponge.new(136, 0x1F):absorb(...) end,
}
