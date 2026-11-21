<h1 align="left">ML-KEM · Luau</h1>
 
<p align="left">
<img src="https://img.shields.io/badge/Post--Quantum-Cryptography-181717?style=for-the-badge&logo=letsencrypt&logoColor=white" />
<img src="https://img.shields.io/badge/NIST-FIPS_203-181717?style=for-the-badge" />
<img src="https://img.shields.io/badge/Pure-Luau-181717?style=for-the-badge&logo=roblox&logoColor=white" />
</p>
A boring, somewhat readable implementation of ML-KEM (NIST FIPS 203) in pure Luau.
 
## About
 
ML-KEM (Module-Lattice-Based Key-Encapsulation Mechanism) is the post-quantum key exchange NIST standardised as FIPS 203.
 
This is a boring re-implementation:
 
It is not the first ML-KEM for Luau. [rbx-cryptography](https://github.com/daily3014/rbx-cryptography) has had ML-KEM-512, 768 and 1024 since August 2025 and is considerably faster (see below). If you need ML-KEM in production, use that over this lying repo.
 
## Correctness
 
Tested against the NIST ACVP vectors for FIPS 203 (`ML-KEM-keyGen-FIPS203` and `ML-KEM-encapDecap-FIPS203`), all three parameter sets:
 
| Test | Result |
|---|---|
| Key generation | 75 / 75 |
| Encapsulation | 75 / 75 |
| Decapsulation, valid and modified ciphertexts | 30 / 30 |
| Rejects malformed encapsulation keys | 15 / 15 |
| Rejects decapsulation keys with a modified hash | 0 / 15 |
 
There is not decapsulation-key hash check from FIPS 203 which rbx crypto does have
 
## Performance

| Operation | Time |
|---|---|
| ML-KEM-512 generateKeys | 5.2 ms |
| ML-KEM-512 encapsulate | 5.2 ms |
| ML-KEM-512 decapsulate | 5.6 ms |

### Compared with rbx-cryptography

| Operation | rbx-cryptography | Ratio |
|---|---|---|
| ML-KEM-512 generateKeys | 28.9 µs | 180x slower |
| ML-KEM-512 encapsulate | 33 µs | 158x slower |
| ML-KEM-512 decapsulate | 51.8 µs | 108x slower |
 
rbx-cryptography also passes all 210 of the ACVP cases above, including the decapsulation-key hash check.
 
## Usage
Don't use it, use https://github.com/daily3014/rbx-cryptography its faster, actually passes all tests and more secure
 
