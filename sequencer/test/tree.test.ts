/**
 * The mirror must agree with the chain.
 *
 * These roots are not self-generated. `circuits/build/action-fixtures.json` carries the
 * batches and roots that `contracts/test/ShieldedPool.t.sol` asserts equal to the roots
 * `IncrementalMerkleTree.sol` actually computed on-chain
 * (`test_contractRootMatchesProverRoot`). So checking the TypeScript mirror against this
 * file is a transitive check against the contract, not a check of JS against itself.
 *
 * This is the failure this suite exists to catch: a mirror that drifts hands users
 * Merkle paths for a tree shape that never existed. Every resulting proof fails
 * on-chain with no diagnostic, and no gas number looks wrong.
 */
import { describe, it, expect, beforeAll } from "vitest";
import { readFileSync } from "node:fs";
import { CommitmentTree, initHasher, hash2, BATCH_SIZE, ZERO_VALUE } from "../src/tree.ts";
import { RelayerPool, RELAYER_COUNT } from "../src/relayers.ts";

const FIXTURES = new URL("../../circuits/build/action-fixtures.json", import.meta.url);

interface Fixtures {
  batch1: string[];
  batch2: string[];
  rootAfterBatch1: string;
  rootAfterBatch2: string;
  bet: { root: string };
  redeem: { root: string };
}

let fixtures: Fixtures;

beforeAll(async () => {
  await initHasher();
  fixtures = JSON.parse(readFileSync(FIXTURES, "utf8"));
});

describe("CommitmentTree", () => {
  it("reproduces the on-chain root after the first batch", () => {
    const tree = new CommitmentTree();
    tree.insertBatch(fixtures.batch1.map(BigInt));

    expect(tree.root()).toBe(BigInt(fixtures.rootAfterBatch1));
  });

  it("reproduces the on-chain root after consecutive batches", () => {
    const tree = new CommitmentTree();
    tree.insertBatch(fixtures.batch1.map(BigInt));
    tree.insertBatch(fixtures.batch2.map(BigInt));

    expect(tree.root()).toBe(BigInt(fixtures.rootAfterBatch2));
  });

  it("serves the root the bet proof was built against", () => {
    const tree = new CommitmentTree();
    tree.insertBatch(fixtures.batch1.map(BigInt));

    expect(tree.root()).toBe(BigInt(fixtures.bet.root));
  });

  it("serves the root the redeem proof was built against", () => {
    const tree = new CommitmentTree();
    tree.insertBatch(fixtures.batch1.map(BigInt));
    tree.insertBatch(fixtures.batch2.map(BigInt));

    expect(tree.root()).toBe(BigInt(fixtures.redeem.root));
  });

  it("finds a queued commitment and returns a well-formed path", () => {
    const tree = new CommitmentTree();
    tree.insertBatch(fixtures.batch1.map(BigInt));

    const target = BigInt(fixtures.batch1[0]!);
    const index = tree.indexOf(target);
    expect(index).toBe(0);

    const { pathElements, pathIndices } = tree.path(index);
    expect(pathElements).toHaveLength(20);
    expect(pathIndices).toHaveLength(20);
    for (const bit of pathIndices) expect([0n, 1n]).toContain(bit);
  });

  /**
   * The path must actually reconstruct the root. A path of the right SHAPE that does
   * not hash back to the root is the exact bug that produces silent proof failures.
   */
  it("path recomputes the root, leaf by leaf", () => {
    const tree = new CommitmentTree();
    tree.insertBatch(fixtures.batch1.map(BigInt));

    const index = 5;
    const leaf = BigInt(fixtures.batch1[index]!);
    const { pathElements, pathIndices } = tree.path(index);

    let node = leaf;
    for (let d = 0; d < pathElements.length; d++) {
      node =
        pathIndices[d] === 1n
          ? hash2(pathElements[d]!, node)
          : hash2(node, pathElements[d]!);
    }

    expect(node).toBe(tree.root());
  });

  it("refuses a partial batch", () => {
    const tree = new CommitmentTree();
    expect(() => tree.insertBatch([1n, 2n, 3n])).toThrow(/exactly 64/);
  });

  it("uses a non-zero empty-leaf value", () => {
    // With zero, "empty slot" and "note committing to zero" would be the same digest.
    expect(ZERO_VALUE).not.toBe(0n);
  });

  it("has an empty root that no batch can collide with", () => {
    const tree = new CommitmentTree();
    const empty = tree.root();
    tree.insertBatch(fixtures.batch1.map(BigInt));
    expect(tree.root()).not.toBe(empty);
  });

  it("agrees with itself across rebuild -- resync must be deterministic", () => {
    const a = new CommitmentTree();
    a.insertBatch(fixtures.batch1.map(BigInt));
    a.insertBatch(fixtures.batch2.map(BigInt));

    const b = new CommitmentTree();
    b.insertBatch(fixtures.batch1.map(BigInt));
    b.insertBatch(fixtures.batch2.map(BigInt));

    expect(a.root()).toBe(b.root());
    expect(a.size).toBe(BATCH_SIZE * 2);
  });
});

describe("RelayerPool", () => {
  const MNEMONIC = "test test test test test test test test test test test junk";

  it("derives the configured number of distinct accounts", () => {
    const pool = new RelayerPool(MNEMONIC);
    expect(pool.size).toBe(RELAYER_COUNT);
    expect(new Set(pool.addresses).size).toBe(RELAYER_COUNT);
  });

  it("rotates round-robin so no address submits twice in a row", () => {
    const pool = new RelayerPool(MNEMONIC);

    let previous = pool.next().address;
    for (let i = 0; i < RELAYER_COUNT * 3; i++) {
      const next = pool.next().address;
      expect(next).not.toBe(previous);
      previous = next;
    }
  });

  it("wraps back to the first account after a full cycle", () => {
    const pool = new RelayerPool(MNEMONIC);
    const first = pool.next().address;
    for (let i = 1; i < RELAYER_COUNT; i++) pool.next();
    expect(pool.next().address).toBe(first);
  });

  // The batching account is pinned by the pool's IMMUTABLE `sequencer`, which is set from the
  // deployer's raw PRIVATE_KEY. Nothing can change it afterwards, so if this pool could only
  // take a mnemonic the sequencer service could never sign as the address it must sign as.
  describe("raw private key", () => {
    // anvil account 0 -- the same key the mnemonic above derives at index 0.
    const KEY = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";
    const ADDRESS = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266";

    it("yields exactly one account, matching the key", () => {
      const pool = new RelayerPool(KEY, 1);
      expect(pool.size).toBe(1);
      expect(pool.addresses).toEqual([ADDRESS]);
    });

    it("keeps returning that one account", () => {
      const pool = new RelayerPool(KEY, 1);
      expect(pool.next().address).toBe(ADDRESS);
      expect(pool.next().address).toBe(ADDRESS);
    });

    it("refuses to pretend a single key can rotate", () => {
      // Silently collapsing to one account would look like rotation was configured and
      // working, while every batch went out from the same address.
      expect(() => new RelayerPool(KEY, 5)).toThrow(/exactly one account/);
    });

    it("still treats a mnemonic as a mnemonic", () => {
      expect(new RelayerPool(MNEMONIC, 1).addresses).toEqual([ADDRESS]);
    });
  });
});
