/**
 * Restart correctness for the tree mirror.
 *
 * The bug these cover was live: `resync` rebuilt the mirror by slicing the queue into 64s.
 * `insertedCount` counts only REAL commitments, but every graft inserts exactly 64 leaves,
 * padding the remainder with fillers derived on-chain. So after any partial batch:
 *
 *   - the final slice is short, `insertBatch` throws, and the sequencer cannot boot at all;
 *   - and the fillers, which depend on each batch's own `treeStart`, are missing from the
 *     rebuilt tree entirely.
 *
 * Partial batches are not exotic. `maxBatchDelayMs` exists to submit them, so any quiet
 * market produces one. The failure mode is a sequencer that works until its first restart
 * after a quiet period, then never comes back -- and while it is down, nobody can obtain a
 * Merkle path, so nobody can build a bet proof.
 */
import { describe, it, expect, beforeAll } from "vitest";
import {
  CommitmentTree,
  rebuildBatches,
  derivedFiller,
  initHasher,
  BATCH_SIZE,
  type GraftedBatch,
} from "../src/tree.ts";

const leaf = (n: number) => BigInt(1000 + n);

describe("rebuildBatches", () => {
  beforeAll(async () => {
    await initHasher();
  }, 60_000);

  it("returns full 64-leaf batches even when the graft was partial", () => {
    // The exact shape that used to throw: 10 real commitments in one padded batch.
    const batches: GraftedBatch[] = [{ startIndex: 0n, count: 10 }];
    const queued = Array.from({ length: 10 }, (_, i) => leaf(i));

    const out = rebuildBatches(batches, queued);
    expect(out).toHaveLength(1);
    expect(out[0]).toHaveLength(BATCH_SIZE);
  });

  it("pads with the CONTRACT's derived fillers, keyed on that batch's treeStart", () => {
    const batches: GraftedBatch[] = [{ startIndex: 0n, count: 2 }];
    const out = rebuildBatches(batches, [leaf(0), leaf(1)])[0]!;

    expect(out[0]).toBe(leaf(0));
    expect(out[1]).toBe(leaf(1));
    for (let slot = 2; slot < BATCH_SIZE; slot++) {
      expect(out[slot]).toBe(derivedFiller(0n, BigInt(slot)));
    }
  });

  it("uses each batch's OWN treeStart, so two partial batches get different fillers", () => {
    // The whole point of keying fillers on treeStart: identical padding across batches
    // would put the same leaf at two tree positions.
    const batches: GraftedBatch[] = [
      { startIndex: 0n, count: 1 },
      { startIndex: 64n, count: 1 },
    ];
    const [first, second] = rebuildBatches(batches, [leaf(0), leaf(1)]);

    expect(first![5]).toBe(derivedFiller(0n, 5n));
    expect(second![5]).toBe(derivedFiller(64n, 5n));
    expect(first![5]).not.toBe(second![5]);
  });

  it("handles a full batch with no padding at all", () => {
    const queued = Array.from({ length: BATCH_SIZE }, (_, i) => leaf(i));
    const out = rebuildBatches([{ startIndex: 0n, count: BATCH_SIZE }], queued)[0]!;
    expect(out).toEqual(queued);
  });

  it("handles full batches followed by a partial one -- the realistic history", () => {
    const queued = Array.from({ length: BATCH_SIZE + 5 }, (_, i) => leaf(i));
    const out = rebuildBatches(
      [
        { startIndex: 0n, count: BATCH_SIZE },
        { startIndex: BigInt(BATCH_SIZE), count: 5 },
      ],
      queued,
    );

    expect(out).toHaveLength(2);
    expect(out[0]).toEqual(queued.slice(0, BATCH_SIZE));
    expect(out[1]!.slice(0, 5)).toEqual(queued.slice(BATCH_SIZE, BATCH_SIZE + 5));
    expect(out[1]![5]).toBe(derivedFiller(BigInt(BATCH_SIZE), 5n));
  });

  it("consumes the queue in order across batches, never re-reading", () => {
    const queued = Array.from({ length: 30 }, (_, i) => leaf(i));
    const out = rebuildBatches(
      [
        { startIndex: 0n, count: 10 },
        { startIndex: 64n, count: 20 },
      ],
      queued,
    );
    expect(out[0]!.slice(0, 10)).toEqual(queued.slice(0, 10));
    expect(out[1]!.slice(0, 20)).toEqual(queued.slice(10, 30));
  });

  it("refuses when the queue is behind the batch log rather than grafting wrong leaves", () => {
    // A mirror that guesses here serves paths for a tree that never existed, and every
    // proof built from them fails on-chain with no diagnostic.
    expect(() => rebuildBatches([{ startIndex: 0n, count: 10 }], [leaf(0)])).toThrow(
      /only 1 are available/,
    );
  });

  it("rejects a count outside [0, 64] instead of trusting the log", () => {
    expect(() => rebuildBatches([{ startIndex: 0n, count: 65 }], [])).toThrow(/outside/);
    expect(() => rebuildBatches([{ startIndex: 0n, count: -1 }], [])).toThrow(/outside/);
  });

  it("returns nothing for a chain with no batches yet", () => {
    expect(rebuildBatches([], [])).toEqual([]);
  });
});

describe("mirror restart", () => {
  beforeAll(async () => {
    await initHasher();
  }, 60_000);

  it("a rebuilt mirror has the SAME ROOT as one built live -- padded batches included", () => {
    // THE property. Everything else here is a means to this.
    const queued = Array.from({ length: BATCH_SIZE + 7 }, (_, i) => leaf(i));
    const batches: GraftedBatch[] = [
      { startIndex: 0n, count: BATCH_SIZE },
      { startIndex: BigInt(BATCH_SIZE), count: 7 },
    ];

    const live = new CommitmentTree();
    for (const b of rebuildBatches(batches, queued)) live.insertBatch(b);
    const liveRoot = live.root();

    const restarted = new CommitmentTree();
    for (const b of rebuildBatches(batches, queued)) restarted.insertBatch(b);

    expect(restarted.root()).toBe(liveRoot);
    expect(restarted.size).toBe(2 * BATCH_SIZE);
  });

  it("reset() clears the mirror, so a second resync replaces rather than appends", () => {
    // Without reset, a re-resync doubles the tree: batch-aligned, no error thrown, and
    // every served path silently wrong.
    const queued = Array.from({ length: 10 }, (_, i) => leaf(i));
    const batches: GraftedBatch[] = [{ startIndex: 0n, count: 10 }];

    const tree = new CommitmentTree();
    for (const b of rebuildBatches(batches, queued)) tree.insertBatch(b);
    const once = tree.root();
    expect(tree.size).toBe(BATCH_SIZE);

    tree.reset();
    expect(tree.size).toBe(0);
    for (const b of rebuildBatches(batches, queued)) tree.insertBatch(b);

    expect(tree.root()).toBe(once);
    expect(tree.size).toBe(BATCH_SIZE);
  });

  it("REGRESSION: the old slice-the-queue rebuild throws on a partial batch", () => {
    // Pinning the original bug so it cannot come back. 10 real commitments sliced into
    // 64s gives one 10-leaf array, and insertBatch requires exactly 64.
    const queued = Array.from({ length: 10 }, (_, i) => leaf(i));
    const tree = new CommitmentTree();
    expect(() => tree.insertBatch(queued.slice(0, BATCH_SIZE))).toThrow(/must be exactly 64/);
  });
});
