/**
 * Register a freshly created market with the running app, so it is live without a deploy.
 *
 * WHY THIS EXISTS. `markets.json` was the registry, read out of atrum-markets' deployment
 * bundle -- so a market created here did not exist as far as production was concerned until
 * someone committed the regenerated file and waited for Vercel. Creating a market was a
 * deploy, and during a live demo that is minutes of dead time per market.
 *
 * OVER HTTP, NOT STRAIGHT INTO POSTGRES, so this repo never needs `DATABASE_URL`. The one
 * credential the creation scripts already hold is the operator key, which is exactly what the
 * endpoint authenticates -- and the same key already had to sign the on-chain registration a
 * moment earlier, so this adds no new secret anywhere.
 *
 * BEST EFFORT BY DESIGN. The market is already registered on chain by the time this runs; a
 * failure here means the app has not been told, not that anything is broken. So it warns and
 * returns rather than throwing, and `db/import-markets.mjs` can always backfill from the file.
 * Killing a script after a successful on-chain registration would be strictly worse: the id is
 * permanently taken (`registerEncryptedMarket` reverts on a used id) and re-running it fails.
 */
import { ethers } from "ethers";

/**
 * @param {string} appUrl      e.g. https://markets.atrum.fun -- skipped entirely when unset
 * @param {ethers.Wallet} wallet  the operator key that just registered the market on chain
 * @param {object} market      the registry row: id, question, category, resolverType, vault,
 *                             resolver, bettingCloseTime, resolutionStartTime, createdAt, spec
 */
export async function registerWithApp(appUrl, wallet, market) {
  if (!appUrl) {
    console.log("APP_URL not set -- skipping app registration (run db/import-markets.mjs to backfill)");
    return false;
  }

  const base = appUrl.replace(/\/$/, "");

  try {
    // Sign in exactly as a browser does: server-issued single-use nonce, personal_sign, cookie.
    const nonceRes = await fetch(`${base}/api/atrum/auth/nonce`);
    if (!nonceRes.ok) throw new Error(`auth/nonce -> ${nonceRes.status}`);
    const { nonce, message } = await nonceRes.json();

    const signature = await wallet.signMessage(message);

    const verifyRes = await fetch(`${base}/api/atrum/auth/verify`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ address: wallet.address, nonce, signature }),
    });
    if (!verifyRes.ok) {
      throw new Error(`auth/verify -> ${verifyRes.status}: ${JSON.stringify(await verifyRes.json())}`);
    }
    const cookie = verifyRes.headers
      .getSetCookie()
      .find((c) => c.startsWith("atrum_session="))
      ?.split(";")[0];
    if (!cookie) throw new Error("no session cookie returned");

    const res = await fetch(`${base}/api/atrum/admin/markets`, {
      method: "POST",
      headers: { "content-type": "application/json", cookie },
      body: JSON.stringify(market),
    });
    const body = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(`admin/markets -> ${res.status}: ${body.error ?? "unknown"}`);

    console.log(`registered with ${base} -- live now, no deploy needed`);
    return true;
  } catch (error) {
    console.warn(
      `warning: could not register with ${base}: ${error.message}\n` +
        "         The market IS on chain. Run db/import-markets.mjs in atrum-markets to backfill.",
    );
    return false;
  }
}
