import { test } from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { createHash, generateKeyPairSync, verify } from "node:crypto";
import worker, { decide, latestEntry, privateKeyBytes, publicHealth, readPublication, runCheck, sourceProof, timestamp } from "./worker.mjs";

const now = Date.parse("2026-10-07T00:00:00Z");
const minute = 60_000;
const at = minutes => new Date(now - minutes * minute).toISOString();
const id = "tftset18-18.3-r425-m0123456789";
const refresh = ".github/workflows/refresh-tft-data.yml";
const redeploy = ".github/workflows/deploy-pages.yml";
const repository = "test-owner/test-data";
const api = `https://api.github.com/repos/${repository}`;
const indexUrl = "https://test-owner.github.io/test-data/data-index.json";
const manifest = { id, setId: "TFTSet18", patch: "18.3", revision: "425", files: [] };
const hash = text => createHash("sha256").update(text).digest("hex");
const manifestText = JSON.stringify(manifest);
const entry = { ...manifest, manifestUrl: `bundles/${id}/manifest.json`, manifestSha256: hash(manifestText), sourceTimestampUtc: at(60) };
const index = { latestVersionId: id, latestAvailableVersionId: id, versions: [entry] };
const quality = { schemaVersion: 1, versionId: id, setId: "TFTSet18", patch: "18.3", revision: "425", qualityState: "DEGRADED_OPTIONAL" };
const publication = { aligned: true, versionId: id, sourceAt: at(60) };
const run = (options = {}) => ({ id: 100, path: refresh, event: "schedule", head_branch: "main", status: "completed", conclusion: "success", created_at: at(30), updated_at: at(20), ...options });
const proofJobs = [{ conclusion: "success", steps: [{ name: `Source verified: ${id}`, conclusion: "success", completed_at: at(20) }] }];
function fixture(options = {}) {
  let stored = options.state || {};
  const calls = [];
  const env = { ENABLED: "true", GITHUB_TOKEN: "test-secret-not-for-logs", GITHUB_REPOSITORY: repository, DATA_INDEX_URL: indexUrl,
    STATE: { get: async () => structuredClone(stored), put: async (_key, value) => { stored = JSON.parse(value); } } };
  const fetcher = async (input, init = {}) => {
    const url = new URL(input);
    calls.push({ url: url.href, init });
    if (options.fetchFailure?.(url)) throw new Error("private-url-secret-must-not-leak");
    if (url.hostname !== "api.github.com") assert.equal(init.headers?.Authorization, undefined, "credentials must never leave the GitHub API host");
    const value = (body, status = 200) => new Response(typeof body === "string" ? body : JSON.stringify(body), { status });
    if (url.pathname.endsWith("/dispatches")) return new Response(null, { status: options.dispatchStatus || 204 });
    if (url.pathname.endsWith("/actions/runs")) return value({ workflow_runs: options.runs || [run()] });
    if (url.pathname.endsWith("/git/ref/heads/main")) return value({ object: { sha: "a".repeat(40) } });
    if (url.pathname.endsWith("/jobs")) return value({ jobs: options.jobs || proofJobs });
    if (url.pathname.endsWith("/manifest.json")) return value(options.manifestText ?? manifestText);
    if (url.pathname.endsWith("/data-index.json")) {
      if (url.hostname.endsWith("github.io")) return value(options.publicIndex ?? index, options.publicStatus || 200);
      return value(options.trackedIndex ?? index);
    }
    if (url.pathname.endsWith("/data-quality.json")) return value(url.hostname.endsWith("github.io") ? options.publicQuality ?? quality : quality);
    throw new Error(`Unexpected fixture request ${url.pathname}`);
  };
  return { env, fetcher, calls, state: () => stored };
}
const decision = (runs = [], changes = {}) => decide({ runs, publication, state: {}, now, ...changes });

