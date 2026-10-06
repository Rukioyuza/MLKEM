--!native
--!optimize 2
-- R_q = Z_q[X]/(X²⁵⁶+1): polynomials are 256 × u16 buffers, coefficients in [0, q).

local MODULUS = 3329

local zetas = table.create(127, 0) -- zetas[bitReverse7(exponent)] = 17^exponent mod q
do
	local power = 1
	for exponent = 1, 127 do
		local reversed = 0
		for position = 0, 6 do reversed += reversed + bit32.extract(exponent, position) end
		power = power * 17 % MODULUS
		zetas[reversed] = power
	end
end

local function forwardTransform(polynomial) -- in place, Cooley-Tukey; span is in bytes
	local zetas = zetas
	local zetaIndex, span = 1, 256
	while span >= 4 do
		for start = 0, 511, 2 * span do
			local zeta = zetas[zetaIndex]
			zetaIndex += 1
			for offset = start, start + span - 2, 2 do
				local upper = zeta * buffer.readu16(polynomial, offset + span) % MODULUS
				local lower = buffer.readu16(polynomial, offset)
				buffer.writeu16(polynomial, offset, (lower + upper) % MODULUS)
				buffer.writeu16(polynomial, offset + span, (lower - upper) % MODULUS)
			end
		end
		span /= 2
	end
	return polynomial
end

local function inverseTransform(polynomial) -- in place, Gentleman-Sande; 3303 = 128⁻¹ mod q
	local zetas = zetas
	local zetaIndex, span = 127, 4
	while span <= 256 do
		for start = 0, 511, 2 * span do
			local zeta = zetas[zetaIndex]
			zetaIndex -= 1
			for offset = start, start + span - 2, 2 do
				local lower, upper = buffer.readu16(polynomial, offset), buffer.readu16(polynomial, offset + span)
				buffer.writeu16(polynomial, offset, (lower + upper) % MODULUS)
				buffer.writeu16(polynomial, offset + span, zeta * (upper - lower) % MODULUS)
			end
		end
		span *= 2
	end
	for offset = 0, 510, 2 do buffer.writeu16(polynomial, offset, buffer.readu16(polynomial, offset) * 3303 % MODULUS) end
	return polynomial
end

local function multiplyAccumulate(sum, left, right) -- sum += left ∘ right over 128 × Z_q[X]/(X² ∓ ζ); stays < 2⁵³
	local zetas = zetas
	for offset = 0, 508, 4 do
		local zeta = if offset % 8 == 0 then zetas[64 + offset // 8] else -zetas[64 + offset // 8]
		local left0, left1 = buffer.readu16(left, offset), buffer.readu16(left, offset + 2)
		local right0, right1 = buffer.readu16(right, offset), buffer.readu16(right, offset + 2)
		buffer.writeu16(sum, offset, (buffer.readu16(sum, offset) + left0 * right0 + left1 * right1 * zeta) % MODULUS)
		buffer.writeu16(sum, offset + 2, (buffer.readu16(sum, offset + 2) + left0 * right1 + left1 * right0) % MODULUS)
	end
end

local function add(polynomial, other, sign) -- polynomial += sign · other, in place
	sign = sign or 1
	for offset = 0, 510, 2 do
		buffer.writeu16(polynomial, offset, (buffer.readu16(polynomial, offset) + sign * buffer.readu16(other, offset)) % MODULUS)
	end
	return polynomial
end

local function encode(output, byteOffset, polynomial, bits) -- ByteEncode ∘ Compress (12 bits: raw), little-endian bit packing
	local scale = 2 ^ bits
	local pending, pendingBits = 0, 0
	for offset = 0, 510, 2 do
		local value = buffer.readu16(polynomial, offset)
		if bits < 12 then value = (value * scale + 1664) // MODULUS % scale end
		pending += bit32.lshift(value, pendingBits)
		pendingBits += bits
		while pendingBits >= 8 do
			buffer.writeu8(output, byteOffset, bit32.band(pending, 0xFF))
			pending = bit32.rshift(pending, 8)
			pendingBits -= 8
			byteOffset += 1
		end
	end
end

local function decode(polynomial, input, byteOffset, bits) -- Decompress ∘ ByteDecode (12 bits: raw, canonical only)
	local scale, lastRead = 2 ^ bits, buffer.len(input) - 4 -- clamp so the 4-byte read never leaves the buffer
	local mask = scale - 1
	for index = 0, 255 do
		local bitOffset = byteOffset * 8 + index * bits
		local readOffset = math.min(bitOffset // 8, lastRead)
		local value = bit32.band(bit32.rshift(buffer.readu32(input, readOffset), bitOffset - readOffset * 8), mask)
		if bits == 12 and value >= MODULUS then error("non-canonical coefficient") end
		buffer.writeu16(polynomial, 2 * index, if bits < 12 then (value * MODULUS + scale / 2) // scale else value)
	end
	return polynomial
end

return {
	forwardTransform = forwardTransform, inverseTransform = inverseTransform,
	multiplyAccumulate = multiplyAccumulate, add = add, encode = encode, decode = decode,
}
