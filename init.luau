--!native
--!optimize 2
-- ML-KEM (FIPS 203), deterministic core: the caller supplies all randomness as 32-byte buffers.
-- All working memory is module-level scratch; only returned keys, ciphertexts and secrets are allocated.

local Keccak = require("@self/Keccak")
local Polynomial = require("@self/Polynomial")
local MODULUS = 3329

local message, expanded = buffer.create(1600), buffer.create(64) -- hash input; SHA3-512 output (ρ‖σ or key‖coins)
local matrixSeed, noiseSeed, noiseBytes = buffer.create(34), buffer.create(33), buffer.create(196)
local sampled, noise, scalar, candidate = buffer.create(512), buffer.create(512), buffer.create(512), buffer.create(1568)
local secrets, products = {}, {} -- vectors, sized for the largest rank
for index = 1, 4 do secrets[index], products[index] = buffer.create(512), buffer.create(512) end

---- Sampling ----

local function sampleUniform() -- sampled ← SHAKE128(matrixSeed): two 12-bit candidates per 3 bytes of each output block
	local sampled, block, squeeze = sampled, Keccak.block, Keccak.squeeze
	Keccak.absorb(168, 0x1F, matrixSeed, 34)
	local filled = 0
	while true do
		for offset = 0, 165, 3 do
			local word = buffer.readu32(block, offset)
			local first, second = bit32.band(word, 0xFFF), bit32.band(bit32.rshift(word, 12), 0xFFF)
			if first < MODULUS then
				buffer.writeu16(sampled, filled, first)
				filled += 2
				if filled == 512 then return end
			end
			if second < MODULUS then
				buffer.writeu16(sampled, filled, second)
				filled += 2
				if filled == 512 then return end
			end
		end
		squeeze(168)
	end
end

local function sampleNoise(polynomial, eta, counter) -- centered binomial from SHAKE256(σ ‖ counter), bit-sliced popcounts
	local noiseBytes = noiseBytes
	buffer.writeu8(noiseSeed, 32, counter)
	Keccak.hash(136, 0x1F, noiseSeed, 33, noiseBytes, 0, 64 * eta)
	local pattern = if eta == 2 then 0x55555555 else 0x00249249 -- one bit per eta-bit field
	local chunkBytes, lastShift, mask = if eta == 2 then 4 else 3, if eta == 2 then 28 else 18, 2 ^ eta - 1
	local offset = 0
	for byteOffset = 0, 64 * eta - chunkBytes, chunkBytes do
		local word = buffer.readu32(noiseBytes, byteOffset)
		local sums = bit32.band(word, pattern) + bit32.band(bit32.rshift(word, 1), pattern) -- per-field popcount
		if eta == 3 then sums += bit32.band(bit32.rshift(word, 2), pattern) end
		for shift = 0, lastShift, 2 * eta do
			local plus, minus = bit32.band(bit32.rshift(sums, shift), mask), bit32.band(bit32.rshift(sums, shift + eta), mask)
			buffer.writeu16(polynomial, offset, (plus - minus) % MODULUS)
			offset += 2
		end
	end
	return polynomial
end

local function multiplyMatrix(rank, transposed) -- products ← Â∘secrets (or Âᵀ), Â[row][column] = XOF(ρ ‖ column ‖ row)
	local matrixSeed, sampled, secrets, products = matrixSeed, sampled, secrets, products
	local sampleUniform, multiplyAccumulate = sampleUniform, Polynomial.multiplyAccumulate
	for row = 1, rank do
		buffer.fill(products[row], 0, 0)
		for column = 1, rank do
			buffer.writeu8(matrixSeed, 32, (if transposed then row else column) - 1)
			buffer.writeu8(matrixSeed, 33, (if transposed then column else row) - 1)
			sampleUniform()
			multiplyAccumulate(products[row], sampled, secrets[column])
		end
	end
end

---- Scheme ----

