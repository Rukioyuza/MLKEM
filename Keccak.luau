--!native
--!optimize 2
--!nocheck

local state = buffer.create(200) -- interleaved lanes
local block = buffer.create(200) -- plain bytes of the current input / output block
local split = buffer.create(262144) -- u32[x]: even bits of 16-bit x in bits 0-7, odd bits in bits 16-23
local spread = buffer.create(262144) -- u32[x]: bits of 16-bit x moved to the even positions

local function compact(value) -- 16 bits -> the 8 bits at its even positions
	value = bit32.band(value, 0x5555)
	value = bit32.band(bit32.bor(value, bit32.rshift(value, 1)), 0x3333)
	value = bit32.band(bit32.bor(value, bit32.rshift(value, 2)), 0x0F0F)
	return bit32.band(bit32.bor(value, bit32.rshift(value, 4)), 0x00FF)
end

for value = 0, 65535 do
	local wide = bit32.band(bit32.bor(value, bit32.lshift(value, 8)), 0x00FF00FF)
	wide = bit32.band(bit32.bor(wide, bit32.lshift(wide, 4)), 0x0F0F0F0F)
	wide = bit32.band(bit32.bor(wide, bit32.lshift(wide, 2)), 0x33333333)
	wide = bit32.band(bit32.bor(wide, bit32.lshift(wide, 1)), 0x55555555)
	buffer.writeu32(spread, 4 * value, wide)
	buffer.writeu32(split, 4 * value, compact(value) + compact(bit32.rshift(value, 1)) * 65536)
end

