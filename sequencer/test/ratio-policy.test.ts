/**
 * Attacks on the publish policy.
 *
 * Every case here is either an attempt to make the publisher leak more than it should, or
 * an attempt to make it publish a number that is simply wrong. The pass condition for the
 * leak cases is REFUSAL or COARSENING, not a successful publish.
 */
import { describe, it, expect } from "vitest";
import {
  decide,
  quantise,
  rawRatioBps,
  DEFAULT_POLICY,
  type MarketState,
  type RatioPolicy,
} from "../src/ratio-policy.ts";

const base = (over: Partial<MarketState> = {}): MarketState => ({
  yesUnits: 100n,
  noUnits: 100n,
  betCount: 10,
  betCountAtLastPublish: null,
  secondsSinceLastPublish: null,
  minPublishIntervalSeconds: 300,
  settled: false,
  bettingClosed: false,
  ...over,
});

describe("quantise", () => {
  it("rounds to the nearest bucket, not down", () => {
    // Flooring would bias every ratio downward, and a known bias is itself information.
    expect(quantise(5049, 100)).toBe(5000);
    expect(quantise(5051, 100)).toBe(5100);
    expect(quantise(4999, 100)).toBe(5000);
  });

  it("clamps into [0, 10000] rather than emitting a ratio the contract rejects", () => {
    // publishAttestedRatio reverts on > 10_000. Rounding 9990 up to a 100 bucket gives
    // 10000 exactly, but a larger bucket could overshoot.
    expect(quantise(9990, 100)).toBe(10_000);
    expect(quantise(9990, 1000)).toBe(10_000);
    expect(quantise(-5, 100)).toBe(0);
    expect(quantise(12_000, 100)).toBe(10_000);
  });

  it("passes values through when the bucket is degenerate", () => {
    expect(quantise(4237, 1)).toBe(4237);
    expect(quantise(4237, 0)).toBe(4237);
  });
});

describe("rawRatioBps", () => {
  it("is exact for the fixture pool", () => {
    expect(rawRatioBps(137n, 0n)).toBe(10_000);
    expect(rawRatioBps(0n, 137n)).toBe(0);
    expect(rawRatioBps(100n, 100n)).toBe(5000);
  });

  it("does not lose precision on a pool too large for a float", () => {
    // Number(yes)/Number(total) would lose the low bits here; integer-first math does not.
    const big = 10n ** 30n;
    expect(rawRatioBps(big, big)).toBe(5000);
    expect(rawRatioBps(big * 3n, big)).toBe(7500);
  });

  it("truncates toward zero rather than rounding, so quantise sees a consistent input", () => {
    expect(rawRatioBps(1n, 2n)).toBe(3333);
  });
});

describe("decide -- refusals that protect privacy", () => {
  it("refuses before the minimum opening bet count", () => {
    // Two bets and one exact ratio is solvable up to scale, and settlement supplies the
    // scale. The opening is the most dangerous moment, not the least.
    const d = decide(base({ betCount: 2 }));
    expect(d.publish).toBe(false);
    expect((d as any).reason).toMatch(/before first publish/);
  });

  it("refuses to publish once per bet, which is the actual attack", () => {
    // 3 bets required between publications. With one bet since the last one, refuse --
    // otherwise the observer gets one equation per unknown.
    const d = decide(base({ betCount: 11, betCountAtLastPublish: 10, secondsSinceLastPublish: 9999 }));
    expect(d.publish).toBe(false);
    expect((d as any).reason).toMatch(/since last publish/);
  });

  it("publishes once enough bets have aggregated", () => {
    const d = decide(base({ betCount: 13, betCountAtLastPublish: 10, secondsSinceLastPublish: 9999 }));
    expect(d.publish).toBe(true);
  });

  it("respects the contract's cadence floor so it does not burn a reverting transaction", () => {
    const d = decide(base({ betCount: 20, betCountAtLastPublish: 10, secondsSinceLastPublish: 60 }));
    expect(d.publish).toBe(false);
    expect((d as any).reason).toMatch(/cadence floor/);
  });

  it("refuses after settlement, when exact totals are already public", () => {
    const d = decide(base({ settled: true, betCount: 100 }));
    expect(d.publish).toBe(false);
    expect((d as any).reason).toMatch(/settled/);
  });

  it("refuses once betting has closed, when odds can no longer inform anyone", () => {
    const d = decide(base({ bettingClosed: true, betCount: 100 }));
    expect(d.publish).toBe(false);
    expect((d as any).reason).toMatch(/betting closed/);
  });

  it("refuses on an empty pool instead of publishing a fabricated 50%", () => {
    // Publishing 5000 for an empty pool would be a lie that looks like data.
    const d = decide(base({ yesUnits: 0n, noUnits: 0n, betCount: 100 }));
    expect(d.publish).toBe(false);
    expect((d as any).reason).toMatch(/empty pool/);
  });

  it("settled takes precedence over everything else", () => {
    const d = decide(base({ settled: true, bettingClosed: true, yesUnits: 0n, noUnits: 0n }));
    expect(d.publish).toBe(false);
    expect((d as any).reason).toMatch(/settled/);
  });
});

