/**
 * The HTTP surface, tested without an RPC connection or a chain.
 *
 * The CORS headers here are not cosmetic. The browser client is served from a different
 * origin, so a missing header makes every Merkle-path fetch fail in the browser while
 * continuing to work perfectly from curl -- the failure mode is invisible to exactly the
 * tools you would reach for first.
 */
import { describe, it, expect } from "vitest";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import { createPathHandler } from "../src/main.ts";

/** Minimal stand-in for the Sequencer, holding one known commitment at index 3. */
const LEAVES = [10n, 11n, 12n, 99n, 14n, 15n, 16n];
const fake = {
  tree: {
    size: 7,
    root: () => 12345n,
    leavesFrom: (start = 0) => LEAVES.slice(start),
  },
  pathFor(commitment: bigint) {
    if (commitment !== 99n) throw new Error("commitment not found in the mirror");
    return {
      index: 3,
      root: 12345n,
      path: { pathElements: [1n, 2n], pathIndices: [0n, 1n] },
    };
  },
};

async function withServer<T>(
  fn: (base: string) => Promise<T>,
  origin?: string,
  relayer?: Parameters<typeof createPathHandler>[2],
  balanceOf?: Parameters<typeof createPathHandler>[3],
): Promise<T> {
  const server = createServer(createPathHandler(fake, origin, relayer, balanceOf));
  await new Promise<void>((resolve) => server.listen(0, resolve));
  const { port } = server.address() as AddressInfo;
  try {
    return await fn(`http://127.0.0.1:${port}`);
  } finally {
    await new Promise<void>((resolve) => server.close(() => resolve()));
  }
}

describe("path endpoint", () => {
  it("serves a Merkle path for a known commitment", async () => {
    await withServer(async (base) => {
      const res = await fetch(`${base}/path?commitment=99`);
      expect(res.status).toBe(200);
      expect(await res.json()).toEqual({
        index: 3,
        root: "12345",
        pathElements: ["1", "2"],
        pathIndices: ["0", "1"],
      });
    });
  });

  it("reports health without touching anything private", async () => {
    await withServer(async (base) => {
      const res = await fetch(`${base}/health`);
      expect(res.status).toBe(200);
      expect(await res.json()).toEqual({ status: "ok", leaves: 7, root: "12345" });
    });
  });

  it("400s a commitment the mirror has not grafted yet", async () => {
    await withServer(async (base) => {
      const res = await fetch(`${base}/path?commitment=1`);
      expect(res.status).toBe(400);
      const body = (await res.json()) as { error: string };
      expect(body.error).toContain("not found");
    });
  });

  it("400s an unparseable commitment", async () => {
    await withServer(async (base) => {
      expect((await fetch(`${base}/path?commitment=notanumber`)).status).toBe(400);
    });
  });

  it("404s any other route", async () => {
    await withServer(async (base) => {
      expect((await fetch(`${base}/admin`)).status).toBe(404);
    });
  });
});

describe("CORS", () => {
  // Every branch, not just the happy one: a client that cannot read the ERROR body is just
  // as broken as one that cannot read the path, and it debugs far worse.
  it.each([
    ["/health", 200],
    ["/path?commitment=99", 200],
    ["/path?commitment=1", 400],
    ["/nope", 404],
  ])("sets the origin header on %s (%i)", async (path, status) => {
    await withServer(async (base) => {
      const res = await fetch(`${base}${path}`, { headers: { Origin: "http://localhost:8080" } });
      expect(res.status).toBe(status);
      expect(res.headers.get("access-control-allow-origin")).toBe("*");
    });
  });

  it("honours CORS_ORIGIN when the deployment locks it down", async () => {
    await withServer(async (base) => {
      const res = await fetch(`${base}/health`);
      expect(res.headers.get("access-control-allow-origin")).toBe("https://app.atrum.markets");
    }, "https://app.atrum.markets");
  });

  it("answers the OPTIONS preflight instead of 404ing it", async () => {
    // Only triggered once a client sends a non-simple header, but a 404 here is a silent,
    // baffling failure -- the actual GET never even leaves the browser.
    await withServer(async (base) => {
      const res = await fetch(`${base}/path?commitment=99`, { method: "OPTIONS" });
      expect(res.status).toBe(204);
      expect(res.headers.get("access-control-allow-origin")).toBe("*");
      expect(res.headers.get("access-control-allow-methods")).toContain("GET");
    });
  });
});

/**
 * `/leaves` exists so a client never has to name the commitment it is spending. These check
 * the mechanics; the privacy property itself is asserted in atrum-markets' client suite,
 * which verifies no path lookup leaves the browser at all.
 */