local roundEven, roundOdd = {}, {} -- iota constants, interleaved
do
	local register = 1
	for round = 1, 24 do
		local even, odd = 0, 0
		for step = 0, 6 do -- LFSR x^8+x^6+x^5+x^4+1 -> constant bit 2^step - 1
			register = bit32.bxor(register * 2, register // 128 * 0x71) % 256
			if register % 4 >= 2 then
				if step == 0 then even = 1 else odd += 2 ^ (2 ^ (step - 1) - 1) end
			end
		end
		roundEven[round], roundOdd[round] = even, odd
	end
end

local rotation, destination = table.create(25, 0), table.create(25, 0) -- rho offsets / pi targets, indexed by lane + 1
do
	local x, y = 1, 0
	for step = 1, 24 do
		rotation[x + 5 * y + 1] = step * (step + 1) // 2 % 64
		x, y = y, (2 * x + 3 * y) % 5
	end
	for lane = 0, 24 do
		local x, y = lane % 5, lane // 5
		destination[lane + 1] = 8 * (y + 5 * ((2 * x + 3 * y) % 5))
	end
end

local parity = buffer.create(40) -- column parities, interleaved
local moved = buffer.create(200) -- lanes after theta, rho and pi

local function permute()
	local state, parity, moved = state, parity, moved
	for round = 1, 24 do
		for column = 0, 32, 8 do -- theta: column parities
			buffer.writeu32(parity, column, bit32.bxor(buffer.readu32(state, column), buffer.readu32(state, column + 40), buffer.readu32(state, column + 80), buffer.readu32(state, column + 120), buffer.readu32(state, column + 160)))
			buffer.writeu32(parity, column + 4, bit32.bxor(buffer.readu32(state, column + 4), buffer.readu32(state, column + 44), buffer.readu32(state, column + 84), buffer.readu32(state, column + 124), buffer.readu32(state, column + 164)))
		end
		for x = 0, 4 do
			local left, right = 8 * ((x + 4) % 5), 8 * ((x + 1) % 5)
			local mixEven = bit32.bxor(buffer.readu32(parity, left), bit32.lrotate(buffer.readu32(parity, right + 4), 1)) -- parity[x-1] ^ rotl64(parity[x+1], 1)
			local mixOdd = bit32.bxor(buffer.readu32(parity, left + 4), buffer.readu32(parity, right))
			for lane = x, 24, 5 do -- theta, then rho and pi into `moved`
				local even = bit32.bxor(buffer.readu32(state, 8 * lane), mixEven)
				local odd = bit32.bxor(buffer.readu32(state, 8 * lane + 4), mixOdd)
				local amount, target = rotation[lane + 1], destination[lane + 1]
				local half = amount // 2
				if amount % 2 == 0 then -- even 64-bit rotation: rotate both halves
					buffer.writeu32(moved, target, bit32.lrotate(even, half))
					buffer.writeu32(moved, target + 4, bit32.lrotate(odd, half))
				else -- odd rotation: the halves swap
					buffer.writeu32(moved, target, bit32.lrotate(odd, half + 1))
					buffer.writeu32(moved, target + 4, bit32.lrotate(even, half))
				end
			end
		end
		for row = 0, 160, 40 do -- chi
			for x = 0, 4 do
				local here, next1, next2 = row + 8 * x, row + 8 * ((x + 1) % 5), row + 8 * ((x + 2) % 5)
				buffer.writeu32(state, here, bit32.bxor(buffer.readu32(moved, here), bit32.band(bit32.bnot(buffer.readu32(moved, next1)), buffer.readu32(moved, next2))))
				buffer.writeu32(state, here + 4, bit32.bxor(buffer.readu32(moved, here + 4), bit32.band(bit32.bnot(buffer.readu32(moved, next1 + 4)), buffer.readu32(moved, next2 + 4))))
			end
		end
		buffer.writeu32(state, 0, bit32.bxor(buffer.readu32(state, 0), roundEven[round])) -- iota
		buffer.writeu32(state, 4, bit32.bxor(buffer.readu32(state, 4), roundOdd[round]))
	end
end

local function mix(rate) -- state ^= interleaved block[0, rate)
	local state, block, split = state, block, split
	for offset = 0, rate - 8, 8 do
		local lower = bit32.bor(buffer.readu32(split, 4 * buffer.readu16(block, offset)), bit32.lshift(buffer.readu32(split, 4 * buffer.readu16(block, offset + 2)), 8))
		local upper = bit32.bor(buffer.readu32(split, 4 * buffer.readu16(block, offset + 4)), bit32.lshift(buffer.readu32(split, 4 * buffer.readu16(block, offset + 6)), 8))
		buffer.writeu32(state, offset, bit32.bxor(buffer.readu32(state, offset), bit32.band(lower, 0xFFFF), bit32.lshift(upper, 16)))
		buffer.writeu32(state, offset + 4, bit32.bxor(buffer.readu32(state, offset + 4), bit32.rshift(lower, 16), bit32.band(upper, 0xFFFF0000)))
	end
end

local function extract(rate) -- block[0, rate) = plain bytes of the state
	local state, block, spread = state, block, spread
	for offset = 0, rate - 8, 8 do
		buffer.writeu32(block, offset, bit32.bor(buffer.readu32(spread, 4 * buffer.readu16(state, offset)), bit32.lshift(buffer.readu32(spread, 4 * buffer.readu16(state, offset + 4)), 1)))
		buffer.writeu32(block, offset + 4, bit32.bor(buffer.readu32(spread, 4 * buffer.readu16(state, offset + 2)), bit32.lshift(buffer.readu32(spread, 4 * buffer.readu16(state, offset + 6)), 1)))
	end
end

local function absorb(rate, suffix, input, length) -- reset, absorb input[0, length), pad; block[0, rate) is then output block 0
	local block = block
	buffer.fill(state, 0, 0)
	local offset = 0
	while length - offset >= rate do
		buffer.copy(block, 0, input, offset, rate)
		mix(rate)
		permute()
		offset += rate
	end
	local remaining = length - offset
	buffer.fill(block, 0, 0, rate)
	buffer.copy(block, 0, input, offset, remaining)
	buffer.writeu8(block, remaining, suffix)
	buffer.writeu8(block, rate - 1, bit32.bor(buffer.readu8(block, rate - 1), 0x80))
	mix(rate)
	permute()
	extract(rate)
end

local function squeeze(rate) -- block[0, rate) = next output block
	permute()
	extract(rate)
end

-- SHA3-256: (136, 0x06) / SHA3-512: (72, 0x06) / SHAKE128, SHAKE256: (168 / 136, 0x1F)
local function hash(rate, suffix, input, inputLength, output, outputOffset, outputLength)
	absorb(rate, suffix, input, inputLength)
	for written = 0, outputLength - 1, rate do
		if written > 0 then squeeze(rate) end
		buffer.copy(output, outputOffset + written, block, 0, math.min(rate, outputLength - written))
	end
end

return { block = block, permute = permute, absorb = absorb, squeeze = squeeze, hash = hash }