test("production transport preserves the Workers native fetch receiver", async () => {
  const f = fixture();
  const originalFetch = globalThis.fetch;
  globalThis.fetch = function(input, init) {
    assert.equal(this, globalThis, "Workers native fetch rejects an unbound receiver");
    return f.fetcher(input, init);
  };
  try {
    const result = await runCheck(f.env, { now });
    assert.equal(result.status, "CHECKED");
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("diagnostics locate a failure without exposing its message or untrusted name", async () => {
  const f = fixture({ fetchFailure: () => true });
  const failed = await runCheck(f.env, { fetcher: f.fetcher, now });
  assert.equal(failed.failureStage, "RUN_QUEUE");
  assert.equal(failed.failureKind, "OTHER");
  assert.ok(!JSON.stringify(failed).includes("private-url-secret"));
  const recovered = await runCheck(f.env, { fetcher: fixture().fetcher, now: now + minute });
  assert.equal(recovered.failureStage, null);
  assert.equal(recovered.failureKind, null);
});

test("independent dispatch when all GitHub schedules have been silent for six hours", () => {
  assert.equal(decision([run({ created_at: at(400) })]).action, "REFRESH");
});
test("15-minute cadence is based on start, not completion", () => {
  assert.equal(decision([run({ created_at: at(16), updated_at: at(1) })]).action, "REFRESH");
  assert.equal(decision([run({ created_at: at(14) })]).reason, "REFRESH_INTERVAL");
});
for (const status of ["queued", "in_progress", "waiting", "requested", "pending"]) {
  test(`never duplicate an active ${status} publication`, () => {
    assert.equal(decision([run({ status, conclusion: null })]).reason, "RUN_IN_PROGRESS");
  });
}
test("stalled publication is reported, not repeatedly replaced", () => {
  assert.equal(decision([run({ status: "queued", created_at: at(90) })]).reason, "RUN_STALLED");
});
test("other branches and unrelated CI do not suppress main", () => {
  assert.equal(decision([run({ head_branch: "feature", status: "queued" }), run({ path: ".github/workflows/tests.yml", status: "in_progress" })]).action, "REFRESH");
});
test("publication repair reuses the validated site instead of reacquiring upstream", () => {
  assert.equal(decision([], { publication: { aligned: false, reason: "PUBLIC_QUALITY_MISMATCH" } }).action, "REDEPLOY");
});
test("failure backoff prevents infinite rapid retries and remains recoverable", () => {
  const failed = [0, 1, 2, 3].map((n) => run({ id: 100 + n, conclusion: "failure", created_at: at(16 + n * 20) }));
  assert.equal(decision(failed).reason, "FAILURE_BACKOFF");
  assert.equal(decision(failed, { now: now + 121 * minute }).action, "REFRESH");
});
test("ambiguous dispatch has a reserved cooldown", () => {
  assert.equal(decision([], { state: { lastDispatchAt: at(5) } }).reason, "DISPATCH_COOLDOWN");
});
test("valid no-change proof advances check time without changing immutable version", () => {
  assert.deepEqual(sourceProof(run(), proofJobs, id, now), { runId: "100", versionId: id, checkedAt: at(20) });
});
for (const variant of [
  { name: "failed run", current: run({ conclusion: "failure" }), jobs: proofJobs, id },
  { name: "feature branch", current: run({ head_branch: "other" }), jobs: proofJobs, id },
  { name: "untrusted pull request", current: run({ event: "pull_request" }), jobs: proofJobs, id },
  { name: "SOURCE_NOT_READY green run", current: run(), jobs: [{ conclusion: "success", steps: [] }], id },
  { name: "different version", current: run(), jobs: proofJobs, id: `${id}x` },
  { name: "skipped evidence", current: run(), jobs: [{ conclusion: "success", steps: [{ ...proofJobs[0].steps[0], conclusion: "skipped" }] }], id },
]) test(`reject ${variant.name} as freshness evidence`, () => assert.equal(sourceProof(variant.current, variant.jobs, variant.id, now), null));
test("local timezone cannot silently change UTC timestamps", () => {
  assert.equal(timestamp("2026-10-07T09:00:00+09:00"), now);
  assert.throws(() => timestamp("2026-10-07 09:00:00"));
});
test("index rejects duplicate identities and unsafe manifest paths", () => {
  assert.throws(() => latestEntry({ ...index, versions: [entry, entry] }));
  for (const path of ["../manifest.json", "https://evil.invalid/manifest.json", "C:/manifest.json"]) assert.throws(() => latestEntry({ ...index, versions: [{ ...entry, manifestUrl: path }] }));
});
test("HTTP requests cannot dispatch, including secret-looking paths", async () => {
  const f = fixture();
  for (const [path, method] of [["/refresh", "GET"], ["/health", "POST"], ["/dispatch", "POST"]]) assert.equal((await worker.fetch(new Request(`https://watch.invalid${path}`, { method }), f.env)).status, 404);
  assert.equal(f.calls.length, 0);
});
test("normal end-to-end check uses authenticated GitHub only and dispatches one refresh", async () => {
  const f = fixture();
  const result = await runCheck(f.env, { fetcher: f.fetcher, now });
  assert.equal(result.status, "CHECKED");
  assert.equal(result.lastAction, "REFRESH");
  assert.equal(result.sourceVerifiedAt, at(20));
  const writes = f.calls.filter(c => c.init.method === "POST");
  assert.equal(writes.length, 1);
  assert.equal(writes[0].url, `${api}/actions/workflows/refresh-tft-data.yml/dispatches`);
  assert.deepEqual(JSON.parse(writes[0].init.body), { ref: "main" });
  assert.ok(!JSON.stringify(f.state()).includes("test-secret"));
});
test("publication failure requests a bounded redeploy and keeps latest unchanged", async () => {
  const f = fixture({ publicQuality: { ...quality, versionId: `${id}old` } });
  const result = await runCheck(f.env, { fetcher: f.fetcher, now });
  assert.equal(result.status, "PUBLICATION_DELAYED");
  assert.equal(result.lastAction, "REDEPLOY");
  assert.equal(f.calls.filter(c => c.init.method === "POST")[0].url, `${api}/actions/workflows/deploy-pages.yml/dispatches`);
});
for (const code of [404, 500]) test(`Pages ${code} triggers safe redeployment`, async () => {
  const f = fixture({ publicStatus: code });
  const result = await runCheck(f.env, { fetcher: f.fetcher, now });
  assert.equal(result.lastAction, "REDEPLOY");
  assert.equal(result.publicVersionId, null);
});
test("manifest tampering cannot be marked verified", async () => {
  const f = fixture({ manifestText: `${manifestText} ` });
  const result = await runCheck(f.env, { fetcher: f.fetcher, now });
  assert.equal(result.publicationAligned, false);
  assert.equal(result.lastAction, "REDEPLOY");
});
test("GitHub API failure causes no speculative writes and no secret disclosure", async () => {
  const f = fixture({ fetchFailure: u => u.hostname === "api.github.com" });
  const result = await runCheck(f.env, { fetcher: f.fetcher, now });
  assert.equal(result.status, "CHECK_FAILED");
  assert.equal(f.calls.filter(c => c.init.method === "POST").length, 0);
  assert.ok(!JSON.stringify(result).includes("private-url"));
});
test("ambiguous POST failure cannot hammer dispatch on the next check", async () => {
  const f = fixture({ dispatchStatus: 500 });
  assert.equal((await runCheck(f.env, { fetcher: f.fetcher, now })).status, "CHECK_FAILED");
  const second = await runCheck(f.env, { fetcher: f.fetcher, now: now + 5 * minute });
  assert.equal(second.reason, "DISPATCH_COOLDOWN");
  assert.equal(f.calls.filter(c => c.init.method === "POST").length, 1);
});
test("disabled setup makes zero network calls", async () => {
  const f = fixture(); f.env.ENABLED = "false";
  assert.equal((await runCheck(f.env, { fetcher: f.fetcher, now })).status, "DISABLED");
  assert.equal(f.calls.length, 0);
});
test("source age and successful source check age remain separate", async () => {
  const f = fixture({ jobs: [] });
  const result = await runCheck(f.env, { fetcher: f.fetcher, now });
  assert.equal(result.status, "DATA_CHECK_OVERDUE");
  assert.equal(result.sourceVerifiedAt, null);
  assert.equal(result.publicSourceUpdatedAt, at(60));
});
test("stopped independent clock cannot leave a permanently green health page", () => {
  assert.equal(publicHealth({ checkedAt: at(13), status: "CHECKED" }, now).status, "MONITOR_STALE");
});
test("META_UPDATE changes invalidate prior source proof even on the same patch", () => {
  assert.equal(publicHealth({ checkedAt: at(1), status: "CHECKED", publication: { versionId: `${id}new`, sourceAt: at(60) }, sourceProof: { versionId: id, checkedAt: at(1) } }, now).sourceVerifiedAt, null);
});
test("evidence stays bounded over 48h and never grows history without limit", async () => {
  const f = fixture(); f.env.ENABLED = "false";
  for (let i = 0; i < 577; i++) await runCheck(f.env, { fetcher: f.fetcher, now: now + i * 5 * minute });
  assert.equal(f.state().recent.length, 20);
  assert.equal(f.state().observationCount, 577);
  assert.equal(f.state().maximumCheckGapMinutes, 5);
  assert.ok(JSON.stringify(f.state()).length < 8192);
});
test("GitHub PKCS1 download imports as valid PKCS8 without external libraries", async () => {
  const { privateKey, publicKey } = generateKeyPairSync("rsa", { modulusLength: 2048 });
  const pem = privateKey.export({ type: "pkcs1", format: "pem" });
  const key = await crypto.subtle.importKey("pkcs8", privateKeyBytes(pem), { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["sign"]);
  const data = new TextEncoder().encode("installation token fixture");
  assert.ok(verify("SHA256", data, publicKey, Buffer.from(await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, data))));
});
test("installation tokens are short-lived and restricted to the single data repository", async () => {
  const f = fixture();
  delete f.env.GITHUB_TOKEN;
  const { privateKey, publicKey } = generateKeyPairSync("rsa", { modulusLength: 2048 });
  Object.assign(f.env, { GITHUB_APP_ID: "1234", GITHUB_INSTALLATION_ID: "5678", GITHUB_APP_PRIVATE_KEY: privateKey.export({ type: "pkcs1", format: "pem" }) });
  let issued = 0;
  const fetcher = async (url, init = {}) => {
    if (String(url).endsWith("/access_tokens")) {
      issued++;
      assert.equal(String(url), "https://api.github.com/app/installations/5678/access_tokens");
      assert.deepEqual(JSON.parse(init.body), { repositories: ["test-data"], permissions: { actions: "write", contents: "read" } });
      const [head, payload, signature] = init.headers.Authorization.slice(7).split(".");
      assert.ok(verify("SHA256", Buffer.from(`${head}.${payload}`), publicKey, Buffer.from(signature, "base64url")));
      const claims = JSON.parse(Buffer.from(payload, "base64url"));
      assert.equal(claims.iss, "1234");
      assert.ok(claims.exp - claims.iat <= 600);
      return Response.json({ token: "installation-fixture", expires_at: new Date(now + 60 * minute).toISOString() });
    }
    return f.fetcher(url, init);
  };
  const result = await runCheck(f.env, { fetcher, now });
  assert.equal(result.status, "CHECKED");
  assert.equal(issued, 1);
  assert.ok(!JSON.stringify(f.state()).includes("PRIVATE KEY"));
  await runCheck(f.env, { fetcher, now: now + 5 * minute });
  assert.equal(issued, 1, "a valid installation token is reused without requesting one every five minutes");
});
test("all fixed-root quality readers preserve the cache-busting query", async () => {
  for (const name of ["tools/reconcile-publication.ps1", ".github/scripts/check-refresh-freshness.ps1", "tools/check-public-data-quality.ps1"]) {
    const text = await readFile(new URL(`../${name}`, import.meta.url), "utf8");
    assert.match(text, /Get-TftPublicDataQualityUri \$indexUri/);
  }
});
test("source proof step cannot run for SOURCE_NOT_READY", async () => {
  const text = await readFile(new URL("../.github/workflows/refresh-tft-data.yml", import.meta.url), "utf8");
  assert.match(text, /name: "Source verified: \$\{\{ steps\.refresh\.outputs\.detected_version \}\}"\s+if: success\(\) && \(steps\.refresh\.outputs\.result == 'NO_CHANGE' \|\| steps\.refresh\.outputs\.result == 'PUBLISHED'\)/);
});
