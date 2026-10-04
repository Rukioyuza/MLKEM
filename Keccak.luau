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

local function permute() -- fully unrolled: state lives in locals for all 24 rounds
	local state, roundEven, roundOdd = state, roundEven, roundOdd
	local even0, odd0 = buffer.readu32(state, 0), buffer.readu32(state, 4)
	local even1, odd1 = bit32.bnot(buffer.readu32(state, 8)), bit32.bnot(buffer.readu32(state, 12))
	local even2, odd2 = bit32.bnot(buffer.readu32(state, 16)), bit32.bnot(buffer.readu32(state, 20))
	local even3, odd3 = buffer.readu32(state, 24), buffer.readu32(state, 28)
	local even4, odd4 = buffer.readu32(state, 32), buffer.readu32(state, 36)
	local even5, odd5 = buffer.readu32(state, 40), buffer.readu32(state, 44)
	local even6, odd6 = buffer.readu32(state, 48), buffer.readu32(state, 52)
	local even7, odd7 = buffer.readu32(state, 56), buffer.readu32(state, 60)
	local even8, odd8 = bit32.bnot(buffer.readu32(state, 64)), bit32.bnot(buffer.readu32(state, 68))
	local even9, odd9 = buffer.readu32(state, 72), buffer.readu32(state, 76)
	local even10, odd10 = buffer.readu32(state, 80), buffer.readu32(state, 84)
	local even11, odd11 = buffer.readu32(state, 88), buffer.readu32(state, 92)
	local even12, odd12 = bit32.bnot(buffer.readu32(state, 96)), bit32.bnot(buffer.readu32(state, 100))
	local even13, odd13 = buffer.readu32(state, 104), buffer.readu32(state, 108)
	local even14, odd14 = buffer.readu32(state, 112), buffer.readu32(state, 116)
	local even15, odd15 = buffer.readu32(state, 120), buffer.readu32(state, 124)
	local even16, odd16 = buffer.readu32(state, 128), buffer.readu32(state, 132)
	local even17, odd17 = bit32.bnot(buffer.readu32(state, 136)), bit32.bnot(buffer.readu32(state, 140))
	local even18, odd18 = buffer.readu32(state, 144), buffer.readu32(state, 148)
	local even19, odd19 = buffer.readu32(state, 152), buffer.readu32(state, 156)
	local even20, odd20 = bit32.bnot(buffer.readu32(state, 160)), bit32.bnot(buffer.readu32(state, 164))
	local even21, odd21 = buffer.readu32(state, 168), buffer.readu32(state, 172)
	local even22, odd22 = buffer.readu32(state, 176), buffer.readu32(state, 180)
	local even23, odd23 = buffer.readu32(state, 184), buffer.readu32(state, 188)
	local even24, odd24 = buffer.readu32(state, 192), buffer.readu32(state, 196)
	for round = 1, 24 do
		local parityEven0, parityOdd0 = bit32.bxor(even0, even5, even10, even15, even20), bit32.bxor(odd0, odd5, odd10, odd15, odd20)
		local parityEven1, parityOdd1 = bit32.bxor(even1, even6, even11, even16, even21), bit32.bxor(odd1, odd6, odd11, odd16, odd21)
		local parityEven2, parityOdd2 = bit32.bxor(even2, even7, even12, even17, even22), bit32.bxor(odd2, odd7, odd12, odd17, odd22)
		local parityEven3, parityOdd3 = bit32.bxor(even3, even8, even13, even18, even23), bit32.bxor(odd3, odd8, odd13, odd18, odd23)
		local parityEven4, parityOdd4 = bit32.bxor(even4, even9, even14, even19, even24), bit32.bxor(odd4, odd9, odd14, odd19, odd24)
		local mixEven0, mixOdd0 = bit32.bxor(parityEven4, bit32.lrotate(parityOdd1, 1)), bit32.bxor(parityOdd4, parityEven1)
		local mixEven1, mixOdd1 = bit32.bxor(parityEven0, bit32.lrotate(parityOdd2, 1)), bit32.bxor(parityOdd0, parityEven2)
		local mixEven2, mixOdd2 = bit32.bxor(parityEven1, bit32.lrotate(parityOdd3, 1)), bit32.bxor(parityOdd1, parityEven3)
		local mixEven3, mixOdd3 = bit32.bxor(parityEven2, bit32.lrotate(parityOdd4, 1)), bit32.bxor(parityOdd2, parityEven4)
		local mixEven4, mixOdd4 = bit32.bxor(parityEven3, bit32.lrotate(parityOdd0, 1)), bit32.bxor(parityOdd3, parityEven0)
		local movedEven0, movedOdd0 = bit32.bxor(even0, mixEven0), bit32.bxor(odd0, mixOdd0)
		local movedEven1, movedOdd1 = bit32.lrotate(bit32.bxor(even6, mixEven1), 22), bit32.lrotate(bit32.bxor(odd6, mixOdd1), 22)
		local movedEven2, movedOdd2 = bit32.lrotate(bit32.bxor(odd12, mixOdd2), 22), bit32.lrotate(bit32.bxor(even12, mixEven2), 21)
		local movedEven3, movedOdd3 = bit32.lrotate(bit32.bxor(odd18, mixOdd3), 11), bit32.lrotate(bit32.bxor(even18, mixEven3), 10)
		local movedEven4, movedOdd4 = bit32.lrotate(bit32.bxor(even24, mixEven4), 7), bit32.lrotate(bit32.bxor(odd24, mixOdd4), 7)
		local movedEven5, movedOdd5 = bit32.lrotate(bit32.bxor(even3, mixEven3), 14), bit32.lrotate(bit32.bxor(odd3, mixOdd3), 14)
		local movedEven6, movedOdd6 = bit32.lrotate(bit32.bxor(even9, mixEven4), 10), bit32.lrotate(bit32.bxor(odd9, mixOdd4), 10)
		local movedEven7, movedOdd7 = bit32.lrotate(bit32.bxor(odd10, mixOdd0), 2), bit32.lrotate(bit32.bxor(even10, mixEven0), 1)
		local movedEven8, movedOdd8 = bit32.lrotate(bit32.bxor(odd16, mixOdd1), 23), bit32.lrotate(bit32.bxor(even16, mixEven1), 22)
		local movedEven9, movedOdd9 = bit32.lrotate(bit32.bxor(odd22, mixOdd2), 31), bit32.lrotate(bit32.bxor(even22, mixEven2), 30)
		local movedEven10, movedOdd10 = bit32.lrotate(bit32.bxor(odd1, mixOdd1), 1), bit32.bxor(even1, mixEven1)
		local movedEven11, movedOdd11 = bit32.lrotate(bit32.bxor(even7, mixEven2), 3), bit32.lrotate(bit32.bxor(odd7, mixOdd2), 3)
		local movedEven12, movedOdd12 = bit32.lrotate(bit32.bxor(odd13, mixOdd3), 13), bit32.lrotate(bit32.bxor(even13, mixEven3), 12)
		local movedEven13, movedOdd13 = bit32.lrotate(bit32.bxor(even19, mixEven4), 4), bit32.lrotate(bit32.bxor(odd19, mixOdd4), 4)
		local movedEven14, movedOdd14 = bit32.lrotate(bit32.bxor(even20, mixEven0), 9), bit32.lrotate(bit32.bxor(odd20, mixOdd0), 9)
		local movedEven15, movedOdd15 = bit32.lrotate(bit32.bxor(odd4, mixOdd4), 14), bit32.lrotate(bit32.bxor(even4, mixEven4), 13)
		local movedEven16, movedOdd16 = bit32.lrotate(bit32.bxor(even5, mixEven0), 18), bit32.lrotate(bit32.bxor(odd5, mixOdd0), 18)
		local movedEven17, movedOdd17 = bit32.lrotate(bit32.bxor(even11, mixEven1), 5), bit32.lrotate(bit32.bxor(odd11, mixOdd1), 5)
		local movedEven18, movedOdd18 = bit32.lrotate(bit32.bxor(odd17, mixOdd2), 8), bit32.lrotate(bit32.bxor(even17, mixEven2), 7)
		local movedEven19, movedOdd19 = bit32.lrotate(bit32.bxor(even23, mixEven3), 28), bit32.lrotate(bit32.bxor(odd23, mixOdd3), 28)
		local movedEven20, movedOdd20 = bit32.lrotate(bit32.bxor(even2, mixEven2), 31), bit32.lrotate(bit32.bxor(odd2, mixOdd2), 31)
		local movedEven21, movedOdd21 = bit32.lrotate(bit32.bxor(odd8, mixOdd3), 28), bit32.lrotate(bit32.bxor(even8, mixEven3), 27)
		local movedEven22, movedOdd22 = bit32.lrotate(bit32.bxor(odd14, mixOdd4), 20), bit32.lrotate(bit32.bxor(even14, mixEven4), 19)
		local movedEven23, movedOdd23 = bit32.lrotate(bit32.bxor(odd15, mixOdd0), 21), bit32.lrotate(bit32.bxor(even15, mixEven0), 20)
		local movedEven24, movedOdd24 = bit32.lrotate(bit32.bxor(even21, mixEven1), 1), bit32.lrotate(bit32.bxor(odd21, mixOdd1), 1)
		even0, odd0 = bit32.bxor(movedEven0, bit32.bor(movedEven1, movedEven2), roundEven[round]), bit32.bxor(movedOdd0, bit32.bor(movedOdd1, movedOdd2), roundOdd[round])
		even1, odd1 = bit32.bxor(movedEven1, bit32.bor(bit32.bnot(movedEven2), movedEven3)), bit32.bxor(movedOdd1, bit32.bor(bit32.bnot(movedOdd2), movedOdd3))
		even2, odd2 = bit32.bxor(movedEven2, bit32.band(movedEven3, movedEven4)), bit32.bxor(movedOdd2, bit32.band(movedOdd3, movedOdd4))
		even3, odd3 = bit32.bxor(movedEven3, bit32.bor(movedEven4, movedEven0)), bit32.bxor(movedOdd3, bit32.bor(movedOdd4, movedOdd0))
		even4, odd4 = bit32.bxor(movedEven4, bit32.band(movedEven0, movedEven1)), bit32.bxor(movedOdd4, bit32.band(movedOdd0, movedOdd1))
		even5, odd5 = bit32.bxor(movedEven5, bit32.bor(movedEven6, movedEven7)), bit32.bxor(movedOdd5, bit32.bor(movedOdd6, movedOdd7))
		even6, odd6 = bit32.bxor(movedEven6, bit32.band(movedEven7, movedEven8)), bit32.bxor(movedOdd6, bit32.band(movedOdd7, movedOdd8))
		even7, odd7 = bit32.bxor(movedEven7, bit32.bor(movedEven8, bit32.bnot(movedEven9))), bit32.bxor(movedOdd7, bit32.bor(movedOdd8, bit32.bnot(movedOdd9)))
		even8, odd8 = bit32.bxor(movedEven8, bit32.bor(movedEven9, movedEven5)), bit32.bxor(movedOdd8, bit32.bor(movedOdd9, movedOdd5))
		even9, odd9 = bit32.bxor(movedEven9, bit32.band(movedEven5, movedEven6)), bit32.bxor(movedOdd9, bit32.band(movedOdd5, movedOdd6))
		even10, odd10 = bit32.bxor(movedEven10, bit32.bor(movedEven11, movedEven12)), bit32.bxor(movedOdd10, bit32.bor(movedOdd11, movedOdd12))
		even11, odd11 = bit32.bxor(movedEven11, bit32.band(movedEven12, movedEven13)), bit32.bxor(movedOdd11, bit32.band(movedOdd12, movedOdd13))
		even12, odd12 = bit32.bxor(movedEven12, bit32.band(bit32.bnot(movedEven13), movedEven14)), bit32.bxor(movedOdd12, bit32.band(bit32.bnot(movedOdd13), movedOdd14))
		even13, odd13 = bit32.bxor(bit32.bnot(movedEven13), bit32.bor(movedEven14, movedEven10)), bit32.bxor(bit32.bnot(movedOdd13), bit32.bor(movedOdd14, movedOdd10))
		even14, odd14 = bit32.bxor(movedEven14, bit32.band(movedEven10, movedEven11)), bit32.bxor(movedOdd14, bit32.band(movedOdd10, movedOdd11))
		even15, odd15 = bit32.bxor(movedEven15, bit32.band(movedEven16, movedEven17)), bit32.bxor(movedOdd15, bit32.band(movedOdd16, movedOdd17))
		even16, odd16 = bit32.bxor(movedEven16, bit32.bor(movedEven17, movedEven18)), bit32.bxor(movedOdd16, bit32.bor(movedOdd17, movedOdd18))
		even17, odd17 = bit32.bxor(movedEven17, bit32.bor(bit32.bnot(movedEven18), movedEven19)), bit32.bxor(movedOdd17, bit32.bor(bit32.bnot(movedOdd18), movedOdd19))
		even18, odd18 = bit32.bxor(bit32.bnot(movedEven18), bit32.band(movedEven19, movedEven15)), bit32.bxor(bit32.bnot(movedOdd18), bit32.band(movedOdd19, movedOdd15))
		even19, odd19 = bit32.bxor(movedEven19, bit32.bor(movedEven15, movedEven16)), bit32.bxor(movedOdd19, bit32.bor(movedOdd15, movedOdd16))
		even20, odd20 = bit32.bxor(movedEven20, bit32.band(bit32.bnot(movedEven21), movedEven22)), bit32.bxor(movedOdd20, bit32.band(bit32.bnot(movedOdd21), movedOdd22))
		even21, odd21 = bit32.bxor(bit32.bnot(movedEven21), bit32.bor(movedEven22, movedEven23)), bit32.bxor(bit32.bnot(movedOdd21), bit32.bor(movedOdd22, movedOdd23))
		even22, odd22 = bit32.bxor(movedEven22, bit32.band(movedEven23, movedEven24)), bit32.bxor(movedOdd22, bit32.band(movedOdd23, movedOdd24))
		even23, odd23 = bit32.bxor(movedEven23, bit32.bor(movedEven24, movedEven20)), bit32.bxor(movedOdd23, bit32.bor(movedOdd24, movedOdd20))
		even24, odd24 = bit32.bxor(movedEven24, bit32.band(movedEven20, movedEven21)), bit32.bxor(movedOdd24, bit32.band(movedOdd20, movedOdd21))
	end
	buffer.writeu32(state, 0, even0); buffer.writeu32(state, 4, odd0)
	buffer.writeu32(state, 8, bit32.bnot(even1)); buffer.writeu32(state, 12, bit32.bnot(odd1))
	buffer.writeu32(state, 16, bit32.bnot(even2)); buffer.writeu32(state, 20, bit32.bnot(odd2))
	buffer.writeu32(state, 24, even3); buffer.writeu32(state, 28, odd3)
	buffer.writeu32(state, 32, even4); buffer.writeu32(state, 36, odd4)
	buffer.writeu32(state, 40, even5); buffer.writeu32(state, 44, odd5)
	buffer.writeu32(state, 48, even6); buffer.writeu32(state, 52, odd6)
	buffer.writeu32(state, 56, even7); buffer.writeu32(state, 60, odd7)
	buffer.writeu32(state, 64, bit32.bnot(even8)); buffer.writeu32(state, 68, bit32.bnot(odd8))
	buffer.writeu32(state, 72, even9); buffer.writeu32(state, 76, odd9)
	buffer.writeu32(state, 80, even10); buffer.writeu32(state, 84, odd10)
	buffer.writeu32(state, 88, even11); buffer.writeu32(state, 92, odd11)
	buffer.writeu32(state, 96, bit32.bnot(even12)); buffer.writeu32(state, 100, bit32.bnot(odd12))
	buffer.writeu32(state, 104, even13); buffer.writeu32(state, 108, odd13)
	buffer.writeu32(state, 112, even14); buffer.writeu32(state, 116, odd14)
	buffer.writeu32(state, 120, even15); buffer.writeu32(state, 124, odd15)
	buffer.writeu32(state, 128, even16); buffer.writeu32(state, 132, odd16)
	buffer.writeu32(state, 136, bit32.bnot(even17)); buffer.writeu32(state, 140, bit32.bnot(odd17))
	buffer.writeu32(state, 144, even18); buffer.writeu32(state, 148, odd18)
	buffer.writeu32(state, 152, even19); buffer.writeu32(state, 156, odd19)
	buffer.writeu32(state, 160, bit32.bnot(even20)); buffer.writeu32(state, 164, bit32.bnot(odd20))
	buffer.writeu32(state, 168, even21); buffer.writeu32(state, 172, odd21)
	buffer.writeu32(state, 176, even22); buffer.writeu32(state, 180, odd22)
	buffer.writeu32(state, 184, even23); buffer.writeu32(state, 188, odd23)
	buffer.writeu32(state, 192, even24); buffer.writeu32(state, 196, odd24)
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
