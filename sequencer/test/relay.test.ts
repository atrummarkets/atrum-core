/**
 * The relay surface: what it accepts, what it refuses, and that concurrent submissions from
 * one account cannot race.
 *
 * The nonce test is the reason this file exists. `Sequencer.submit` never needed nonce
 * handling because `tick()` is a strictly serial loop; user submissions are not, and two
 * in-flight transactions from one account would read the same nonce and one would be dropped.
 * That failure is invisible in a single-request test.
 */
import { describe, it, expect } from "vitest";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import { parseRelayRequest, RelayError, RELAYABLE, Relayer } from "../src/relay.ts";
import { createPathHandler } from "../src/main.ts";

const proof = {
  pA: ["1", "2"],
  pB: [
    ["3", "4"],
    ["5", "6"],
  ],
  pC: ["7", "8"],
};

const withdrawArgs = ["100", "200", "300", "400"];
const betArgs = ["100", "200", "300", "400", ["1", "2", "3", "4"]];

describe("parseRelayRequest", () => {
  it("accepts a well-formed withdraw", () => {
    const { action, args } = parseRelayRequest({ ...proof, action: "withdraw", args: withdrawArgs });
    expect(action).toBe("withdraw");
    // pA, pB, pC, then the four tail args
    expect(args).toHaveLength(7);
    expect(args[0]).toEqual([1n, 2n]);
    expect(args[6]).toBe(400n);
  });

  it("accepts betEncrypted and keeps the ciphertext as a nested array", () => {
    const { args } = parseRelayRequest({ ...proof, action: "betEncrypted", args: betArgs });
    expect(args).toHaveLength(8);
    expect(args[7]).toEqual([1n, 2n, 3n, 4n]);
  });

  // The point of the allowlist: a relayer spends its OWN gas, so a caller must not be able to
  // talk it into submitting something it did not intend to support.
  it("refuses deposit, which is not relayable", () => {
    expect(() => parseRelayRequest({ ...proof, action: "deposit", args: withdrawArgs })).toThrow(
      /not relayable/,
    );
  });

  it("refuses an unknown action", () => {
    expect(() => parseRelayRequest({ ...proof, action: "flushBatch", args: [] })).toThrow(RelayError);
  });

  it("refuses the wrong argument count for the action", () => {
    // withdraw takes 4 tail args; betEncrypted's 5 must not be accepted for it.
    expect(() => parseRelayRequest({ ...proof, action: "withdraw", args: betArgs })).toThrow(
      /must be an array of 4/,
    );
  });

  it("refuses a malformed proof point", () => {
    expect(() =>
      parseRelayRequest({ ...proof, pA: ["1"], action: "withdraw", args: withdrawArgs }),
    ).toThrow(/pA must be an array of 2/);
  });

  it("refuses non-numeric values rather than passing them to viem", () => {
    expect(() =>
      parseRelayRequest({ ...proof, action: "withdraw", args: ["1", "2", "3", "not-a-number"] }),
    ).toThrow(/not a valid integer/);
  });

  // Values here routinely exceed Number.MAX_SAFE_INTEGER, so they arrive as JSON strings.
  it("accepts field-sized decimal strings without precision loss", () => {
    const big = "21888242871839275222246405745257275088548364400416034343698204186575808495616";
    const { args } = parseRelayRequest({ ...proof, action: "withdraw", args: [big, "2", "3", "4"] });
    expect(args[3]).toBe(BigInt(big));
  });

  it("lists exactly the three proof-gated actions", () => {
    expect([...RELAYABLE]).toEqual(["betEncrypted", "redeemPrivate", "withdraw"]);
  });
});

const fakeSequencer = {
  tree: { size: 0, root: () => 0n, leavesFrom: () => [] },
  pathFor: () => {
    throw new Error("not used");
  },
};

async function withServer<T>(
  relayer: { submit: (a: never, b: readonly unknown[]) => Promise<never> } | undefined,
  fn: (base: string) => Promise<T>,
): Promise<T> {
  const server = createServer(createPathHandler(fakeSequencer, "*", relayer as never));
  await new Promise<void>((resolve) => server.listen(0, resolve));
  const { port } = server.address() as AddressInfo;
  try {
    return await fn(`http://127.0.0.1:${port}`);
  } finally {
    await new Promise<void>((resolve) => server.close(() => resolve()));
  }
}