describe("decide -- the published value", () => {
  it("emits a coarsened ratio, never the exact one", () => {
    // 137 vs 100 is 5780 bps exactly. A 1% bucket must not reveal that precision.
    const d = decide(base({ yesUnits: 137n, noUnits: 100n }));
    expect(d.publish).toBe(true);
    expect((d as any).ratioBps).toBe(5800);
    expect((d as any).ratioBps).not.toBe(5780);
  });

  it("never carries a magnitude in its output", () => {
    // The decision object is what a caller might log. It must contain no unit counts.
    const d = decide(base({ yesUnits: 987_654n, noUnits: 12_346n }));
    expect(JSON.stringify(d)).not.toMatch(/987654|12346/);
  });

  it("gives the same ratio for pools of wildly different size -- the value is scale-free", () => {
    const small = decide(base({ yesUnits: 3n, noUnits: 1n }));
    const large = decide(base({ yesUnits: 3_000_000n, noUnits: 1_000_000n }));
    expect((small as any).ratioBps).toBe((large as any).ratioBps);
  });

  it("stays inside the contract's accepted range for one-sided pools", () => {
    // publishAttestedRatio reverts above 10_000, so a 100%-YES pool is the boundary case.
    for (const s of [
      { yesUnits: 137n, noUnits: 0n },
      { yesUnits: 0n, noUnits: 137n },
      { yesUnits: 1n, noUnits: 10n ** 18n },
    ]) {
      const d = decide(base(s));
      expect(d.publish).toBe(true);
      expect((d as any).ratioBps).toBeGreaterThanOrEqual(0);
      expect((d as any).ratioBps).toBeLessThanOrEqual(10_000);
    }
  });
});

describe("decide -- the leak bound actually binds", () => {
  it("caps publications well below the bet count over a long market", () => {
    // THE load-bearing property. The attack needs roughly one equation per unknown stake;
    // this asserts the observer cannot get them. Simulate 100 bets, ticking after each.
    const policy: RatioPolicy = DEFAULT_POLICY;
    let published = 0;
    let atLast: number | null = null;

    for (let bets = 1; bets <= 100; bets++) {
      const d = decide(
        base({
          betCount: bets,
          betCountAtLastPublish: atLast,
          secondsSinceLastPublish: atLast === null ? null : 10_000,
        }),
        policy,
      );
      if (d.publish) {
        published++;
        atLast = bets;
      }
    }

    // 100 bets, 5 before the first publish, 3 between each after: ~32 publications.
    expect(published).toBeLessThanOrEqual(Math.ceil(100 / policy.minBetsBetweenPublishes));
    expect(published * policy.minBetsBetweenPublishes).toBeLessThanOrEqual(100 + policy.minBetsBetweenPublishes);
    // And each is a 1% interval, not an equality.
    expect(policy.quantiseBps).toBeGreaterThanOrEqual(100);
  });

  it("a stricter policy publishes strictly less", () => {
    const strict: RatioPolicy = { quantiseBps: 500, minBetsBeforeFirstPublish: 20, minBetsBetweenPublishes: 10 };
    const count = (p: RatioPolicy) => {
      let n = 0;
      let atLast: number | null = null;
      for (let bets = 1; bets <= 100; bets++) {
        const d = decide(
          base({ betCount: bets, betCountAtLastPublish: atLast, secondsSinceLastPublish: atLast === null ? null : 10_000 }),
          p,
        );
        if (d.publish) { n++; atLast = bets; }
      }
      return n;
    };
    expect(count(strict)).toBeLessThan(count(DEFAULT_POLICY));
  });
});