local function parameterSet(rank, eta1, eta2, uBits, vBits)
	local keyBytes, vectorBytes = 384 * rank, 32 * uBits * rank
	local ciphertextBytes = vectorBytes + 32 * vBits

	local function encrypt(ciphertext, key, keyOffset, plaintext) -- K-PKE.Encrypt, coins = expanded[32, 64)
		buffer.copy(noiseSeed, 0, expanded, 32, 32)
		buffer.copy(matrixSeed, 0, key, keyOffset + keyBytes, 32)
		for index = 1, rank do Polynomial.forwardTransform(sampleNoise(secrets[index], eta1, index - 1)) end
		multiplyMatrix(rank, true)
		buffer.fill(scalar, 0, 0)
		for index = 1, rank do
			local vectorTerm = Polynomial.add(Polynomial.inverseTransform(products[index]), sampleNoise(noise, eta2, rank + index - 1))
			Polynomial.encode(ciphertext, (index - 1) * 32 * uBits, vectorTerm, uBits)
			Polynomial.multiplyAccumulate(scalar, Polynomial.decode(sampled, key, keyOffset + (index - 1) * 384, 12), secrets[index])
		end
		Polynomial.add(Polynomial.inverseTransform(scalar), sampleNoise(noise, eta2, 2 * rank))
		Polynomial.encode(ciphertext, vectorBytes, Polynomial.add(scalar, Polynomial.decode(noise, plaintext, 0, 1)), vBits)
	end

	local function generateKeys(seed, rejectionSeed) -- → encapsulationKey, decapsulationKey = ŝ ‖ ek ‖ H(ek) ‖ z
		assert(buffer.len(seed) == 32 and buffer.len(rejectionSeed) == 32, "bad seed length")
		buffer.copy(message, 0, seed)
		buffer.writeu8(message, 32, rank)
		Keccak.hash(72, 0x06, message, 33, expanded, 0, 64) -- ρ ‖ σ
		buffer.copy(matrixSeed, 0, expanded, 0, 32)
		buffer.copy(noiseSeed, 0, expanded, 32, 32)
		local encapsulationKey, decapsulationKey = buffer.create(keyBytes + 32), buffer.create(2 * keyBytes + 96)
		for index = 1, rank do
			local secret = Polynomial.forwardTransform(sampleNoise(secrets[index], eta1, index - 1))
			Polynomial.encode(decapsulationKey, (index - 1) * 384, secret, 12)
		end
		multiplyMatrix(rank, false)
		for index = 1, rank do
			local errorTerm = Polynomial.forwardTransform(sampleNoise(noise, eta1, rank + index - 1))
			Polynomial.encode(encapsulationKey, (index - 1) * 384, Polynomial.add(products[index], errorTerm), 12)
		end
		buffer.copy(encapsulationKey, keyBytes, expanded, 0, 32)
		buffer.copy(decapsulationKey, keyBytes, encapsulationKey)
		Keccak.hash(136, 0x06, encapsulationKey, keyBytes + 32, decapsulationKey, 2 * keyBytes + 32, 32)
		buffer.copy(decapsulationKey, 2 * keyBytes + 64, rejectionSeed)
		return encapsulationKey, decapsulationKey
	end

	local function encapsulate(encapsulationKey, randomness) -- → sharedSecret, ciphertext
		assert(buffer.len(encapsulationKey) == keyBytes + 32 and buffer.len(randomness) == 32, "bad input length")
		buffer.copy(message, 0, randomness)
		Keccak.hash(136, 0x06, encapsulationKey, keyBytes + 32, message, 32, 32)
		Keccak.hash(72, 0x06, message, 64, expanded, 0, 64) -- sharedSecret ‖ coins
		local sharedSecret, ciphertext = buffer.create(32), buffer.create(ciphertextBytes)
		buffer.copy(sharedSecret, 0, expanded, 0, 32)
		encrypt(ciphertext, encapsulationKey, 0, randomness)
		return sharedSecret, ciphertext
	end

	local function decapsulate(decapsulationKey, ciphertext) -- → sharedSecret; implicit rejection on re-encryption mismatch
		assert(buffer.len(decapsulationKey) == 2 * keyBytes + 96 and buffer.len(ciphertext) == ciphertextBytes, "bad input length")
		local message, candidate = message, candidate
		buffer.fill(scalar, 0, 0)
		for index = 1, rank do
			Polynomial.forwardTransform(Polynomial.decode(noise, ciphertext, (index - 1) * 32 * uBits, uBits))
			Polynomial.multiplyAccumulate(scalar, Polynomial.decode(sampled, decapsulationKey, (index - 1) * 384, 12), noise)
		end
		Polynomial.add(Polynomial.decode(noise, ciphertext, vectorBytes, vBits), Polynomial.inverseTransform(scalar), -1)
		Polynomial.encode(message, 0, noise, 1)
		buffer.copy(message, 32, decapsulationKey, 2 * keyBytes + 32, 32)
		Keccak.hash(72, 0x06, message, 64, expanded, 0, 64) -- sharedSecret ‖ coins
		encrypt(candidate, decapsulationKey, keyBytes, message)
		local difference = 0
		for offset = 0, ciphertextBytes - 4, 4 do
			difference = bit32.bor(difference, bit32.bxor(buffer.readu32(ciphertext, offset), buffer.readu32(candidate, offset)))
		end
		local sharedSecret = buffer.create(32) -- rejection value J(z ‖ ciphertext), always computed
		buffer.copy(message, 0, decapsulationKey, 2 * keyBytes + 64, 32)
		buffer.copy(message, 32, ciphertext)
		Keccak.hash(136, 0x1F, message, 32 + ciphertextBytes, sharedSecret, 0, 32)
		if difference == 0 then buffer.copy(sharedSecret, 0, expanded, 0, 32) end
		return sharedSecret
	end

	return { generateKeys = generateKeys, encapsulate = encapsulate, decapsulate = decapsulate }
end

return {
	[512] = parameterSet(2, 3, 2, 10, 4),
	[768] = parameterSet(3, 2, 2, 10, 4),
	[1024] = parameterSet(4, 2, 2, 11, 5),
}
