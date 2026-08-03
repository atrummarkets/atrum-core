/**
 * Resolve an oracle (Pyth) market -- the counterpart to `resolve-and-settle.mjs resolve`,
 * which only handles the human-resolver path (`vault.resolve()` called directly by the
 * resolver address). An oracle market resolves differently: through PythResolver.resolve(),
 * which verifies a signed price update and calls `vault.resolve()` itself. Nobody calls
 * `vault.resolve()` by hand for these.
 *
 * After this, settlement is identical either way -- `resolve-and-settle.mjs settle` already
 * works unchanged, because it only checks `vault.outcome() != Unresolved`, not how it got
 * there.
 *
 * Usage:
 *   PRIVATE_KEY=0x... node scripts/resolve-oracle-market.mjs <marketId>
 *
 * Reads the market's spec from atrum-markets/markets.json (written by create-market.mjs),
 * fetches the FIRST Pyth update at or after the committed targetTime from Hermes, and
 * submits it. Permissionless on the contract -- any funded key can call this, per
 * PythResolver.sol's own design.
 */
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { ethers } from "ethers";

const HERE = dirname(fileURLToPath(import.meta.url));
const RPC = process.env.RPC_URL ?? "https://testnet-rpc.monad.xyz";
const REGISTRY_PATH =
  process.env.REGISTRY ?? join(HERE, "..", "..", "..", "atrum-markets", "markets.json");

// `spec` is ABI-encoded bytes on the wire (built with defaultAbiCoder below), not a raw
// tuple argument -- `PythResolver.resolve` decodes it internally.
const RESOLVER_ABI = ["function resolve(address vault, bytes spec, bytes[] oracleData) payable"];

function die(msg) {
  console.error(`error: ${msg}`);
  process.exit(1);
}

async function main() {
  const [marketIdArg] = process.argv.slice(2);
  if (!marketIdArg) {
    console.log("usage: resolve-oracle-market.mjs <marketId>");
    process.exit(1);
  }
  const marketId = Number(marketIdArg);

  const privateKey = process.env.PRIVATE_KEY;
  if (!privateKey) die("missing PRIVATE_KEY");

  const registry = JSON.parse(readFileSync(REGISTRY_PATH, "utf8"));
  const market = registry.markets.find((m) => m.id === marketId);
  if (!market) die(`market ${marketId} not found in ${REGISTRY_PATH}`);
  if (market.resolverType !== "oracle") die(`market ${marketId} is resolverType '${market.resolverType}', not oracle`);
  if (!market.spec) die(`market ${marketId} has no recorded spec -- can't resolve it`);

  const now = Math.floor(Date.now() / 1000);
  if (now < market.spec.targetTime) {
    die(
      `too early -- targetTime is ${new Date(market.spec.targetTime * 1000).toISOString()}, ` +
        `now is ${new Date(now * 1000).toISOString()}`,
    );
  }

  console.log(`resolving market ${marketId}: ${market.question}`);
  console.log(`fetching Pyth update at/after ${new Date(market.spec.targetTime * 1000).toISOString()}…`);

  const res = await fetch(
    `https://hermes.pyth.network/v2/updates/price/${market.spec.targetTime}?ids[]=${market.spec.priceId}`,
  );
  if (!res.ok) die(`Hermes returned ${res.status} -- no update found in range, or feed id is wrong`);
  const body = await res.json();
  const parsed = body.parsed[0];
  const price = Number(parsed.price.price) * 10 ** parsed.price.expo;
  console.log(
    `got: $${price.toFixed(2)} at ${new Date(parsed.price.publish_time * 1000).toISOString()} `
    + `(claimed: ${market.spec.greaterThan ? "above" : "below"} $${Number(market.spec.threshold) * 10 ** market.spec.thresholdExpo})`,
  );

  const oracleData = [`0x${body.binary.data[0]}`];

  const provider = new ethers.providers.JsonRpcProvider(RPC);
  const wallet = new ethers.Wallet(privateKey, provider);
  const resolver = new ethers.Contract(market.resolver, RESOLVER_ABI, wallet);

  const specEncoded = ethers.utils.defaultAbiCoder.encode(
    ["tuple(bytes32,int64,int32,uint64,uint64,bool)"],
    [[
      market.spec.priceId,
      market.spec.threshold,
      market.spec.thresholdExpo,
      market.spec.targetTime,
      market.spec.windowSeconds,
      market.spec.greaterThan,
    ]],
  );

  // Pyth's own getUpdateFee, read directly rather than through the resolver -- the resolver
  // only exposes it bundled with a specific vault/spec call, and the fee itself does not
  // depend on either.
  const pythAbi = ["function getUpdateFee(bytes[] updateData) view returns (uint256)"];
  const pyth = new ethers.Contract(await new ethers.Contract(market.resolver, ["function pyth() view returns (address)"], wallet).pyth(), pythAbi, wallet);
  const fee = await pyth.getUpdateFee(oracleData);
  console.log(`update fee: ${ethers.utils.formatEther(fee)} MON`);

  console.log("submitting…");
  const tx = await resolver.resolve(market.vault, specEncoded, oracleData, {
    value: fee,
    gasLimit: 2_000_000,
  });
  console.log(`tx: ${tx.hash}`);
  const receipt = await tx.wait();
  console.log(`status: ${receipt.status === 1 ? "SUCCESS" : "FAILED"}, block ${receipt.blockNumber}`);
  console.log(receipt.status === 1 ? "market resolved -- run 'resolve-and-settle.mjs settle' next" : "");
  process.exit(receipt.status === 1 ? 0 : 1);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