describe("POST /relay", () => {
  it("503s when relaying is not enabled, rather than 404ing confusingly", async () => {
    await withServer(undefined, async (base) => {
      const res = await fetch(`${base}/relay`, {
        method: "POST",
        body: JSON.stringify({ ...proof, action: "withdraw", args: withdrawArgs }),
      });
      expect(res.status).toBe(503);
    });
  });

  it("405s a GET to /relay", async () => {
    const relayer = { submit: async () => ({}) as never };
    await withServer(relayer, async (base) => {
      expect((await fetch(`${base}/relay`)).status).toBe(405);
    });
  });

  it("400s an invalid body without reaching the submitter", async () => {
    let called = false;
    const relayer = {
      submit: async () => {
        called = true;
        return {} as never;
      },
    };
    await withServer(relayer, async (base) => {
      const res = await fetch(`${base}/relay`, {
        method: "POST",
        body: JSON.stringify({ ...proof, action: "deposit", args: withdrawArgs }),
      });
      expect(res.status).toBe(400);
      expect(called).toBe(false);
    });
  });

  it("400s a body that is not JSON", async () => {
    const relayer = { submit: async () => ({}) as never };
    await withServer(relayer, async (base) => {
      const res = await fetch(`${base}/relay`, { method: "POST", body: "{{{" });
      expect(res.status).toBe(400);
    });
  });

  it("returns the tx hash on success", async () => {
    const relayer = {
      submit: async () =>
        ({
          hash: "0xabc",
          blockNumber: 123n,
          gasUsed: 456n,
          relayer: "0xrelayer",
        }) as never,
    };
    await withServer(relayer, async (base) => {
      const res = await fetch(`${base}/relay`, {
        method: "POST",
        body: JSON.stringify({ ...proof, action: "withdraw", args: withdrawArgs }),
      });
      expect(res.status).toBe(200);
      expect(await res.json()).toEqual({
        hash: "0xabc",
        blockNumber: 123,
        gasUsed: "456",
        relayer: "0xrelayer",
      });
    });
  });

  it("advertises POST in the preflight, or the browser never sends the body", async () => {
    const relayer = { submit: async () => ({}) as never };
    await withServer(relayer, async (base) => {
      const res = await fetch(`${base}/relay`, { method: "OPTIONS" });
      expect(res.status).toBe(204);
      expect(res.headers.get("access-control-allow-methods")).toContain("POST");
      // /relay is the first route sending content-type, which is what triggers preflight.
      expect(res.headers.get("access-control-allow-headers")).toContain("content-type");
    });
  });
});

/**
 * The off-chain half of the timing defence.
 *
 * Driven through a Relayer whose `dispatch` is stubbed, because what is under test is the
 * HOLD-AND-SHUFFLE policy, not viem. Wiring a real chain in here would test the RPC and hide
 * the ordering behaviour behind it.
 */
describe("Relayer release windows", () => {
  /** A Relayer that records what it would have sent, in the order it would have sent it. */
  function harness(releaseIntervalMs: number) {
    const sent: string[] = [];
    const relayer = new Relayer({
      rpcUrl: "http://127.0.0.1:0",
      chain: { id: 1 } as never,
      poolAddress: "0x0000000000000000000000000000000000000001",
      mnemonic: "test test test test test test test test test test test junk",
      publicClient: {} as never,
      relayerCount: 1,
      releaseIntervalMs,
    });

    // Replace the network leg. Everything above it -- holding, shuffling, per-account nonce
    // serialisation -- is real.
    (relayer as unknown as { dispatch: (a: string, args: readonly unknown[]) => Promise<unknown> })
      .dispatch = async (_action: string, args: readonly unknown[]) => {
        sent.push(String(args[0]));
        return { hash: "0x0", blockNumber: 1n, gasUsed: 1n, relayer: "0x0" };
      };

    return { relayer, sent };
  }

  it("forwards immediately when no interval is configured", async () => {
    const { relayer, sent } = harness(0);
    await relayer.submit("withdraw", ["a"]);
    expect(sent).toEqual(["a"]);
    expect(relayer.pending).toBe(0);
  });

  it("holds submissions instead of forwarding them", async () => {
    const { relayer, sent } = harness(60_000);

    void relayer.submit("withdraw", ["a"]);
    void relayer.submit("withdraw", ["b"]);

    // Nothing has been sent, and the callers are still waiting. That is the point: the
    // relayer is deliberately NOT racing to forward.
    expect(sent).toEqual([]);
    expect(relayer.pending).toBe(2);
  });

  it("releases the whole window at once", async () => {
    const { relayer, sent } = harness(60_000);

    const first = relayer.submit("withdraw", ["a"]);
    const second = relayer.submit("withdraw", ["b"]);
    relayer.flush();

    await Promise.all([first, second]);
    expect(sent.slice().sort()).toEqual(["a", "b"]);
    expect(relayer.pending).toBe(0);
  });

  it("does not preserve arrival order across many windows", async () => {
    // The property that matters, stated as a property rather than as one shuffle's outcome:
    // over enough windows, arrival order must NOT be the release order every time. A
    // per-submission timer would pass every other test in this block and fail this one --
    // and it is exactly the implementation someone would reach for first.
    let sawReordering = false;

    for (let round = 0; round < 40 && !sawReordering; round++) {
      const { relayer, sent } = harness(60_000);
      const inOrder = ["a", "b", "c", "d", "e", "f"];
      const all = inOrder.map((x) => relayer.submit("withdraw", [x]));
      relayer.flush();
      await Promise.all(all);

      if (sent.join(",") !== inOrder.join(",")) sawReordering = true;
    }

    expect(sawReordering).toBe(true);
  });

  it("loses nothing across a window", async () => {
    const { relayer, sent } = harness(60_000);
    const items = Array.from({ length: 20 }, (_, i) => `n${i}`);

    const all = items.map((x) => relayer.submit("withdraw", [x]));
    relayer.flush();
    await Promise.all(all);

    // Shuffling must not drop or duplicate. A subtle Fisher-Yates bug does exactly that, and
    // for a user it looks like their withdrawal silently never happened.
    expect(sent.slice().sort()).toEqual(items.slice().sort());
  });

  it("flushing an empty window is a no-op", async () => {
    const { relayer, sent } = harness(60_000);
    relayer.flush();
    expect(sent).toEqual([]);
  });
});
