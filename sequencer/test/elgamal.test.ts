/**
 * Proves `src/elgamal.ts` agrees with `circuits/scripts/lib/elgamal.mjs`.
 *
 * The publisher is a re-implementation, and a re-implementation of a security primitive is
 * only acceptable if it is pinned to the original's own recorded outputs. The decisive case
 * is the `yes` ciphertext in `e2e-fixtures.json`: it came out of a REAL `bet_encrypted`
 * proof, not from JS, so decrypting it correctly exercises circuit, contract and publisher
 * agreeing on the same encoding.
 */
import { describe, it, expect, beforeAll } from "vitest";
import { readFileSync } from "node:fs";
import { buildDecryptor, SUBGROUP_ORDER, type Point, type Decryptor } from "../src/elgamal.ts";

const BUILD = new URL("../../circuits/build/", import.meta.url).pathname;
const read = (f: string) => JSON.parse(readFileSync(BUILD + f, "utf8"));

describe("ElGamal decryption", () => {
  let dec: Decryptor;
  let e2e: any;

  beforeAll(async () => {
    const key = read("committee-key.json");
    e2e = read("e2e-fixtures.json");
    dec = await buildDecryptor(BigInt(key.secret));
  }, 60_000);

  const pt = (p: any): Point => [BigInt(p[0]), BigInt(p[1])];

  it("recovers the total from a ciphertext produced by a real bet_encrypted proof", () => {
    // 100 + 37, encrypted independently and summed homomorphically. Never decrypted
    // in between -- which is the whole claim.
    expect(dec.decrypt(pt(e2e.yes.c1), pt(e2e.yes.c2), 1024n)).toBe(BigInt(e2e.total));
  });

  it("agrees with the reference implementation's recorded totals per side", () => {
    expect(dec.decrypt(pt(e2e.yes.c1), pt(e2e.yes.c2), 1024n)).toBe(BigInt(e2e.expected.yesTotal));
    expect(dec.decrypt(pt(e2e.no.c1), pt(e2e.no.c2), 1024n)).toBe(BigInt(e2e.expected.noTotal));
  });

  it("returns 0 for an encryption of zero rather than failing", () => {
    // The NO side had no bets. Enc(0) is the identity after the [s]C1 subtraction, which is
    // the edge case the complete addition law exists to handle -- and the one a naive
    // BSGS loop misses, because the table is built starting FROM the identity.
    expect(dec.decrypt(pt(e2e.no.c1), pt(e2e.no.c2), 1024n)).toBe(0n);
  });

  it("throws rather than returning a wrong answer when m exceeds the bound", () => {
    // A silent wrong answer here would publish a wrong ratio forever. It must fail loudly.
    expect(() => dec.decrypt(pt(e2e.yes.c1), pt(e2e.yes.c2), 4n)).toThrow(/outside the searched bound/);
  });

  it("rejects a secret outside the subgroup instead of decrypting to garbage", async () => {
    await expect(buildDecryptor(0n)).rejects.toThrow(/outside/);
    await expect(buildDecryptor(SUBGROUP_ORDER)).rejects.toThrow(/outside/);
    await expect(buildDecryptor(-1n)).rejects.toThrow(/outside/);
  });

  it("is deterministic -- the same ciphertext always gives the same total", () => {
    const a = dec.decrypt(pt(e2e.yes.c1), pt(e2e.yes.c2), 1024n);
    const b = dec.decrypt(pt(e2e.yes.c1), pt(e2e.yes.c2), 1024n);
    expect(a).toBe(b);
  });
});
