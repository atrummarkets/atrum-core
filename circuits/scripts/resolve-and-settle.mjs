/**
 * Operator tool: resolve a market, then publish its decrypted totals.
 *
 * NOT CLIENT CODE. This needs the resolver's Ethereum key (to call `vault.resolve`) and the
 * disclosed committee secret (to decrypt and prove), and neither belongs in a browser tab --
 * the resolver key is a real wallet, and the browser's own justification for holding secrets
 * is that it holds nothing but the user's own. In the real design a publisher service runs
 * this on a cadence; this is the manual equivalent, for testing before that service exists.
 *
 * `publishFinalTotals` is PERMISSIONLESS on the contract (EncryptedParimutuelPool.sol:165,
 * no access modifier) -- resolving is not, `vault.resolve` checks `msg.sender == resolver`.
 * So `settle` can run from any funded key; `resolve` needs the specific resolver key.
 *
 * Reuses lib/elgamal.mjs (BSGS-bounded decrypt) and lib/dleq.mjs (buildDLEQ) verbatim --
 * this is exactly what gen_settlement_fixtures.mjs already does against synthetic
 * ciphertexts; this script does the same math against the real on-chain accumulator.
 *
 * Usage:
 *   PRIVATE_KEY=0x... POOL=0x... node scripts/resolve-and-settle.mjs resolve <marketId> <YES|NO>
 *   PRIVATE_KEY=0x... POOL=0x... node scripts/resolve-and-settle.mjs settle  <marketId>
 */
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { ethers } from "ethers";
import { buildElGamal } from "./lib/elgamal.mjs";
import { buildDLEQ } from "./lib/dleq.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const RPC = process.env.RPC_URL ?? "https://testnet-rpc.monad.xyz";

// Bet sizes in this project are denomination UNITS (10, 100, ...), not raw token amounts --
// see Denominations.sol. BSGS is O(sqrt(bound)), so this is generous for testing and still
// instant: sqrt(10^7) is ~3,163 steps.
const DECRYPT_BOUND = 10_000_000n;

const VAULT_ABI = [
  "function outcome() view returns (uint8)",
  "function resolve(uint8 outcome_)",
];
const POOL_ABI = [
  "function marketVault(uint32) view returns (address)",
  "function encryptedTotals() view returns (address)",
];
const TOTALS_ABI = [
  "function accumulator() view returns (address)",
  "function settled(uint32) view returns (bool)",
  "function finalYesTotal(uint32) view returns (uint256)",
  "function finalNoTotal(uint32) view returns (uint256)",
  "function publishFinalTotals(uint32 marketId, uint256 yesTotal, uint256 noTotal, " +
    "tuple(uint256 dx, uint256 dy, tuple(uint256 ax, uint256 ay, uint256 bx, uint256 by, uint256 z) proof) yes, " +
    "tuple(uint256 dx, uint256 dy, tuple(uint256 ax, uint256 ay, uint256 bx, uint256 by, uint256 z) proof) no)",
];
const ACCUMULATOR_ABI = [
  "function totalAffine(uint32 marketId, uint8 outcome) view returns " +
    "(uint256 c1x, uint256 c1y, uint256 c2x, uint256 c2y)",
];

function die(msg) {
  console.error(`error: ${msg}`);
  process.exit(1);
}

function requiredEnv(name) {
  const v = process.env[name];
  if (!v) die(`missing required env var ${name}`);
  return v;
}

