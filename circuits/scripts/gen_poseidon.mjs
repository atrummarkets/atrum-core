/**
 * Emit deployable bytecode for circomlib's Poseidon hash contracts.
 *
 * Poseidon is the commitment/nullifier hash for the shielded pool: cheap inside a
 * ZK circuit, where SHA256 or keccak would be ruinous. The tradeoff is that it is
 * comparatively EXPENSIVE on-chain -- it is a pile of field multiplications rather
 * than a native opcode. Every tree insertion pays for `depth` of them, so this cost
 * drives tree depth, batch size, and whether insertion fits the action gas envelope.
 *
 * circomlib generates the contract directly as EVM assembly. We take the creation
 * bytecode here and extract runtime code by deploying it locally, so the runtime
 * code can then be injected into a live-chain `eth_call` for a real measurement.
 *
 * t = arity + 1 (the sponge width). PoseidonT3 hashes 2 inputs, T4 hashes 3, etc.
 */
import { poseidonContract } from "circomlibjs";
import { writeFileSync } from "node:fs";

const ARITIES = [2, 3];
const out = {};

for (const n of ARITIES) {
  const creationCode = poseidonContract.createCode(n);
  const abi = poseidonContract.generateABI(n);
  out[`poseidon${n}`] = { inputs: n, creationCode, abi };
  console.log(`poseidon(${n} inputs): creation bytecode ${(creationCode.length - 2) / 2} bytes`);
}

writeFileSync(
  new URL("../build/poseidon-contracts.json", import.meta.url),
  JSON.stringify(out, null, 2),
);
console.log("wrote build/poseidon-contracts.json");
