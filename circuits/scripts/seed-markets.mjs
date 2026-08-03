/**
 * Operator tool: create a batch of manually-resolved markets and record them in a registry.
 *
 * WHY A REGISTRY FILE. `ShieldedPool` has no on-chain way to enumerate markets -- there is no
 * array, only `marketVault[id]` lookups -- and this project's standing rule is never to build
 * on `eth_getLogs` (the public Monad RPC caps range at 100 blocks). So the front end reads a
 * committed registry and verifies each entry against the chain, rather than scanning.
 *
 * The registry is a CACHE OF IDs, not a source of truth: every field the UI actually acts on
 * (betting window, outcome, totals) is re-read from the vault on each request. A stale or
 * tampered registry can only ever cause a market to be listed or missed, never mispriced.
 *
 * Usage:
 *   PRIVATE_KEY=0x... POOL=0x... node scripts/seed-markets.mjs
 */
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { ethers } from "ethers";

const HERE = dirname(fileURLToPath(import.meta.url));
const RPC = process.env.RPC_URL ?? "https://testnet-rpc.monad.xyz";
const REGISTRY_PATH =
  process.env.REGISTRY ?? join(HERE, "..", "..", "..", "atrum-markets", "markets.json");

const POOL_ABI = [
  "function admin() view returns (address)",
  "function marketVault(uint32) view returns (address)",
  "function collateral() view returns (address)",
  "function registerEncryptedMarket(uint32 marketId, address vault)",
];

const HOUR = 3600;
const DAY = 86400;

/**
 * The seed set. Deliberately varied in BOTH category and clock: a markets page with one
 * question and one deadline tells you nothing about whether the listing, the countdown or the
 * phase transitions actually work.
 */
const MARKETS = [
  { id: 31, category: "Crypto",   question: "Will BTC close above $100,000 this week?",                    closesIn: 5 * DAY },
  { id: 32, category: "Crypto",   question: "Will ETH flip $4,000 before the end of the month?",           closesIn: 12 * DAY },
  { id: 33, category: "Monad",    question: "Will Monad mainnet clear 10,000 TPS sustained before October?", closesIn: 20 * DAY },
  { id: 34, category: "Monad",    question: "Will Monad testnet TPS exceed 5,000 today?",                  closesIn: 1 * DAY },
  { id: 35, category: "AI",       question: "Will a frontier lab ship a model above 2M context this quarter?", closesIn: 9 * DAY },
  { id: 36, category: "Markets",  question: "Will prediction-market monthly volume top $12B this quarter?", closesIn: 15 * DAY },
  // A deliberately short window, so the closed/resolvable states are reachable without waiting
  // days. Not decoration: every phase the UI renders should be reachable in a demo.
  { id: 37, category: "Monad",    question: "Will the next Monad testnet block land under 500ms? (short window)", closesIn: 2 * HOUR },
];

function die(msg) {
  console.error(`error: ${msg}`);
  process.exit(1);
}

async function main() {
  const privateKey = process.env.PRIVATE_KEY;
  const poolAddress = process.env.POOL;
  if (!privateKey) die("missing PRIVATE_KEY");
  if (!poolAddress) die("missing POOL");

  const provider = new ethers.providers.JsonRpcProvider(RPC);
  const wallet = new ethers.Wallet(privateKey, provider);
  const pool = new ethers.Contract(poolAddress, POOL_ABI, wallet);

  const admin = await pool.admin();
  if (admin.toLowerCase() !== wallet.address.toLowerCase()) {
    die(`PRIVATE_KEY (${wallet.address}) is not this pool's admin (${admin})`);
  }

  const reference = await pool.marketVault(8);
  if (reference === ethers.constants.AddressZero) die("no market 8 to read collateral/denomination from");
  const collateral = await new ethers.Contract(reference, ["function collateral() view returns (address)"], wallet).collateral();
  const denomination = await new ethers.Contract(reference, ["function denomination() view returns (uint256)"], wallet).denomination();

  const vaultArtifactPath = join(HERE, "..", "..", "contracts", "out", "Vault.sol", "Vault.json");
  if (!existsSync(vaultArtifactPath)) die(`no forge artifact at ${vaultArtifactPath} -- run 'forge build' in contracts/`);
  const vaultArtifact = JSON.parse(readFileSync(vaultArtifactPath, "utf8"));
  const VaultFactory = new ethers.ContractFactory(vaultArtifact.abi, vaultArtifact.bytecode.object, wallet);

  const registry = existsSync(REGISTRY_PATH)
    ? JSON.parse(readFileSync(REGISTRY_PATH, "utf8"))
    : { pool: poolAddress, collateral, markets: [] };
  registry.pool = poolAddress;
  registry.collateral = collateral;

  for (const spec of MARKETS) {
    const existing = await pool.marketVault(spec.id);
    if (existing !== ethers.constants.AddressZero) {
      console.log(`market ${spec.id} already registered at ${existing} -- skipping`);
      continue;
    }

    const now = Math.floor(Date.now() / 1000);
    const bettingCloseTime = now + spec.closesIn;
    // Vault.MIN_RESOLUTION_GAP is 3 minutes on this deployment (a demo value; production
    // intent is 1 hour). Five minutes clears it with margin.
    const resolutionStartTime = bettingCloseTime + 300;

    console.log(`\n${spec.id}: ${spec.question}`);
    const vault = await VaultFactory.deploy(
      collateral,
      denomination,
      wallet.address,
      ethers.utils.id(spec.question),
      bettingCloseTime,
      resolutionStartTime,
    );
    await vault.deployed();
    const tx = await pool.registerEncryptedMarket(spec.id, vault.address);
    const receipt = await tx.wait();
    if (receipt.status !== 1) die(`registering market ${spec.id} failed`);
    console.log(`  vault ${vault.address}  (block ${receipt.blockNumber})`);

    registry.markets = registry.markets.filter((m) => m.id !== spec.id);
    registry.markets.push({
      id: spec.id,
      question: spec.question,
      category: spec.category,
      resolverType: "manual",
      vault: vault.address,
      resolver: wallet.address,
      bettingCloseTime,
      resolutionStartTime,
      createdAt: now,
    });
    registry.markets.sort((a, b) => a.id - b.id);
    writeFileSync(REGISTRY_PATH, `${JSON.stringify(registry, null, 2)}\n`);
  }

  console.log(`\nregistry written to ${REGISTRY_PATH} (${registry.markets.length} markets)`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
