pragma circom 2.1.9;

include "elgamal.circom";

/// Phase 0 gas probe -- variant A: committee key passed as a PUBLIC INPUT.
///
/// Public signals: pubKey[2] + c1[2] + c2[2] = 6.
///
/// Operationally the nicer of the two variants: the committee key is protocol
/// state, so it can be rotated without a new circuit and a new trusted setup.
/// The cost is two extra public inputs, and each public input costs one `ecMul`
/// (measured 30,000 gas on Monad, 5x Ethereum) plus one `ecAdd` to fold into vk_x.
///
/// Variant B (`probe_fixed_key.circom`) trades that flexibility for 4 public
/// signals. Both are measured so the trade is priced, not guessed.
component main {public [pubKey]} = ElGamalEncrypt(40);
