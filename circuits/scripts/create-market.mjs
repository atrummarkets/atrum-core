/**
 * Operator tool: create a new Pyth-resolved market on an existing pool, without redeploying.
 *
 * ShieldedPool.registerEncryptedMarket has no deploy-time restriction -- it checks
 * `msg.sender == admin` and nothing else, so a pool's admin can add markets for as long as
 * the pool lives. That is the actual answer to "how do we keep testing without redeploying
 * every time": deploy once, create markets on top of it whenever.
 *
 * Two steps, same as Deploy.s.sol does for market 10, just outside the constructor:
 *   1. deploy a Vault, resolver = the pool's existing PythResolver, spec hashed and committed
 *   2. registerEncryptedMarket(marketId, vault)
 *
 * Then appends the market to atrum-client's markets.json registry, because ShieldedPool has
 * no on-chain way to list "all markets" -- no array, just marketVault[id] lookups -- and this
 * project's own rule is never build on eth_getLogs (100-block cap on the public RPC). A
 * committed registry file is the alternative that doesn't need log scanning.
 *
 * Usage:
 *   PRIVATE_KEY=0x... POOL=0x... node scripts/create-market.mjs \
 *     <marketId> <BTC|ETH|SOL> <above|below> <thresholdUSD> <hoursFromNow>
 *
 * Example: "Will BTC be above $65,000 in 24 hours?"
 *   node scripts/create-market.mjs 11 BTC above 65000 24
 */
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { ethers } from "ethers";

const HERE = dirname(fileURLToPath(import.meta.url));
const RPC = process.env.RPC_URL ?? "https://testnet-rpc.monad.xyz";
const REGISTRY_PATH = join(HERE, "..", "..", "..", "atrum-client", "markets.json");

// Verified live against Hermes on 2026-08-02 -- Pyth's own feed directory
// (hermes.pyth.network/v2/price_feeds?query=<SYM>), not copied from memory. A wrong feed id
// fails LOUD (Hermes 404s it), never silently resolves the wrong asset.
const FEEDS = {
  BTC: "0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43",
  ETH: "0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace",
  SOL: "0xef0d8b6fda2ceba41da15d4095d1da392a0d2f8ed0c6c7bc0f4cfac8c280b56d",
};

const POOL_ABI = [
  "function admin() view returns (address)",
  "function marketVault(uint32) view returns (address)",
  "function registerEncryptedMarket(uint32 marketId, address vault)",
];
const RESOLVER_ABI = ["function hashSpec((bytes32,int64,int32,uint64,uint64,bool)) view returns (bytes32)"];
const VAULT_ABI = ["function bettingCloseTime() view returns (uint64)"];

const VAULT_BYTECODE_ABI = [
  "constructor(address collateral, uint256 denomination, address resolver, bytes32 resolutionSpecHash, uint64 bettingCloseTime, uint64 resolutionStartTime)",
];

function die(msg) {
  console.error(`error: ${msg}`);
  process.exit(1);
}