/** What `/leaves` returns. `Response.json()` is `unknown` here, so the shape is declared. */
interface LeavesBody {
  since: number;
  total: number;
  root: string;
  leaves: string[];
}

describe("GET /leaves", () => {
  it("serves the whole leaf set with the current root", async () => {
    await withServer(async (base) => {
      const res = await fetch(`${base}/leaves`);
      expect(res.status).toBe(200);
      const body = (await res.json()) as LeavesBody;
      expect(body.total).toBe(7);
      expect(body.since).toBe(0);
      expect(body.root).toBe("12345");
      expect(body.leaves).toEqual(["10", "11", "12", "99", "14", "15", "16"]);
    });
  });

  it("returns only the tail when the client has already synced", async () => {
    await withServer(async (base) => {
      const body = (await (await fetch(`${base}/leaves?since=5`)).json()) as LeavesBody;
      expect(body.since).toBe(5);
      expect(body.total).toBe(7);
      expect(body.leaves).toEqual(["15", "16"]);
    });
  });

  it("returns an empty tail rather than an error once fully synced", async () => {
    await withServer(async (base) => {
      const body = (await (await fetch(`${base}/leaves?since=7`)).json()) as LeavesBody;
      expect(body.leaves).toEqual([]);
      expect(body.total).toBe(7);
    });
  });

  it("rejects a nonsense since rather than serving the whole tree", async () => {
    await withServer(async (base) => {
      expect((await fetch(`${base}/leaves?since=-1`)).status).toBe(400);
      expect((await fetch(`${base}/leaves?since=abc`)).status).toBe(400);
    });
  });

  it("serves leaves as decimal strings, not JSON numbers", async () => {
    // Field elements exceed Number.MAX_SAFE_INTEGER; a numeric encoding would silently
    // round them and every path built from the result would be wrong.
    await withServer(async (base) => {
      const raw = await (await fetch(`${base}/leaves`)).text();
      expect(raw).toContain('"10"');
      expect(raw).not.toMatch(/"leaves":\[\d/);
    });
  });
});

/**
 * `/relayers` is monitoring, not protocol -- it exists because relay accounts drain silently
 * and take every bet and redemption down with them, with nothing on chain saying why.
 */
describe("GET /relayers", () => {
  const RELAYERS = [
    "0x1111111111111111111111111111111111111111",
    "0x2222222222222222222222222222222222222222",
  ] as const;

  const sink = {
    submit: async () => {
      throw new Error("not used");
    },
    addresses: RELAYERS,
  } as unknown as Parameters<typeof createPathHandler>[2];

  interface RelayersBody {
    relaying: boolean;
    accounts: { address: string; balanceWei: string }[];
    error?: string;
  }

  it("reports each relayer and its balance", async () => {
    const balances: Record<string, bigint> = {
      [RELAYERS[0]]: 3_000_000_000_000_000_000n,
      [RELAYERS[1]]: 140_000_000_000_000_000n,
    };
    await withServer(
      async (base) => {
        const body = (await (await fetch(`${base}/relayers`)).json()) as RelayersBody;
        expect(body.relaying).toBe(true);
        expect(body.accounts).toEqual([
          { address: RELAYERS[0], balanceWei: "3000000000000000000" },
          { address: RELAYERS[1], balanceWei: "140000000000000000" },
        ]);
      },
      undefined,
      sink,
      async (a) => balances[a]!,
    );
  });

  it("says relaying is off rather than pretending there are no accounts", async () => {
    await withServer(async (base) => {
      const res = await fetch(`${base}/relayers`);
      expect(res.status).toBe(200);
      const body = (await res.json()) as RelayersBody;
      expect(body.relaying).toBe(false);
      expect(body.accounts).toEqual([]);
    });
  });

  it("fails loudly when the RPC is down, rather than reporting zero accounts", async () => {
    // A monitor that reads an RPC outage as "no relayers to worry about" is worse than none.
    await withServer(
      async (base) => {
        const res = await fetch(`${base}/relayers`);
        expect(res.status).toBe(503);
        expect(((await res.json()) as RelayersBody).error).toContain("rpc exploded");
      },
      undefined,
      sink,
      async () => {
        throw new Error("rpc exploded");
      },
    );
  });

  it("serves balances as decimal strings, not JSON numbers", async () => {
    // Wei exceeds Number.MAX_SAFE_INTEGER; a numeric encoding would round it.
    await withServer(
      async (base) => {
        const raw = await (await fetch(`${base}/relayers`)).text();
        expect(raw).toContain('"3000000000000000000"');
      },
      undefined,
      sink,
      async () => 3_000_000_000_000_000_000n,
    );
  });
});
