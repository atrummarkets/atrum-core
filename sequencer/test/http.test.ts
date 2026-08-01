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
const fake = {
  tree: { size: 7, root: () => 12345n },
  pathFor(commitment: bigint) {
    if (commitment !== 99n) throw new Error("commitment not found in the mirror");
    return {
      index: 3,
      root: 12345n,
      path: { pathElements: [1n, 2n], pathIndices: [0n, 1n] },
    };
  },
};

async function withServer<T>(fn: (base: string) => Promise<T>, origin?: string): Promise<T> {
  const server = createServer(createPathHandler(fake, origin));
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
