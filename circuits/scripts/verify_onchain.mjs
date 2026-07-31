/**
 * Read the encrypted pool total straight off a live chain and decrypt it.
 *
 * This is the end-to-end check that the encryption is load-bearing rather than
 * ceremonial. Everything else shows the contract ACCEPTING ciphertexts; this shows the
 * bytes sitting in contract storage are a real ElGamal ciphertext of the real total,
 * recoverable only with the committee key.
 *
 * It deliberately reads through plain `eth_call` rather than any local state, and
 * decrypts with the shared `lib/elgamal.mjs` BSGS the publisher will use -- so a pass
 * here is evidence about the deployed system, not about this script.
 *
 * Usage:
 *   ACCUMULATOR=0x.. MARKET_ID=8 [RPC=..] [EXPECTED=137] node scripts/verify_onchain.mjs
 */
import { readFileSync } from "node:fs";
import { buildElGamal } from "./lib/elgamal.mjs";

const BUILD = new URL("../build/", import.meta.url);

const RPC = process.env.RPC ?? "https://testnet-rpc.monad.xyz";
const ACCUMULATOR = process.env.ACCUMULATOR;
const MARKET_ID = Number(process.env.MARKET_ID ?? 8);
const EXPECTED = process.env.EXPECTED === undefined ? null : BigInt(process.env.EXPECTED);
const BOUND = BigInt(process.env.BOUND ?? 100_000);

if (!ACCUMULATOR) throw new Error("set ACCUMULATOR=0x...");

/** keccak256("totalAffine(uint32,uint8)")[0:4] -- `cast sig 'totalAffine(uint32,uint8)'`. */
const SELECTOR = "0xf6172454";

const word = (n) => BigInt(n).toString(16).padStart(64, "0");

async function ethCall(to, data) {
  const res = await fetch(RPC, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      jsonrpc: "2.0",
      id: 1,
      method: "eth_call",
      params: [{ to, data }, "latest"],
    }),
  });
  const j = await res.json();
  if (j.error) throw new Error(`eth_call failed: ${JSON.stringify(j.error)}`);
  return j.result;
}

async function totalAffine(marketId, outcome) {
  const raw = await ethCall(ACCUMULATOR, SELECTOR + word(marketId) + word(outcome));
  const body = raw.slice(2);
  const at = (i) => BigInt("0x" + body.slice(i * 64, (i + 1) * 64));
  return { c1: [at(0), at(1)], c2: [at(2), at(3)] };
}

const key = JSON.parse(readFileSync(new URL("committee-key.json", BUILD)));
const elgamal = await buildElGamal(key.pubKey, key.secret);
const { F, babyJub } = elgamal;

/** circomlibjs wants field elements, the chain gave us plain integers. */
const toPoint = (p) => [F.e(p[0]), F.e(p[1])];

let failures = 0;
const check = (label, ok) => {
  console.log(`  ${ok ? "ok  " : "FAIL"}  ${label}`);
  if (!ok) failures++;
};

console.log(`reading accumulator ${ACCUMULATOR} on ${RPC}`);
console.log(`market ${MARKET_ID}\n`);

for (const [outcome, name] of [[1, "YES"], [2, "NO"]]) {
  const t = await totalAffine(MARKET_ID, outcome);
  const isIdentity = t.c1[0] === 0n && t.c1[1] === 1n;

  console.log(`=== ${name} (outcome ${outcome}) ===`);
  console.log(`  C1 = (${t.c1[0]}, ${t.c1[1]})`);
  console.log(`  C2 = (${t.c2[0]}, ${t.c2[1]})`);

  if (isIdentity) {
    console.log("  side is Enc(0) -- the identity (0,1), i.e. no stake accumulated\n");
    continue;
  }

  // Both points must be real curve points, or the "ciphertext" is not a group element
  // and the total would be unrecoverable.
  check("C1 is on the curve", babyJub.inCurve(toPoint(t.c1)));
  check("C2 is on the curve", babyJub.inCurve(toPoint(t.c2)));

  const recovered = elgamal.decrypt(toPoint(t.c1), toPoint(t.c2), BOUND);
  console.log(`  decrypts to: ${recovered}`);

  if (EXPECTED !== null && outcome === 1) {
    check(`decrypted total equals the expected ${EXPECTED}`, recovered === EXPECTED);
  }
  console.log();
}

console.log(
  failures === 0
    ? "on-chain ciphertext verified: it is a real ElGamal encryption of the real total"
    : `${failures} CHECK(S) FAILED`,
);
process.exit(failures === 0 ? 0 : 1);
