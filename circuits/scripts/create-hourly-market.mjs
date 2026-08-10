/**
 * Operator tool: deploy ONE new Pyth-resolved market with a fixed, hourly shape, and record
 * it both locally (markets.json) and in production (Postgres, via the app's own API).
 *
 * WHY THIS EXISTS SEPARATELY FROM create-market.mjs. That script is built for realistic,
 * variable-length markets: it leaves a quiet period between betting close and the price
 * check, and defaults to a ~61-minute resolution margin. Both are wrong for a market meant to
 * open, close and resolve within about an hour, end to end. This script hardcodes that shape
 * instead of overloading create-market.mjs's env knobs every run:
 *
 *   bettingCloseTime   = now + 3600            betting is open for exactly one hour
 *   targetTime         = bettingCloseTime      price is checked the instant betting closes
 *   windowSeconds       = 300                  liveness margin for a Pyth update to land
 *   resolutionStartTime = targetTime + 240     clears Vault.MIN_RESOLUTION_GAP (3 min) with
 *                                               margin, so the market is resolvable well
 *                                               before the next 5-minute sweep-markets.yml
 *                                               tick picks it up
 *
 * WHY IT ALSO POSTS TO THE APP, NOT JUST markets.json. The market registry moved into
 * Postgres (atrum-markets commit "Move the market registry into Postgres, so creating a
 * market is not a deploy"). `loadRegistry()` only falls back to markets.json when the table
 * has no rows for the pool, so a market written only to the file would be live on chain and
 * invisible in the app. Uses the same `lib/register-market.mjs` helper `create-market.mjs`
 * and `create-manual-market.mjs` now use (see commit "Register new markets with the app over
 * HTTP, not by rewriting a file") rather than a second copy of the same sign-in flow: it
 * authenticates as the operator (server-issued nonce, personal_sign, cookie) and POSTs to
 * `/api/atrum/admin/markets`, which verifies the vault on chain itself before accepting the
 * row -- a wrong body can misregister a market but never misprice one. Best-effort by that
 * helper's own design: a POST failure here means the app has not been told, not that anything
 * on chain broke, so it warns rather than dying and burning the id.
 *
 * IDEMPOTENT ACROSS RETRIES. The market id is `max(existing ids) + 1`, read fresh from the
 * app each run. If a previous run deployed the vault and called registerEncryptedMarket but
 * crashed before the POST landed, that id is taken on chain but still missing from Postgres --
 * re-deploying would revert with MarketAlreadyRegistered. So before deploying, this checks
 * `pool.marketVault(candidateId)` directly: if it is already set, the vault is reused (its
 * on-chain timing is read back, not re-derived) and only the POST is retried.
 *
 * Usage:
 *   PRIVATE_KEY=0x... POOL=0x... APP_URL=https://markets.atrum.fun \
 *     node scripts/create-hourly-market.mjs
 *
 * Env:
 *   PRIVATE_KEY          pool admin key -- deploys the Vault and calls registerEncryptedMarket
 *   OPERATOR_PRIVATE_KEY the app's operator key, for the admin/markets POST. Defaults to
 *                        PRIVATE_KEY -- true on this deployment, where one throwaway key plays
 *                        both roles. If a real deployment splits them, set this explicitly.
 *   POOL                 the ShieldedPool address
 *   APP_URL               the running atrum-markets app (default https://markets.atrum.fun).
 *                         MARKETS_BASE_URL is accepted as an alias.
 *   RPC_URL               default https://testnet-rpc.monad.xyz
 *   REGISTRY              default ../../../atrum-markets/markets.json
 */
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { ethers } from "ethers";
import { registerWithApp } from "./lib/register-market.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const RPC = process.env.RPC_URL ?? "https://testnet-rpc.monad.xyz";
const REGISTRY_PATH =
  process.env.REGISTRY ?? join(HERE, "..", "..", "..", "atrum-markets", "markets.json");
// `||`, not `??`: an unset GitHub Actions secret/var interpolates to an EMPTY STRING in the
// env block (`APP_URL: ${{ vars.APP_URL }}` with no var set), not an absent key -- `??` only
// falls through on null/undefined, so it would have kept "" and every fetch below would have
// hit a relative URL.
const APP_URL = (
  process.env.APP_URL || process.env.MARKETS_BASE_URL || "https://markets.atrum.fun"
).replace(/\/$/, "");

// Same feed directory as create-market.mjs (verified live against Hermes, not copied from
// memory -- see that file's comment for how).
const FEEDS = {
  BTC: "0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43",
  ETH: "0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace",
  SOL: "0xef0d8b6fda2ceba41da15d4095d1da392a0d2f8ed0c6c7bc0f4cfac8c280b56d",
};
const ROTATION = ["BTC", "ETH", "SOL"];

