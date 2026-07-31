/**
 * WHEN the publisher is allowed to publish, and at what precision.
 *
 * Pure decision logic, separated from the worker so it can be attacked in tests without
 * a chain. This file is the privacy-critical part of the publisher; `publisher.ts` is
 * plumbing.
 *
 * ============================================================================
 * THE LEAK THIS EXISTS TO BOUND
 * ============================================================================
 *
 * A single published ratio leaks nothing about magnitudes. `yes / (yes + no)` is
 * scale-free: 50% is 50% whether the pool holds 2 units or 2,000,000.
 *
 * A SEQUENCE of ratios is a different object, because of three things an observer already
 * has for free:
 *
 *   1. Every encrypted bet is a visible transaction, so the observer knows exactly how many
 *      bets happened and when.
 *   2. `betMeta` is a PUBLIC circuit signal carrying `marketId * 4 + outcome`, and
 *      `ElGamalAccumulator` emits `StakeAccumulated(marketId, outcome)`. So the SIDE of
 *      every bet is public. Only the amount is hidden.
 *   3. `publishFinalTotals` reveals the exact totals at settlement -- deliberately, because
 *      a pro-rata payout needs real numbers.
 *
 * Put those together. Let bet i have unknown size a_i on a known side. Each published ratio
 * gives one equation in the running sums; settlement pins the absolute scale that a
 * ratio alone would not. Publish once per bet at fine precision and the observer ends up
 * with roughly as many equations as unknowns, and individual stakes fall out.
 *
 * That would retroactively undo exactly what `redeemPrivate` and the encrypted accumulator
 * are for.
 *
 * ============================================================================
 * THE BOUND
 * ============================================================================
 *
 * Two knobs, and they attack the two halves of "as many equations as unknowns":
 *
 *   - `minBetsBetweenPublishes` caps the NUMBER of equations. With k bets required between
 *     publications, an observer gets at most N/k equations for N unknowns, so the system
 *     stays underdetermined by construction rather than by luck.
 *   - `quantiseBps` degrades each equation from an equality into an interval. A 100 bps
 *     bucket says "somewhere in this 1% band", which is a constraint, not a solution.
 *
 * `minBetsBeforeFirstPublish` handles the opening, where the system is smallest and so
 * easiest to solve: two bets and one exact ratio is genuinely solvable up to scale.
 *
 * NONE OF THIS IS A PROOF OF PRIVACY. It bounds a known attack; it does not establish that
 * no better attack exists. The honest claim is "mid-market odds are coarse and infrequent
 * by policy", not "individual stakes are provably unrecoverable".
 */

export interface RatioPolicy {
  /** Bucket size in basis points. 100 = round to whole percent. */
  quantiseBps: number;
  /** Bets that must exist before the very first publication for a market. */
  minBetsBeforeFirstPublish: number;
  /** Bets that must land between one publication and the next. */
  minBetsBetweenPublishes: number;
}

/**
 * Deliberately coarse. 1% buckets, and at most one publication per 3 bets, with 5 bets
 * before the market shows odds at all.
 *
 * These are a judgement call, not a measured optimum: there is no threshold at which the
 * attack described above stops working, only one at which it gets expensive. They are set
 * to favour privacy over UX because the odds are decoration -- no payout reads them.
 */
export const DEFAULT_POLICY: RatioPolicy = {
  quantiseBps: 100,
  minBetsBeforeFirstPublish: 5,
  minBetsBetweenPublishes: 3,
};

export interface MarketState {
  /** Decrypted YES total. Never leaves the publisher process. */
  yesUnits: bigint;
  /** Decrypted NO total. Never leaves the publisher process. */
  noUnits: bigint;
  /** Encrypted bets seen for this market, all time. */
  betCount: number;
  /** `betCount` as of the last successful publication, or null if never published. */
  betCountAtLastPublish: number | null;
  /** Seconds since the last publication, or null if never published. */
  secondsSinceLastPublish: number | null;
  /** The contract's own cadence floor; publishing sooner reverts `PublishedTooSoon`. */
  minPublishIntervalSeconds: number;
  settled: boolean;
  bettingClosed: boolean;
}

export type Decision =
  | { publish: true; ratioBps: number }
  | { publish: false; reason: string };

/**
 * Round to the nearest bucket and clamp to [0, 10000].
 *
 * Nearest rather than floor: flooring biases every published ratio downward, and a
 * consistent bias is itself information once an observer knows the rule.
 */
export function quantise(ratioBps: number, bucket: number): number {
  if (bucket <= 1) return Math.max(0, Math.min(10_000, Math.round(ratioBps)));
  const snapped = Math.round(ratioBps / bucket) * bucket;
  return Math.max(0, Math.min(10_000, snapped));
}

/** Exact YES share in basis points. Caller must have checked the pool is non-empty. */
export function rawRatioBps(yesUnits: bigint, noUnits: bigint): number {
  const total = yesUnits + noUnits;
  // Integer math to full precision first; only the final divide goes to float, so a large
  // pool cannot lose precision the way (Number(yes) / Number(total)) would.
  return Number((yesUnits * 10_000n) / total);
}

export function decide(state: MarketState, policy: RatioPolicy = DEFAULT_POLICY): Decision {
  // Settlement publishes the exact totals. A ratio afterwards is noise at best, and at
  // worst an extra equation layered on top of the now-known scale.
  if (state.settled) return { publish: false, reason: "market already settled" };

  // Once betting closes the ratio can no longer inform anyone's decision, so publishing it
  // buys nothing and only adds an observation.
  if (state.bettingClosed) return { publish: false, reason: "betting closed" };

  const total = state.yesUnits + state.noUnits;
  if (total === 0n) return { publish: false, reason: "empty pool -- no ratio is defined" };

  const first = state.betCountAtLastPublish === null;

  if (first) {
    if (state.betCount < policy.minBetsBeforeFirstPublish) {
      return {
        publish: false,
        reason: `only ${state.betCount} bets; need ${policy.minBetsBeforeFirstPublish} before first publish`,
      };
    }
  } else {
    const since = state.betCount - state.betCountAtLastPublish!;
    if (since < policy.minBetsBetweenPublishes) {
      return {
        publish: false,
        reason: `only ${since} bets since last publish; need ${policy.minBetsBetweenPublishes}`,
      };
    }
    // The contract enforces this too; checking here turns a reverted transaction and a
    // wasted fee into a no-op.
    if (
      state.secondsSinceLastPublish !== null &&
      state.secondsSinceLastPublish < state.minPublishIntervalSeconds
    ) {
      return {
        publish: false,
        reason: `cadence floor: ${state.secondsSinceLastPublish}s < ${state.minPublishIntervalSeconds}s`,
      };
    }
  }

  return { publish: true, ratioBps: quantise(rawRatioBps(state.yesUnits, state.noUnits), policy.quantiseBps) };
}
