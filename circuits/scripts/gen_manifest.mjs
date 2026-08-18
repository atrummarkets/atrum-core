#!/usr/bin/env node
/**
 * THE BUILD-HASH GUARD.
 *
 * Circuit/verifier drift has orphaned three pools. The shape is always the same: circuits
 * are rebuilt, `make verifiers` is not re-run (or is run and not committed), and a
 * deployment goes out whose on-chain verifier belongs to a DIFFERENT proving key than the
 * one the client proves against. Every proof then fails verification on a contract that is
 * otherwise perfectly healthy, and the pool is unusable with no diagnostic pointing at the
 * cause.
 *
 * Nothing in the repo could catch this, because the two halves live in different trees:
 *
 *     circuits/build/<c>_vkey.json      <-- what the prover proves against
 *     contracts/src/verifiers/<N>.sol   <-- what the chain verifies with
 *
 * `DeploymentInvariants` check #7 asserts each verifier address has code. It cannot assert
 * the code is the RIGHT code, so a stale verifier passes every existing check.
 *
 * WHAT THIS DOES, AND WHY IT IS A DERIVATION RATHER THAN AN ASSERTION
 *
 * A snarkjs Solidity verifier is a pure function of its verification key: every curve point
 * in the vkey appears as a `uint256 constant` in the contract. So the two halves can be
 * compared directly, constant by constant, with no trust in a recorded hash and no need for
 * the (large, gitignored, non-reproducible) zkey to be present.
 *
 *   1. Parse the vkey constants back OUT of each committed verifier .sol.
 *   2. Compare them against `<c>_vkey.json`, field by field. Any mismatch is drift; the
 *      script names the exact constant so the failure is diagnosable in one read.
 *   3. Only then emit the manifest: sha256 of each canonical vkey, plus the verifier source
 *      hash, into `circuits/build/circuit-manifest.json` and `contracts/src/CircuitManifest.sol`.
 *
 * Step 3 is deliberately downstream of step 2. Emitting a hash of whatever happens to be on
 * disk would record the drift rather than catch it -- the manifest would faithfully describe
 * a broken build. The manifest is only ever written for a build that has already been proved
 * self-consistent.
 *
 * SCOPE. This binds circuit artifact <-> committed verifier source. It does NOT yet bind
 * committed source <-> deployed bytecode; that is the codehash check in
 * `DeploymentInvariants`, which consumes the constants this script emits.
 *
 * Usage:
 *   node scripts/gen_manifest.mjs            # check, then write the manifest
 *   node scripts/gen_manifest.mjs --check    # check only, write nothing (CI)
 */

import { createHash } from "node:crypto";
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(HERE, "../..");
const BUILD = resolve(ROOT, "circuits/build");
const VERIFIERS = resolve(ROOT, "contracts/src/verifiers");

const CHECK_ONLY = process.argv.includes("--check");

/**
 * circuit artifact name -> verifier contract name. Mirrors the `verifiers` target in the
 * Makefile, and MUST stay in step with it: a circuit present there and absent here is a
 * circuit this guard silently does not cover, which is the exact failure mode the guard
 * exists to remove. The pairing is asserted against the Makefile below.
 */
const CIRCUITS = [
  ["probe_fixed_key", "FixedKeyVerifier"],
  ["probe_pubkey_input", "PubKeyInputVerifier"],
  ["deposit", "DepositVerifier"],
  ["bet", "BetVerifier"],
  ["redeem", "RedeemVerifier"],
  ["bet_encrypted", "BetEncryptedVerifier"],
  ["redeem_private", "RedeemPrivateVerifier"],
  ["withdraw", "WithdrawVerifier"],
];

// ---------------------------------------------------------------------------

const red = (s) => `\x1b[31m${s}\x1b[0m`;
const green = (s) => `\x1b[32m${s}\x1b[0m`;
const dim = (s) => `\x1b[2m${s}\x1b[0m`;

/**
 * snarkjs writes G2 coordinates as [c0, c1]; the Solidity template names them x1/x2 with
 * x1 = c1 and x2 = c0. The swap is real and easy to get backwards, so it is written once,
 * here, and every G2 field goes through it.
 */
const g2 = (pt) => ({ x1: pt[0][1], x2: pt[0][0], y1: pt[1][1], y2: pt[1][0] });

