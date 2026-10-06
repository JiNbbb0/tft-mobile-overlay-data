// Read-only smoke probe. Does not authenticate, dispatch, alter latest or fetch
// MetaTFT. This is not a Cloudflare scheduling/performance test.
import { readPublication } from "./worker.mjs";
const repository = "JiNbbb0/tft-mobile-overlay-data";
const response = await fetch(`https://api.github.com/repos/${repository}/git/ref/heads/main`, {
  headers: { "User-Agent": "TFT-Independent-Watchdog-Probe" }, signal: AbortSignal.timeout(15_000), redirect: "error",
});
if (!response.ok) throw new Error(`GitHub read failed: ${response.status}`);
const head = await response.json();
const result = await readPublication({ repository, commitSha: head.object.sha, index: new URL("https://jinbbb0.github.io/tft-mobile-overlay-data/data-index.json") }, fetch, Date.now());
console.log(JSON.stringify(result, null, 2));
if (!result.aligned) process.exitCode = 1;
