-- Polynomials in Z_q[X]/(X²⁵⁶ + 1), q = 3329 (FIPS 203 §4). Immutable: every operation returns a new polynomial.
-- A polynomial is a table of 256 coefficients in [0, q), indexed 0..255 as in the specification.
-- `+` and `-` work in either domain; `*` multiplies two polynomials that are both in the NTT domain.

local MODULUS = 3329 -- q
local ROOT = 17 -- ζ, a primitive 256th root of unity mod q

local Polynomial = {}
Polynomial.__index = Polynomial

local function build(coefficient: (index: number) -> number) -- Σ coefficient(i)·Xⁱ, each reduced mod q
	local polynomial = setmetatable({}, Polynomial)
	for index = 0, 255 do polynomial[index] = coefficient(index) % MODULUS end
	return polynomial
end

---- Arithmetic ----

function Polynomial.__add(left, right)
	return build(function(index) return left[index] + right[index] end)
end

function Polynomial.__sub(left, right)
	return build(function(index) return left[index] - right[index] end)
end

local function bitReverse7(value: number): number
	local reversed = 0
	for _ = 1, 7 do
		reversed, value = 2 * reversed + value % 2, value // 2
	end
	return reversed
end

local function rootPower(exponent: number): number -- ζ^exponent mod q
	local power = 1
	for _ = 1, exponent do power = power * ROOT % MODULUS end
	return power
end

local zetas, gammas = {}, {} -- zetas[i] = ζ^BitRev7(i) for the transforms, gammas[i] = ζ^(2·BitRev7(i) + 1) for products
for index = 0, 127 do
	zetas[index] = rootPower(bitReverse7(index))
	gammas[index] = rootPower(2 * bitReverse7(index) + 1)
end

function Polynomial:ntt() -- NTT (Algorithm 9)
	local result, zetaIndex, length = table.clone(self), 1, 128
	while length >= 2 do
		for start = 0, 255, 2 * length do
			local zeta = zetas[zetaIndex]
			zetaIndex += 1
			for index = start, start + length - 1 do
				local low, high = result[index], zeta * result[index + length]
				result[index], result[index + length] = (low + high) % MODULUS, (low - high) % MODULUS
			end
		end
		length //= 2
	end
	return result
end

function Polynomial:inverseNtt() -- NTT⁻¹ (Algorithm 10); 3303 = 128⁻¹ mod q
	local result, zetaIndex, length = table.clone(self), 127, 2
	while length <= 128 do
		for start = 0, 255, 2 * length do
			local zeta = zetas[zetaIndex]
			zetaIndex -= 1
			for index = start, start + length - 1 do
				local low, high = result[index], result[index + length]
				result[index], result[index + length] = (low + high) % MODULUS, zeta * (high - low) % MODULUS
			end
		end
		length *= 2
	end
	return build(function(index) return result[index] * 3303 end)
end

function Polynomial.__mul(left, right) -- MultiplyNTTs (Algorithms 11-12): 128 products modulo X² − γ
	return build(function(index)
		local even = index - index % 2
		local a0, a1, b0, b1 = left[even], left[even + 1], right[even], right[even + 1]
		return if index % 2 == 0 then a0 * b0 + a1 * b1 * gammas[even // 2] else a0 * b1 + a1 * b0
	end)
end

---- Encoding: d-bit coefficients, packed little-endian. d = 12 is exact; d < 12 is lossy compression ----

local function compress(value: number, bits: number): number -- round(2ᵈ/q · value) mod 2ᵈ
	return if bits == 12 then value else (value * 2 ^ bits + MODULUS // 2) // MODULUS % 2 ^ bits
end

local function decompress(value: number, bits: number): number -- round(q/2ᵈ · value)
	return if bits == 12 then value else (value * MODULUS + 2 ^ (bits - 1)) // 2 ^ bits
end

function Polynomial:encode(bits: number): buffer -- ByteEncode_d ∘ Compress_d → 32·d bytes
	local bytes = buffer.create(32 * bits)
	for index = 0, 255 do
		buffer.writebits(bytes, index * bits, bits, compress(self[index], bits))
	end
	return bytes
end

function Polynomial.decode(bytes: buffer, offset: number, bits: number) -- Decompress_d ∘ ByteDecode_d
	return build(function(index)
		local value = buffer.readbits(bytes, 8 * offset + index * bits, bits)
		assert(bits < 12 or value < MODULUS, "non-canonical coefficient")
		return decompress(value, bits)
	end)
end

---- Sampling ----

function Polynomial.sampleUniform(stream) -- SampleNTT (Algorithm 7): keep 12-bit candidates below q
	local accepted = {}
	while #accepted < 256 do
		local bytes = stream:squeeze(3)
		for _, candidate in { buffer.readbits(bytes, 0, 12), buffer.readbits(bytes, 12, 12) } do
			if candidate < MODULUS then table.insert(accepted, candidate) end
		end
	end
	return build(function(index) return accepted[index + 1] end)
end

function Polynomial.sampleBinomial(bytes: buffer, eta: number) -- SamplePolyCBD_η (Algorithm 8), from 64·η bytes
	local function countBits(first: number): number -- set bits among `eta` bits starting at bit `first`
		local count = 0
		for bit = first, first + eta - 1 do count += buffer.readbits(bytes, bit, 1) end
		return count
	end
	return build(function(index)
		return countBits(2 * eta * index) - countBits(2 * eta * index + eta)
	end)
end

return Polynomial