/** Constant name -> expected decimal string, derived from the vkey. */
function expectedConstants(vkey) {
  const beta = g2(vkey.vk_beta_2);
  const gamma = g2(vkey.vk_gamma_2);
  const delta = g2(vkey.vk_delta_2);

  const out = {
    alphax: vkey.vk_alpha_1[0],
    alphay: vkey.vk_alpha_1[1],
    betax1: beta.x1, betax2: beta.x2, betay1: beta.y1, betay2: beta.y2,
    gammax1: gamma.x1, gammax2: gamma.x2, gammay1: gamma.y1, gammay2: gamma.y2,
    deltax1: delta.x1, deltax2: delta.x2, deltay1: delta.y1, deltay2: delta.y2,
  };

  vkey.IC.forEach((pt, i) => {
    out[`IC${i}x`] = pt[0];
    out[`IC${i}y`] = pt[1];
  });

  return out;
}

/** Pull every `uint256 constant NAME = VALUE;` out of a verifier source. */
function parseConstants(source) {
  const found = {};
  const re = /uint256\s+constant\s+(\w+)\s*=\s*(\d+)\s*;/g;
  let m;
  while ((m = re.exec(source)) !== null) found[m[1]] = m[2];
  return found;
}

/**
 * The Makefile is the thing that actually produces these files, so it -- not this script --
 * is the authority on which circuits exist. Reading the pairs back out of it means adding a
 * circuit to the build without adding it here is a hard failure rather than a silent gap in
 * coverage.
 */
function assertCoversMakefile() {
  const mk = readFileSync(resolve(ROOT, "Makefile"), "utf8");
  const target = mk.split("\nverifiers:")[1];
  if (!target) {
    console.error(red("could not find the `verifiers:` target in the Makefile"));
    console.error("  This guard reads its circuit list from there. Adjust the parser.");
    process.exit(1);
  }
  const block = target.split("\n\n")[0];
  const inMakefile = new Set([...block.matchAll(/"(\w+):(\w+)"/g)].map((m) => `${m[1]}:${m[2]}`));
  const here = new Set(CIRCUITS.map(([c, n]) => `${c}:${n}`));

  const missing = [...inMakefile].filter((p) => !here.has(p));
  const extra = [...here].filter((p) => !inMakefile.has(p));

  if (missing.length || extra.length) {
    console.error(red("\nFAIL  the circuit list here disagrees with the Makefile\n"));
    for (const p of missing) console.error(`  built by make, NOT guarded here : ${p}`);
    for (const p of extra) console.error(`  guarded here, NOT built by make  : ${p}`);
    console.error("\n  Update CIRCUITS in this file so every built verifier is covered.\n");
    process.exit(1);
  }
}

// ---------------------------------------------------------------------------

assertCoversMakefile();

console.log("==> binding circuit artifacts to committed verifiers\n");

const manifest = {};
let failures = 0;

