/**
 * Operator tool: register a manually-resolved encrypted market on an existing pool.
 *
 * Same shape as create-market.mjs, but the resolver is the deployer's own EOA rather than
 * PythResolver -- for a live demo where resolution is triggered by hand
 * (resolve-and-settle.mjs), not by a price feed.
 *
 * Usage:
 *   PRIVATE_KEY=0x... POOL=0x... node scripts/create-manual-market.mjs \
 *     <marketId> "<question>" <bettingCloseSeconds> <resolutionGapSeconds>
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

const POOL_ABI = [
  "function admin() view returns (address)",
  "function marketVault(uint32) view returns (address)",
  "function registerEncryptedMarket(uint32 marketId, address vault)",
];

function die(msg) {
  console.error(`error: ${msg}`);
  process.exit(1);
}

async function main() {
  const [marketIdArg, question, closeArg, gapArg] = process.argv.slice(2);
  if (!marketIdArg || !question || !closeArg || !gapArg) {
    die("usage: create-manual-market.mjs <marketId> <question> <bettingCloseSeconds> <resolutionGapSeconds>");
  }
  const marketId = Number(marketIdArg);
  const bettingCloseSeconds = Number(closeArg);
  const resolutionGapSeconds = Number(gapArg);

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
  const existing = await pool.marketVault(marketId);
  if (existing !== ethers.constants.AddressZero) die(`market ${marketId} is already registered`);

  const market8Vault = await pool.marketVault(8);
  if (market8Vault === ethers.constants.AddressZero) {
    die("no market 8 on this pool to read collateral/denomination from");
  }
  const collateral = await new ethers.Contract(market8Vault, ["function collateral() view returns (address)"], wallet).collateral();
  const denomination = await new ethers.Contract(market8Vault, ["function denomination() view returns (uint256)"], wallet).denomination();

  const now = Math.floor(Date.now() / 1000);
  const bettingCloseTime = now + bettingCloseSeconds;
  const resolutionStartTime = bettingCloseTime + resolutionGapSeconds;

  const resolutionSpecHash = ethers.utils.id(question);

  console.log(question);
  console.log(
    `deploying Vault (betting closes ${new Date(bettingCloseTime * 1000).toISOString()}, ` +
      `resolvable after ${new Date(resolutionStartTime * 1000).toISOString()}), resolver = ${wallet.address}…`,
  );

  const vaultArtifactPath = join(HERE, "..", "..", "contracts", "out", "Vault.sol", "Vault.json");
  if (!existsSync(vaultArtifactPath)) die(`no forge artifact at ${vaultArtifactPath} -- run 'forge build' in contracts/`);
  const vaultArtifact = JSON.parse(readFileSync(vaultArtifactPath, "utf8"));

  const VaultFactory = new ethers.ContractFactory(vaultArtifact.abi, vaultArtifact.bytecode.object, wallet);
  const vault = await VaultFactory.deploy(
    collateral,
    denomination,
    wallet.address,
    resolutionSpecHash,
    bettingCloseTime,
    resolutionStartTime,
  );
  await vault.deployed();
  console.log(`Vault: ${vault.address}`);

  console.log("registering market…");
  const tx = await pool.registerEncryptedMarket(marketId, vault.address);
  const receipt = await tx.wait();
  console.log(`status: ${receipt.status === 1 ? "SUCCESS" : "FAILED"}, block ${receipt.blockNumber}`);
  if (receipt.status !== 1) process.exit(1);

  // Same registry shape create-market.mjs writes (see its own note on this) --
  // atrum-markets/registry.ts reads only id/question/category/resolverType/vault/resolver/
  // bettingCloseTime/resolutionStartTime/createdAt; unknown fields are ignored, so the two
  // scripts' extra fields (this one has none, create-market.mjs has `spec`) don't collide.
  const registry = existsSync(REGISTRY_PATH)
    ? JSON.parse(readFileSync(REGISTRY_PATH, "utf8"))
    : { pool: poolAddress, collateral, markets: [] };
  if (registry.pool !== poolAddress) {
    console.log(`note: registry was for pool ${registry.pool}, now recording markets for ${poolAddress}`);
  }
  registry.pool = poolAddress;
  registry.collateral = collateral;
  registry.markets = registry.markets.filter((m) => m.id !== marketId);
  registry.markets.push({
    id: marketId,
    question,
    category: "Monad",
    resolverType: "manual",
    vault: vault.address,
    resolver: wallet.address,
    bettingCloseTime,
    resolutionStartTime,
    createdAt: now,
  });
  registry.markets.sort((a, b) => a.id - b.id);
  writeFileSync(REGISTRY_PATH, `${JSON.stringify(registry, null, 2)}\n`);
  console.log(`recorded in ${REGISTRY_PATH}`);

  // The file is now only a local record and a backfill source -- atrum-markets reads its
  // registry from Postgres. This is what actually makes the market visible.
  // Looked up by id, not `.at(-1)`: both scripts sort the array after pushing, so the
  // last element is the highest id, which is not necessarily the one just created.
  await registerWithApp(
    process.env.APP_URL,
    wallet,
    registry.markets.find((m) => m.id === marketId),
  );

  console.log(
    JSON.stringify(
      {
        marketId,
        question,
        vault: vault.address,
        resolver: wallet.address,
        bettingCloseTime,
        resolutionStartTime,
      },
      null,
      2,
    ),
  );
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
