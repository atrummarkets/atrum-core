/**
 * Rotating relayer accounts.
 *
 * Every batch is a public transaction with a visible `from`. A single submitting
 * address turns the sequencer into a landmark: an observer cannot see which note a bet
 * spent, but can see that one account submits every batch, and can time-correlate
 * batches against deposits. Rotating across ~10 accounts costs nothing and removes that
 * single fixed point.
 *
 * This does NOT make the sequencer anonymous, and it is not meant to. It is defence
 * against trivial correlation, not against an observer who watches funding flows into
 * the relayer set. Real relayer privacy is a Phase 3 concern.
 */
import { mnemonicToAccount } from "viem/accounts";
import type { HDAccount } from "viem/accounts";

export const RELAYER_COUNT = 10;

export class RelayerPool {
  private readonly accounts: HDAccount[];
  private cursor = 0;

  constructor(mnemonic: string, count = RELAYER_COUNT) {
    if (count < 1) throw new Error("need at least one relayer");

    this.accounts = Array.from({ length: count }, (_, i) =>
      mnemonicToAccount(mnemonic, { addressIndex: i }),
    );
  }

  get size(): number {
    return this.accounts.length;
  }

  get addresses(): `0x${string}`[] {
    return this.accounts.map((a) => a.address);
  }

  /**
   * Round-robin rather than random.
   *
   * Random selection collides, and a collision means two batches in a row from the same
   * address -- exactly the pattern rotation exists to avoid. Round-robin guarantees the
   * maximum gap between reuses.
   */
  next(): HDAccount {
    const account = this.accounts[this.cursor % this.accounts.length]!;
    this.cursor += 1;
    return account;
  }
}