for (const [circuit, contract] of CIRCUITS) {
  const vkeyPath = resolve(BUILD, `${circuit}_vkey.json`);
  const solPath = resolve(VERIFIERS, `${contract}.sol`);

  if (!existsSync(vkeyPath)) {
    console.error(`${red("MISSING")}  ${circuit}_vkey.json  ${dim("-- run `make circuits`")}`);
    failures++;
    continue;
  }
  if (!existsSync(solPath)) {
    console.error(`${red("MISSING")}  ${contract}.sol  ${dim("-- run `make verifiers`")}`);
    failures++;
    continue;
  }

  const vkeySource = readFileSync(vkeyPath, "utf8");
  const vkey = JSON.parse(vkeySource);
  const solSource = readFileSync(solPath, "utf8");

  const expected = expectedConstants(vkey);
  const actual = parseConstants(solSource);

  const diverged = [];
  for (const [name, want] of Object.entries(expected)) {
    if (actual[name] !== want) diverged.push({ name, want, got: actual[name] ?? "(absent)" });
  }

  // A vkey with N public signals has N+1 IC points. A verifier carrying a different count
  // is a different circuit shape, not merely a different key -- and it would fail in a way
  // that reads like a calldata packing bug rather than like drift.
  const icInSol = Object.keys(actual).filter((k) => /^IC\d+x$/.test(k)).length;
  const icInVkey = vkey.IC.length;
  if (icInSol !== icInVkey) {
    diverged.push({ name: "IC point count", want: String(icInVkey), got: String(icInSol) });
  }

  if (diverged.length) {
    failures++;
    console.error(`${red("DRIFT")}    ${contract}  ${dim(`vs ${circuit}_vkey.json`)}`);
    for (const d of diverged.slice(0, 4)) {
      console.error(`           ${d.name}`);
      console.error(`             vkey : ${d.want}`);
      console.error(`             .sol : ${d.got}`);
    }
    if (diverged.length > 4) {
      console.error(`           ${dim(`... and ${diverged.length - 4} more constants`)}`);
    }
    continue;
  }

  // sha256 over the vkey bytes exactly as written. This is the circuit's identity for
  // anything downstream (deployment records, the client's artifact check, release notes).
  const vkeyHash = createHash("sha256").update(vkeySource).digest("hex");
  const solHash = createHash("sha256").update(solSource).digest("hex");

  manifest[circuit] = {
    contract,
    nPublic: vkey.nPublic,
    vkeySha256: vkeyHash,
    verifierSourceSha256: solHash,
  };

  console.log(
    `${green("ok")}       ${contract.padEnd(24)} ${String(vkey.nPublic).padStart(2)} signals   ${dim(vkeyHash.slice(0, 16))}`,
  );
}

console.log("");

if (failures) {
  console.error(red(`FAILED -- ${failures} verifier(s) do not match their circuit artifact.\n`));
  console.error("  The deployed chain would reject every proof the client generates.");
  console.error("  Fix with:  make circuits && make verifiers\n");
  console.error("  If you only rebuilt circuits, `make verifiers` is the missing step, and");
  console.error("  the regenerated .sol files must be COMMITTED -- an uncommitted verifier");
  console.error("  is drift that only reproduces on someone else's machine.\n");
  process.exit(1);
}

if (CHECK_ONLY) {
  console.log(green("PASSED -- every verifier matches its circuit artifact.") + dim(" (--check: nothing written)\n"));
  process.exit(0);
}

// ---------------------------------------------------------------------------
// Emit. Only reached when every pair above agreed.

const jsonPath = resolve(BUILD, "circuit-manifest.json");
writeFileSync(jsonPath, JSON.stringify(manifest, null, 2) + "\n");

const solLines = [
  "// SPDX-License-Identifier: UNLICENSED",
  "pragma solidity 0.8.28;",
  "",
  "/// @title CircuitManifest",
  "/// @notice Which proving key each deployed verifier belongs to.",
  "///",
  "/// @dev GENERATED by `circuits/scripts/gen_manifest.mjs`. Do not edit by hand -- a hand",
  "///      edit makes this file agree with a verifier it was not derived from, which is",
  "///      precisely the drift it exists to detect.",
  "///",
  "///      Each hash is sha256 over the canonical `<circuit>_vkey.json` emitted by",
  "///      `snarkjs zkey export verificationkey`. It identifies the PROVING KEY, so it",
  "///      changes whenever the trusted setup is re-run -- including after the ceremony.",
  "///      That is intended: a post-ceremony deployment must not accept pre-ceremony",
  "///      artifacts, and this is what makes that a compile-time fact rather than a",
  "///      procedural one.",
  "library CircuitManifest {",
];

for (const [circuit, entry] of Object.entries(manifest)) {
  const name = circuit.toUpperCase().replace(/[^A-Z0-9]/g, "_");
  solLines.push(`    /// @dev ${entry.contract}, ${entry.nPublic} public signals.`);
  solLines.push(`    bytes32 internal constant ${name}_VKEY = 0x${entry.vkeySha256};`);
  solLines.push("");
}

solLines.push("}");

const manifestSolPath = resolve(ROOT, "contracts/src/CircuitManifest.sol");
writeFileSync(manifestSolPath, solLines.join("\n") + "\n");

console.log(green("PASSED -- every verifier matches its circuit artifact."));
console.log(`  wrote ${dim("circuits/build/circuit-manifest.json")}`);
console.log(`  wrote ${dim("contracts/src/CircuitManifest.sol")}\n`);
