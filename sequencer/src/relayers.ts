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
import { mnemonicToAccount, privateKeyToAccount } from "viem/accounts";
import type { HDAccount, PrivateKeyAccount } from "viem/accounts";

export const RELAYER_COUNT = 10;

type Signer = HDAccount | PrivateKeyAccount;

/**
 * Whether a secret is a raw private key rather than a mnemonic.
 *
 * A raw key can only ever produce ONE account, so rotation is not available to it. That is
 * fine for the batching account, which is pinned to a single address by the pool's immutable
 * `sequencer` and could never rotate anyway -- but it makes a raw key the wrong choice for the
 * user-facing relayer, where rotation is the point.
 */
export function isPrivateKey(secret: string): boolean {
  return /^0x[0-9a-fA-F]{64}$/.test(secret.trim());
}

export class RelayerPool {
  private readonly accounts: Signer[];
  private cursor = 0;

  /**
   * @param secret a BIP-39 mnemonic, or a raw `0x`-prefixed private key.
   *
   * The raw-key form exists because the pool's `sequencer` is IMMUTABLE and set at deploy
   * time, and deployments are driven by a raw `PRIVATE_KEY`. Requiring a mnemonic here meant
   * the batching account could only ever be an address the deployer did not control unless
   * the deploy was told about the mnemonic first -- an ordering dependency that is easy to get
   * wrong and impossible to fix afterwards, since nothing can change `sequencer` later.
   */
  constructor(secret: string, count = RELAYER_COUNT) {
    if (count < 1) throw new Error("need at least one relayer");

    if (isPrivateKey(secret)) {
      if (count > 1) {
        throw new Error(
          "a raw private key yields exactly one account -- pass count = 1, or use a mnemonic " +
            "if you actually want rotation",
        );
      }
      this.accounts = [privateKeyToAccount(secret.trim() as `0x${string}`)];
      return;
    }

    this.accounts = Array.from({ length: count }, (_, i) =>
      mnemonicToAccount(secret, { addressIndex: i }),
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
  next(): Signer {
    const account = this.accounts[this.cursor % this.accounts.length]!;
    this.cursor += 1;
    return account;
  }
}