const WINDOW_SECONDS = 300;
const RESOLUTION_MARGIN_SECONDS = 240;
const CLOSE_DURATION_SECONDS = 3600;

const POOL_ABI = [
  "function admin() view returns (address)",
  "function marketVault(uint32) view returns (address)",
  "function registerEncryptedMarket(uint32 marketId, address vault)",
];
const RESOLVER_ABI = ["function hashSpec((bytes32,int64,int32,uint64,uint64,bool)) view returns (bytes32)"];
const VAULT_ABI = [
  "function bettingCloseTime() view returns (uint64)",
  "function resolutionStartTime() view returns (uint64)",
  "function resolver() view returns (address)",
  "function collateral() view returns (address)",
  "function denomination() view returns (uint256)",
];

function die(msg) {
  console.error(`error: ${msg}`);
  process.exit(1);
}

async function nextMarketId() {
  const res = await fetch(`${APP_URL}/api/atrum/markets`);
  if (!res.ok) die(`GET /api/atrum/markets -> ${res.status}`);
  const { markets } = await res.json();
  const maxId = markets.reduce((m, x) => Math.max(m, x.id), -1);
  return maxId + 1;
}

async function main() {
  const privateKey = process.env.PRIVATE_KEY;
  const operatorKey = process.env.OPERATOR_PRIVATE_KEY || privateKey; // see APP_URL's note on || vs ??
  const poolAddress = process.env.POOL;
  if (!privateKey) die("missing PRIVATE_KEY");
  if (!poolAddress) die("missing POOL");

  const provider = new ethers.providers.JsonRpcProvider(RPC);
  const wallet = new ethers.Wallet(privateKey, provider);
  const operatorWallet = new ethers.Wallet(operatorKey, provider);
  const pool = new ethers.Contract(poolAddress, POOL_ABI, wallet);

  const admin = await pool.admin();
  if (admin.toLowerCase() !== wallet.address.toLowerCase()) {
    die(`PRIVATE_KEY (${wallet.address}) is not this pool's admin (${admin})`);
  }

  const marketId = await nextMarketId();
  const symbol = ROTATION[marketId % ROTATION.length];
  const direction = marketId % 2 === 0 ? "above" : "below";
  const priceId = FEEDS[symbol];

  console.log(`next market id: ${marketId} (${symbol} ${direction})`);

  const now = Math.floor(Date.now() / 1000);

  // --- Recovery path: this id may already be deployed on chain from a crashed prior run. ---
  const existingVault = await pool.marketVault(marketId);
  let vaultAddress;
  let bettingCloseTime;
  let resolutionStartTime;
  let resolverAddress;
  let spec;
  let question;

  if (existingVault !== ethers.constants.AddressZero) {
    console.log(`market ${marketId} already deployed at ${existingVault} -- recovering, not redeploying`);
    vaultAddress = existingVault;
    const vault = new ethers.Contract(existingVault, VAULT_ABI, wallet);
    [bettingCloseTime, resolutionStartTime, resolverAddress] = await Promise.all([
      vault.bettingCloseTime(),
      vault.resolutionStartTime(),
      vault.resolver(),
    ]);
    bettingCloseTime = Number(bettingCloseTime);
    resolutionStartTime = Number(resolutionStartTime);
    // Recovering the exact spec used at deploy time is not possible from chain state alone
    // (only its hash is stored); this run's freshly-computed spec is used for the registry
    // record, matching what resolve-oracle-market.mjs / autoResolveDue actually need: the
    // targetTime/window this deploy used, not the price observed at deploy time. Since
    // targetTime == bettingCloseTime deterministically here, it round-trips correctly.
    const targetTime = bettingCloseTime;
    spec = {
      priceId,
      threshold: null,
      thresholdExpo: -8,
      targetTime,
      windowSeconds: WINDOW_SECONDS,
      greaterThan: direction === "above",
    };
    question = `Will ${symbol} be ${direction} $? at ${new Date(targetTime * 1000).toISOString()}? (recovered, threshold unknown -- see spec)`;
    console.warn(
      "warning: recovered market has no known threshold (only its hash survives on chain) -- " +
        "resolve-oracle-market.mjs / autoResolveDue need the ORIGINAL spec.threshold, which is lost. " +
        "This should not happen in normal operation; investigate why the previous run crashed after " +
        "deploying but before recording.",
    );
  } else {
    const currentPrice = await (async () => {
      const res = await fetch(`https://hermes.pyth.network/v2/updates/price/latest?ids[]=${priceId}`);
      const body = await res.json();
      const p = body.parsed[0].price;
      return Number(p.price) * 10 ** p.expo;
    })();
    console.log(`${symbol}/USD right now: $${currentPrice.toFixed(2)}`);

    bettingCloseTime = now + CLOSE_DURATION_SECONDS;
    const targetTime = bettingCloseTime;
    resolutionStartTime = targetTime + RESOLUTION_MARGIN_SECONDS;

    const thresholdExpo = -8;
    const threshold = BigInt(Math.round(currentPrice * 10 ** -thresholdExpo));

    spec = {
      priceId,
      threshold: threshold.toString(),
      thresholdExpo,
      targetTime,
      windowSeconds: WINDOW_SECONDS,
      greaterThan: direction === "above",
    };
    question = `Will ${symbol} be ${direction} $${currentPrice.toLocaleString(undefined, { maximumFractionDigits: 2 })} at ${new Date(targetTime * 1000).toISOString()}?`;
    console.log(question);

    // Reuse the pool's existing PythResolver, same discovery method as create-market.mjs.
    const market10Vault = await pool.marketVault(10);
    if (market10Vault === ethers.constants.AddressZero) {
      die("no market 10 on this pool to read the PythResolver address from -- pass RESOLVER=0x... to override");
    }
    resolverAddress =
      process.env.RESOLVER ??
      (await new ethers.Contract(market10Vault, VAULT_ABI, wallet).resolver());
    const resolver = new ethers.Contract(resolverAddress, RESOLVER_ABI, wallet);

    const resolutionSpecHash = await resolver.hashSpec([
      priceId,
      threshold,
      thresholdExpo,
      targetTime,
      WINDOW_SECONDS,
      direction === "above",
    ]);

    const collateral = await new ethers.Contract(market10Vault, VAULT_ABI, wallet).collateral();
    const denomination = await new ethers.Contract(market10Vault, VAULT_ABI, wallet).denomination();

    const vaultArtifactPath = join(HERE, "lib", "vault-artifact.json");
    if (!existsSync(vaultArtifactPath)) die(`missing committed artifact at ${vaultArtifactPath}`);
    const vaultArtifact = JSON.parse(readFileSync(vaultArtifactPath, "utf8"));

    console.log(
      `deploying Vault (betting closes ${new Date(bettingCloseTime * 1000).toISOString()}, ` +
        `resolvable after ${new Date(resolutionStartTime * 1000).toISOString()})…`,
    );

    const VaultFactory = new ethers.ContractFactory(vaultArtifact.abi, vaultArtifact.bytecode.object, wallet);
    const vault = await VaultFactory.deploy(
      collateral,
      denomination,
      resolverAddress,
      resolutionSpecHash,
      bettingCloseTime,
      resolutionStartTime,
    );
    await vault.deployed();
    vaultAddress = vault.address;
    console.log(`Vault: ${vaultAddress}`);

    console.log("registering market…");
    const tx = await pool.registerEncryptedMarket(marketId, vaultAddress);
    const receipt = await tx.wait();
    console.log(`status: ${receipt.status === 1 ? "SUCCESS" : "FAILED"}, block ${receipt.blockNumber}`);
    if (receipt.status !== 1) die("registerEncryptedMarket failed");
  }

  // --- markets.json, for local dev / manual CLI tooling. Best-effort: in CI this repo is
  // checked out alone, so the sibling atrum-markets tree (and REGISTRY_PATH) does not exist.
  // Postgres, updated below, is what production actually reads -- this is a convenience for
  // running create-market.mjs / resolve-oracle-market.mjs locally against the same file. ---
  const marketRecord = {
    id: marketId,
    question,
    category: "Crypto",
    resolverType: "oracle",
    vault: vaultAddress,
    resolver: resolverAddress,
    bettingCloseTime,
    resolutionStartTime,
    createdAt: now,
    spec,
  };

  try {
    const registry = existsSync(REGISTRY_PATH)
      ? JSON.parse(readFileSync(REGISTRY_PATH, "utf8"))
      : { pool: poolAddress, collateral: "", markets: [] };
    registry.pool = poolAddress;
    registry.markets = registry.markets.filter((m) => m.id !== marketId);
    registry.markets.push(marketRecord);
    registry.markets.sort((a, b) => a.id - b.id);
    writeFileSync(REGISTRY_PATH, `${JSON.stringify(registry, null, 2)}\n`);
    console.log(`recorded in ${REGISTRY_PATH}`);
  } catch (error) {
    console.warn(`skipping local markets.json (${error.message}) -- continuing to app registration`);
  }

  // --- Postgres, via the app's own API, so it's live immediately. Shared helper: same one
  // create-market.mjs and create-manual-market.mjs use, same best-effort semantics. ---
  await registerWithApp(APP_URL, operatorWallet, marketRecord);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