async function main() {
  const [marketIdArg, symbol, direction, thresholdArg, hoursArg] = process.argv.slice(2);
  if (!marketIdArg || !symbol || !direction || !thresholdArg || !hoursArg) {
    console.log(
      "usage: create-market.mjs <marketId> <BTC|ETH|SOL> <above|below> <thresholdUSD> <hoursFromNow>",
    );
    process.exit(1);
  }

  const marketId = Number(marketIdArg);
  const priceId = FEEDS[symbol.toUpperCase()];
  if (!priceId) die(`unknown symbol '${symbol}' -- known: ${Object.keys(FEEDS).join(", ")}`);
  if (direction !== "above" && direction !== "below") die("direction must be 'above' or 'below'");
  const hours = Number(hoursArg);
  if (!Number.isFinite(hours) || hours <= 0) die("hoursFromNow must be a positive number");

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

  // Reuse the pool's existing PythResolver -- it is stateless (the question lives in the
  // spec hash, per-vault), so one resolver serves every oracle-resolved market on this pool.
  // Discovered from an already-registered oracle market rather than assumed -- market 10 is
  // the one Deploy.s.sol always creates.
  const market10Vault = await pool.marketVault(10);
  if (market10Vault === ethers.constants.AddressZero) {
    die("no market 10 on this pool to read the PythResolver address from -- pass RESOLVER=0x... to override");
  }
  const resolverAddress =
    process.env.RESOLVER ??
    (await new ethers.Contract(market10Vault, VAULT_ABI.concat(["function resolver() view returns (address)"]), wallet).resolver());
  const resolver = new ethers.Contract(resolverAddress, RESOLVER_ABI, wallet);

  const currentPrice = await (async () => {
    const res = await fetch(`https://hermes.pyth.network/v2/updates/price/latest?ids[]=${priceId}`);
    const body = await res.json();
    const p = body.parsed[0].price;
    return Number(p.price) * 10 ** p.expo;
  })();
  console.log(`${symbol}/USD right now: $${currentPrice.toFixed(2)}`);

  const now = Math.floor(Date.now() / 1000);
  const targetTime = now + hours * 3600;

  // Betting stays open until shortly before the price is checked -- a real market, not
  // another 6-minute exercise window. Closes 10 minutes before targetTime, or halfway
  // through the duration for anything shorter than 20 minutes total.
  const bettingCloseTime = targetTime - Math.min(600, Math.floor((hours * 3600) / 2));
  if (bettingCloseTime < now + 30) die("hoursFromNow too small -- leaves no real betting window");

  // Threshold is expressed with a fixed exponent here (-8, matching Pyth's own for these
  // feeds) rather than inferring it from the input string -- an inferred exponent is exactly
  // the kind of "looks right, means something else" bug PythResolver.sol's own comments warn
  // about for the price/threshold comparison.
  const thresholdExpo = -8;
  const threshold = BigInt(Math.round(Number(thresholdArg) * 10 ** -thresholdExpo));

  const spec = [priceId, threshold, thresholdExpo, targetTime, 3600, direction === "above"];
  const question = `Will ${symbol} be ${direction} $${Number(thresholdArg).toLocaleString()} at ${new Date(targetTime * 1000).toISOString()}?`;
  console.log(question);

  const resolutionSpecHash = await resolver.hashSpec(spec);
  const resolutionStartTime = targetTime + 3600 + 60; // after the window closes, plus margin

  if (targetTime < bettingCloseTime) die("target time must be after betting closes");

  console.log(
    `deploying Vault (betting closes ${new Date(bettingCloseTime * 1000).toISOString()}, ` +
      `resolvable after ${new Date(resolutionStartTime * 1000).toISOString()})…`,
  );

  const collateral = await new ethers.Contract(market10Vault, ["function collateral() view returns (address)"], wallet).collateral();
  const denomination = await new ethers.Contract(market10Vault, ["function denomination() view returns (uint256)"], wallet).denomination();

  const vaultArtifactPath = join(HERE, "..", "..", "contracts", "out", "Vault.sol", "Vault.json");
  if (!existsSync(vaultArtifactPath)) die(`no forge artifact at ${vaultArtifactPath} -- run 'forge build' in contracts/`);
  const vaultArtifact = JSON.parse(readFileSync(vaultArtifactPath, "utf8"));

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
  console.log(`Vault: ${vault.address}`);

  console.log("registering market…");
  const tx = await pool.registerEncryptedMarket(marketId, vault.address);
  const receipt = await tx.wait();
  console.log(`status: ${receipt.status === 1 ? "SUCCESS" : "FAILED"}, block ${receipt.blockNumber}`);
  if (receipt.status !== 1) process.exit(1);

  const registry = existsSync(REGISTRY_PATH)
    ? JSON.parse(readFileSync(REGISTRY_PATH, "utf8"))
    : { pool: poolAddress, markets: [] };
  if (registry.pool !== poolAddress) {
    console.log(`note: registry was for pool ${registry.pool}, now recording markets for ${poolAddress}`);
    registry.pool = poolAddress;
  }
  registry.markets = registry.markets.filter((m) => m.id !== marketId);
  registry.markets.push({
    id: marketId,
    question,
    type: "oracle",
    symbol: symbol.toUpperCase(),
    direction,
    threshold: thresholdArg,
    vault: vault.address,
    resolver: resolverAddress,
    spec: { priceId, threshold: threshold.toString(), thresholdExpo, targetTime, windowSeconds: 3600, greaterThan: direction === "above" },
    bettingCloseTime,
    resolutionStartTime,
    createdAt: now,
  });
  writeFileSync(REGISTRY_PATH, `${JSON.stringify(registry, null, 2)}\n`);
  console.log(`recorded in ${REGISTRY_PATH}`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
