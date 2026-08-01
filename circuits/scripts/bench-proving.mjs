/**
 * Measure Groth16 proving time for the four live circuits, under Node, on this machine.
 *
 * WHY THIS IS NOT JUST A CURIOSITY. The browser client's whole architecture turns on a
 * multiplier -- how much slower proving is in a tab than in Node -- and a multiplier is
 * meaningless if its two halves come from different machines. HANDOFF.md records Node
 * timings from one machine on one day; this machine proves the same circuits roughly twice
 * as fast. Dividing a browser number measured here by those figures would understate the
 * multiplier by about 2x, in the unsafe direction.
 *
 * So the client measures the browser, this measures Node, and `atrum-client`'s sync step
 * copies the JSON below across so the two are always compared like for like.
 *
 * It doubles as a correctness gate: it proves AND verifies every circuit, so a fixture that
 * no longer matches a rebuilt circuit fails here in seconds rather than in a browser tab
 * after a 30MB download.
 *
 * Usage: make bench
 */

import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import * as snarkjs from "snarkjs";

const BUILD = join(dirname(fileURLToPath(import.meta.url)), "..", "build");

// Node timings recorded in HANDOFF.md's proving spike, kept only for comparison.
const CIRCUITS = [
  { name: "deposit", handoffMs: 322 },
  { name: "bet_encrypted", handoffMs: 2255 },
  { name: "redeem_private", handoffMs: 1437 },
  { name: "withdraw", handoffMs: 1411 },
];

const inputs = JSON.parse(readFileSync(join(BUILD, "witness-inputs.json"), "utf8"));

const fmt = (ms) => (ms >= 1000 ? `${(ms / 1000).toFixed(2)}s` : `${Math.round(ms)}ms`);

console.log("\nGroth16 proving, Node, this machine");
console.log("=".repeat(64));
console.log(
  "circuit".padEnd(16) +
    "prove".padStart(10) +
    "verify".padStart(10) +
    "HANDOFF".padStart(10) +
    "drift".padStart(10) +
    "  ok",
);
console.log("-".repeat(64));

let failed = 0;
const measured = {};

for (const { name, handoffMs } of CIRCUITS) {
  const base = join(BUILD, name);
  const input = inputs[name];

  if (!input) {
    console.log(`${name.padEnd(16)}${"no fixture input".padStart(40)}`);
    failed += 1;
    continue;
  }

  try {
    const t0 = performance.now();
    const { proof, publicSignals } = await snarkjs.groth16.fullProve(
      input,
      join(BUILD, `${name}_js`, `${name}.wasm`),
      `${base}.zkey`,
    );
    const proveMs = performance.now() - t0;

    const vkey = JSON.parse(readFileSync(`${base}_vkey.json`, "utf8"));
    const t1 = performance.now();
    const ok = await snarkjs.groth16.verify(vkey, publicSignals, proof);
    const verifyMs = performance.now() - t1;

    if (!ok) failed += 1;
    measured[name] = { proveMs, verifyMs, ok };

    const drift = (proveMs / handoffMs - 1) * 100;
    console.log(
      name.padEnd(16) +
        fmt(proveMs).padStart(10) +
        fmt(verifyMs).padStart(10) +
        `${handoffMs}ms`.padStart(10) +
        `${drift >= 0 ? "+" : ""}${drift.toFixed(0)}%`.padStart(10) +
        `  ${ok ? "ok" : "PROOF REJECTED"}`,
    );
  } catch (e) {
    console.log(`${name.padEnd(16)}  ERROR: ${e.message}`);
    failed += 1;
  }
}

console.log("=".repeat(64));

writeFileSync(
  join(BUILD, "proving-baseline.json"),
  `${JSON.stringify(
    {
      measuredAt: new Date().toISOString(),
      runtime: `node ${process.version}`,
      circuits: measured,
    },
    null,
    2,
  )}\n`,
);

if (failed) {
  console.error(
    `\n${failed} circuit(s) failed. If proofs are being rejected, the zkey and vkey are\n` +
      "from different builds -- re-run `make circuits`.\n",
  );
  process.exit(1);
}

console.log(
  "\nAll proofs verified. Wrote build/proving-baseline.json — atrum-client's sync step\n" +
    "copies it so the browser multiplier is computed against the same machine.\n",
);

// snarkjs leaves ffjavascript's worker pool running and it holds the event loop open
// forever. prove.mjs:139 and gen_action_fixtures.mjs:799 end the same way.
process.exit(0);
