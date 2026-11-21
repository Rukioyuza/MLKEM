-- ML-KEM (FIPS 203), deterministic core: the caller supplies all randomness as 32-byte buffers.

local Keccak = require("@self/Keccak")
local Polynomial = require("@self/Polynomial")

---- Bytes ----

local function slice(source: buffer, offset: number, length: number): buffer
	local part = buffer.create(length)
	buffer.copy(part, 0, source, offset, length)
	return part
end

local function halves(bytes: buffer): (buffer, buffer) -- a 64-byte hash as two 32-byte values
	return slice(bytes, 0, 32), slice(bytes, 32, 32)
end

local function concat(...: buffer): buffer
	local length, offset = 0, 0
	for _, part in { ... } do length += buffer.len(part) end
	local joined = buffer.create(length)
	for _, part in { ... } do
		buffer.copy(joined, offset, part)
		offset += buffer.len(part)
	end
	return joined
end

local function equal(left: buffer, right: buffer): boolean -- same lengths; inspects every byte, no early exit
	local difference = 0
	for index = 0, buffer.len(left) - 1 do
		difference = bit32.bor(difference, bit32.bxor(buffer.readu8(left, index), buffer.readu8(right, index)))
	end
	return difference == 0
end

---- Hash functions (FIPS 203 §4.1): arguments are concatenated, each a buffer or a single byte ----

local H, G, XOF = Keccak.sha3_256, Keccak.sha3_512, Keccak.shake128
local function J(...) return Keccak.shake256(...):squeeze(32) end
local function PRF(eta, seed, counter) return Keccak.shake256(seed, counter):squeeze(64 * eta) end

---- Vectors and matrices of polynomials (plain arrays) ----

local function vectorOf(rank: number, entry: (index: number) -> any)
	local entries = table.create(rank)
	for index = 1, rank do entries[index] = entry(index) end
	return entries
end

local function dot(left, right) -- Σ left[i] ∘ right[i], both in the NTT domain
	local sum = left[1] * right[1]
	for index = 2, #left do sum += left[index] * right[index] end
	return sum
end

local function transpose(matrix)
	return vectorOf(#matrix, function(row)
		return vectorOf(#matrix, function(column) return matrix[column][row] end)
	end)
end

---- Scheme ----

local function parameterSet(rank, eta1, eta2, uBits, vBits)
	local keyBytes, vectorBytes = 384 * rank, 32 * uBits * rank
	local ciphertextBytes = vectorBytes + 32 * vBits

	local function noise(seed, eta, counter) -- SamplePolyCBD_η(PRF_η(seed, counter))
		return Polynomial.sampleBinomial(PRF(eta, seed, counter), eta)
	end

	local function sampleMatrix(rho) -- Â[i][j] = SampleNTT(ρ ‖ j ‖ i), with i and j counted from 0
		return vectorOf(rank, function(row)
			return vectorOf(rank, function(column)
				return Polynomial.sampleUniform(XOF(rho, column - 1, row - 1))
			end)
		end)
	end

	local function encodeVector(polynomials, bits)
		return concat(table.unpack(vectorOf(rank, function(index) return polynomials[index]:encode(bits) end)))
	end

	local function decodeVector(bytes, bits) -- `rank` polynomials packed at the start of `bytes`
		return vectorOf(rank, function(index) return Polynomial.decode(bytes, (index - 1) * 32 * bits, bits) end)
	end

	-- K-PKE (FIPS 203 §5)

	local function generateEncryptionKeys(seed) -- K-PKE.KeyGen → encryptionKey = t̂ ‖ ρ, decryptionKey = ŝ
		local rho, sigma = halves(G(seed, rank))
		local matrix = sampleMatrix(rho)
		local secret = vectorOf(rank, function(index) return noise(sigma, eta1, index - 1):ntt() end)
		local public = vectorOf(rank, function(index) -- t̂ = Â∘ŝ + ê
			return dot(matrix[index], secret) + noise(sigma, eta1, rank + index - 1):ntt()
		end)
		return concat(encodeVector(public, 12), rho), encodeVector(secret, 12)
	end

	local function encrypt(encryptionKey, plaintext, coins) -- K-PKE.Encrypt → ciphertext = u ‖ v
		local public, rho = decodeVector(encryptionKey, 12), slice(encryptionKey, keyBytes, 32)
		local matrix = transpose(sampleMatrix(rho))
		local blinding = vectorOf(rank, function(index) return noise(coins, eta1, index - 1):ntt() end) -- ŷ
		local u = vectorOf(rank, function(index) -- u = NTT⁻¹(Âᵀ∘ŷ) + e₁
			return dot(matrix[index], blinding):inverseNtt() + noise(coins, eta2, rank + index - 1)
		end)
		local v = dot(public, blinding):inverseNtt() + noise(coins, eta2, 2 * rank) + Polynomial.decode(plaintext, 0, 1)
		return concat(encodeVector(u, uBits), v:encode(vBits))
	end

	local function decrypt(decryptionKey, ciphertext) -- K-PKE.Decrypt → 32-byte plaintext
		local secret, u = decodeVector(decryptionKey, 12), decodeVector(ciphertext, uBits)
		local v = Polynomial.decode(ciphertext, vectorBytes, vBits)
		local transformed = vectorOf(rank, function(index) return u[index]:ntt() end)
		return (v - dot(secret, transformed):inverseNtt()):encode(1)
	end

	-- ML-KEM (FIPS 203 §6, internal algorithms)

	local function generateKeys(seed, rejectionSeed) -- → encapsulationKey, decapsulationKey = ŝ ‖ ek ‖ H(ek) ‖ z
		assert(buffer.len(seed) == 32 and buffer.len(rejectionSeed) == 32, "bad seed length")
		local encapsulationKey, decryptionKey = generateEncryptionKeys(seed)
		return encapsulationKey, concat(decryptionKey, encapsulationKey, H(encapsulationKey), rejectionSeed)
	end

	local function encapsulate(encapsulationKey, randomness) -- → sharedSecret, ciphertext
		assert(buffer.len(encapsulationKey) == keyBytes + 32 and buffer.len(randomness) == 32, "bad input length")
		local sharedSecret, coins = halves(G(randomness, H(encapsulationKey)))
		return sharedSecret, encrypt(encapsulationKey, randomness, coins)
	end

	local function decapsulate(decapsulationKey, ciphertext) -- → sharedSecret; implicit rejection on re-encryption mismatch
		assert(buffer.len(decapsulationKey) == 2 * keyBytes + 96 and buffer.len(ciphertext) == ciphertextBytes, "bad input length")
		local decryptionKey = slice(decapsulationKey, 0, keyBytes)
		local encapsulationKey = slice(decapsulationKey, keyBytes, keyBytes + 32)
		local keyHash = slice(decapsulationKey, 2 * keyBytes + 32, 32)
		local rejectionSeed = slice(decapsulationKey, 2 * keyBytes + 64, 32)

		local plaintext = decrypt(decryptionKey, ciphertext)
		local sharedSecret, coins = halves(G(plaintext, keyHash))
		local rejection = J(rejectionSeed, ciphertext) -- always computed
		return if equal(ciphertext, encrypt(encapsulationKey, plaintext, coins)) then sharedSecret else rejection
	end

	return { generateKeys = generateKeys, encapsulate = encapsulate, decapsulate = decapsulate }
end

return {
	[512] = parameterSet(2, 3, 2, 10, 4),
	[768] = parameterSet(3, 2, 2, 10, 4),
	[1024] = parameterSet(4, 2, 2, 11, 5),
}