async function main() {
  const [cmd, marketArg, ...rest] = process.argv.slice(2);
  if (!cmd) {
    console.log(
      "usage:\n" +
        "  resolve-and-settle.mjs resolve <marketId> <YES|NO>\n" +
        "  resolve-and-settle.mjs settle  <marketId>",
    );
    process.exit(1);
  }

  const marketId = Number(marketArg);
  if (!Number.isInteger(marketId)) die("marketId must be an integer");

  const provider = new ethers.providers.JsonRpcProvider(RPC);
  const wallet = new ethers.Wallet(requiredEnv("PRIVATE_KEY"), provider);
  const poolAddress = requiredEnv("POOL");
  const pool = new ethers.Contract(poolAddress, POOL_ABI, wallet);

  const vaultAddress = await pool.marketVault(marketId);
  if (vaultAddress === ethers.constants.AddressZero) {
    die(`market ${marketId} is not registered on ${poolAddress}`);
  }
  const vault = new ethers.Contract(vaultAddress, VAULT_ABI, wallet);

  if (cmd === "resolve") {
    const side = (rest[0] ?? "").toUpperCase();
    const outcome = { YES: 1, NO: 2 }[side];
    if (outcome === undefined) die("outcome must be YES or NO (never Void -- see Vault.sol)");

    const current = await vault.outcome();
    if (current !== 0) die(`market ${marketId} is already resolved (outcome=${current})`);

    console.log(`resolving market ${marketId} as ${side}…`);
    const tx = await vault.resolve(outcome);
    console.log(`tx: ${tx.hash}`);
    const receipt = await tx.wait();
    console.log(`status: ${receipt.status === 1 ? "SUCCESS" : "FAILED"}, block ${receipt.blockNumber}`);
    process.exit(receipt.status === 1 ? 0 : 1);
  }

  if (cmd === "settle") {
    const outcome = await vault.outcome();
    if (outcome === 0) die(`market ${marketId} has not been resolved yet -- run 'resolve' first`);
    if (outcome === 3) {
      console.log(
        `market ${marketId} is Void -- redeemPrivate's void path needs no published totals.\n` +
          "Nothing to settle.",
      );
      process.exit(0);
    }

    const totalsAddress = await pool.encryptedTotals();
    if (totalsAddress === ethers.constants.AddressZero) die("encryptedTotals is not bound on this pool");
    const totals = new ethers.Contract(totalsAddress, TOTALS_ABI, wallet);

    if (await totals.settled(marketId)) {
      const [y, n] = await Promise.all([totals.finalYesTotal(marketId), totals.finalNoTotal(marketId)]);
      console.log(`market ${marketId} is already settled: YES=${y} NO=${n}`);
      process.exit(0);
    }

    const accumulatorAddress = await totals.accumulator();
    const accumulator = new ethers.Contract(accumulatorAddress, ACCUMULATOR_ABI, wallet);

    const key = JSON.parse(readFileSync(join(HERE, "..", "build", "committee-key.json"), "utf8"));
    const elgamal = await buildElGamal(key.pubKey, key.secret);
    const dleq = buildDLEQ(elgamal, key.secret);
    const { babyJub, F, asPair } = elgamal;
    const pointOf = (x, y) => [F.e(BigInt(x.toString())), F.e(BigInt(y.toString()))];
    const pt = (p) => asPair(p).map(String);

    async function settleSide(sideOutcome, label) {
      const [c1x, c1y, c2x, c2y] = await accumulator.totalAffine(marketId, sideOutcome);
      const c1 = pointOf(c1x, c1y);
      const c2 = pointOf(c2x, c2y);

      const claimed = elgamal.decrypt(c1, c2, DECRYPT_BOUND);
      console.log(`  ${label}: decrypted total = ${claimed}`);

      const proof = dleq.prove(c1);

      // Verify what we are about to publish BEFORE publishing it -- the non-negotiable
      // gen_settlement_fixtures.mjs enforces: a valid DLEQ proof next to a fabricated total
      // is exactly the attack _checkClaimedPlaintext exists to catch, and trusting the BSGS
      // result blind here would defeat the point of checking it at all.
      const D = asPair(proof.D);
      const target = babyJub.addPoint(c2, elgamal.negate(proof.D));
      const mG =
        claimed === 0n ? elgamal.IDENTITY : babyJub.mulPointEscalar(babyJub.Base8, claimed);
      if (!elgamal.samePoint(target, mG)) {
        throw new Error(`${label}: C2 - D != [claimed]G -- refusing to publish a lying total`);
      }

      return {
        total: claimed,
        decryption: {
          dx: D[0],
          dy: D[1],
          proof: { ax: pt(proof.A)[0], ay: pt(proof.A)[1], bx: pt(proof.B)[0], by: pt(proof.B)[1], z: proof.z.toString() },
        },
      };
    }

    console.log(`settling market ${marketId}…`);
    const yes = await settleSide(1, "YES");
    const no = await settleSide(2, "NO");

    console.log(`publishing: YES=${yes.total} NO=${no.total}`);
    const tx = await totals.publishFinalTotals(marketId, yes.total, no.total, yes.decryption, no.decryption);
    console.log(`tx: ${tx.hash}`);
    const receipt = await tx.wait();
    console.log(`status: ${receipt.status === 1 ? "SUCCESS" : "FAILED"}, block ${receipt.blockNumber}`);
    process.exit(receipt.status === 1 ? 0 : 1);
  }

  die(`unknown command '${cmd}' -- expected 'resolve' or 'settle'`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
