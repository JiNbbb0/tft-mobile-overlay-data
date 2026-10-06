// Independent clock only. Source acquisition, validation, atomic publication,
// rollback and seven-rank identity remain owned by the existing GitHub pipeline.
const MINUTE = 60_000;
const REFRESH = ".github/workflows/refresh-tft-data.yml";
const REDEPLOY = ".github/workflows/deploy-pages.yml";
const PUBLICATION = new Set([REFRESH, REDEPLOY, ".github/workflows/rollback-latest.yml", ".github/workflows/automation-watchdog.yml"]);
const HASH = /^[0-9a-f]{64}$/;
const ID = /^[a-z0-9][a-z0-9._-]{0,159}$/;
const encoder = new TextEncoder();
let tokenCache;

class CheckError extends Error {
  constructor(code) { super(code); this.code = code; }
}
const fail = code => { throw new CheckError(code); };
const iso = value => new Date(value).toISOString();
export function timestamp(value) {
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}T.*(?:Z|[+-]\d{2}:\d{2})$/.test(value)) fail("INVALID_TIMESTAMP");
  const ms = Date.parse(value);
  if (!Number.isFinite(ms)) fail("INVALID_TIMESTAMP");
  return ms;
}
function configuration(env) {
  const repository = env.GITHUB_REPOSITORY;
  if (!/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(repository || "")) fail("INVALID_CONFIGURATION");
  const index = new URL(env.DATA_INDEX_URL);
  if (index.protocol !== "https:" || index.username || index.password || index.search || index.hash || !index.pathname.endsWith("/data-index.json")) fail("INVALID_CONFIGURATION");
  return { repository, index, api: `https://api.github.com/repos/${repository}` };
}
async function bytes(fetcher, url, options = {}, maximum = 1_048_576) {
  // workerd rejects redirect:"error" before sending a request. Manual mode plus
  // the status gate rejects redirects without ever forwarding credentials.
  const response = await fetcher(url, { ...options, redirect: "manual", signal: AbortSignal.timeout(15_000) });
  if (!response.ok) fail(`HTTP_${response.status}`);
  if (response.headers.get("content-length") && Number(response.headers.get("content-length")) > maximum) fail("RESPONSE_TOO_LARGE");
  if (!response.body) fail("EMPTY_RESPONSE");
  const reader = response.body.getReader();
  const chunks = [];
  let size = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > maximum) { await reader.cancel(); fail("RESPONSE_TOO_LARGE"); }
    chunks.push(value);
  }
  const result = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) { result.set(chunk, offset); offset += chunk.length; }
  return result;
}
const decode = data => new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(data).replace(/^\uFEFF/, "");
const json = async (...args) => JSON.parse(decode(await bytes(...args)));
const sha256 = async data => Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", data)), n => n.toString(16).padStart(2, "0")).join("");
const base64url = data => btoa(String.fromCharCode(...data)).replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");
function der(tag, body) {
  const length = body.length;
  const prefix = length < 128 ? [length] : length < 256 ? [0x81, length] : [0x82, length >> 8, length & 255];
  return new Uint8Array([tag, ...prefix, ...body]);
}
export function privateKeyBytes(pem) {
  if (typeof pem !== "string" || pem.length > 8192 || !/-----BEGIN (RSA )?PRIVATE KEY-----/.test(pem)) fail("APP_KEY_INVALID");
  const decoded = Uint8Array.from(atob(pem.replace(/-----[^-]+-----/g, "").replace(/\s/g, "")), c => c.charCodeAt(0));
  if (!pem.includes("BEGIN RSA PRIVATE KEY")) return decoded;
  // GitHub downloads PKCS#1; Web Crypto imports PKCS#8. DER-wrap the unchanged key.
  return der(0x30, new Uint8Array([0x02, 0x01, 0x00, 0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00, ...der(0x04, decoded)]));
}
async function githubToken(env, fetcher, now, setStage) {
  // A scoped token is supported for bootstrap only. Production should use an
  // installation token renewed automatically, not a PAT with a renewal deadline.
  if (env.GITHUB_TOKEN) return env.GITHUB_TOKEN;
  if (!/^\d+$/.test(env.GITHUB_APP_ID || "") || !/^\d+$/.test(env.GITHUB_INSTALLATION_ID || "")) fail("GITHUB_NOT_CONNECTED");
  const identity = `${env.GITHUB_APP_ID}:${env.GITHUB_INSTALLATION_ID}:${env.GITHUB_REPOSITORY}`;
  if (tokenCache?.identity === identity && tokenCache.expires > now + 5 * MINUTE) return tokenCache.token;
  setStage("APP_KEY_DECODE");
  const keyBytes = privateKeyBytes(env.GITHUB_APP_PRIVATE_KEY);
  setStage("APP_KEY_IMPORT");
  const key = await crypto.subtle.importKey("pkcs8", keyBytes, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["sign"]);
  setStage("APP_JWT_ENCODE");
  const header = base64url(encoder.encode(JSON.stringify({ alg: "RS256", typ: "JWT" })));
  const payload = base64url(encoder.encode(JSON.stringify({ iat: Math.floor(now / 1000) - 60, exp: Math.floor(now / 1000) + 540, iss: env.GITHUB_APP_ID })));
  const signing = `${header}.${payload}`;
  setStage("APP_JWT_SIGN");
  const signature = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, encoder.encode(signing));
  setStage("APP_TOKEN_REQUEST");
  const result = await json(fetcher, `https://api.github.com/app/installations/${env.GITHUB_INSTALLATION_ID}/access_tokens`, {
    method: "POST",
    headers: { ...githubHeaders(`${signing}.${base64url(new Uint8Array(signature))}`), "Content-Type": "application/json" },
    body: JSON.stringify({ repositories: [env.GITHUB_REPOSITORY.split("/")[1]], permissions: { actions: "write", contents: "read" } }),
  }, 16_384);
  if (typeof result.token !== "string" || !result.token || timestamp(result.expires_at) <= now) fail("APP_TOKEN_INVALID");
  tokenCache = { identity, token: result.token, expires: timestamp(result.expires_at) };
  return result.token;
}
function githubHeaders(token) {
  return { Authorization: `Bearer ${token}`, Accept: "application/vnd.github+json", "User-Agent": "TFT-Independent-Watchdog", "X-GitHub-Api-Version": "2022-11-28", "Cache-Control": "no-cache" };
}
export function latestEntry(index) {
  const id = index.latestAvailableVersionId || index.latestVersionId;
  if (!ID.test(id || "") || id.includes("..") || !Array.isArray(index.versions) || index.versions.length > 100) fail("INDEX_INVALID");
  const matches = index.versions.filter(v => v.id === id);
  if (matches.length !== 1 || !HASH.test(matches[0].manifestSha256 || "") || matches[0].manifestUrl !== `bundles/${id}/manifest.json`) fail("INDEX_INVALID");
  return matches[0];
}
const cacheBust = (url, now) => { const value = new URL(url); value.searchParams.set("verification", String(now)); return value.href; };
export async function readPublication(config, fetcher, now) {
  const base = new URL(".", config.index);
  if (!/^[0-9a-f]{40}$/.test(config.commitSha || "")) fail("TRACKED_COMMIT_INVALID");
  const rawBase = `https://raw.githubusercontent.com/${config.repository}/${config.commitSha}/site/`;
  const trackedIndex = await json(fetcher, cacheBust(`${rawBase}data-index.json`, now));
  const tracked = latestEntry(trackedIndex);
  let actual;
  try {
    actual = latestEntry(await json(fetcher, cacheBust(config.index, now)));
  } catch {
    return { versionId: null, sourceAt: null, trackedVersionId: tracked.id, aligned: false, reason: "PUBLIC_INDEX_UNAVAILABLE" };
  }
  const result = { versionId: actual.id, sourceAt: actual.sourceTimestampUtc, setId: actual.setId, patch: actual.patch, trackedVersionId: tracked.id };
  if (tracked.id !== actual.id || tracked.manifestSha256 !== actual.manifestSha256) return { ...result, aligned: false, reason: "PUBLIC_VERSION_MISMATCH" };
  const trackedQualityBytes = await bytes(fetcher, cacheBust(`${rawBase}data-quality.json`, now));
  let manifestBytes, qualityBytes;
  try {
    [manifestBytes, qualityBytes] = await Promise.all([
      bytes(fetcher, new URL(actual.manifestUrl, base).href),
      bytes(fetcher, cacheBust(new URL("data-quality.json", base), now)),
    ]);
  } catch {
    return { ...result, aligned: false, reason: "PUBLIC_PAYLOAD_UNAVAILABLE" };
  }
  if (await sha256(manifestBytes) !== actual.manifestSha256) return { ...result, aligned: false, reason: "PUBLIC_MANIFEST_MISMATCH" };
  const manifest = JSON.parse(decode(manifestBytes));
  let quality;
  try { quality = JSON.parse(decode(qualityBytes)); }
  catch { return { ...result, aligned: false, reason: "PUBLIC_QUALITY_INVALID" }; }
  for (const field of ["setId", "patch", "revision"]) {
    if (String(manifest[field]) !== String(actual[field]) || String(quality[field]) !== String(actual[field])) return { ...result, aligned: false, reason: "PUBLIC_IDENTITY_MISMATCH" };
  }
  if (manifest.id !== actual.id || quality.versionId !== actual.id || ![1, 2].includes(quality.schemaVersion) || await sha256(qualityBytes) !== await sha256(trackedQualityBytes)) return { ...result, aligned: false, reason: "PUBLIC_QUALITY_MISMATCH" };
  if (!["READY", "DEGRADED_OPTIONAL", "DEGRADED_CORE", "CATALOG_ONLY"].includes(quality.qualityState)) fail("QUALITY_STATE_INVALID");
  const sourceAt = timestamp(actual.sourceTimestampUtc);
  if (sourceAt > now + 2 * MINUTE) fail("SOURCE_TIME_IN_FUTURE");
  return { ...result, aligned: true, reason: "PUBLICATION_VERIFIED", sourceAt: iso(sourceAt), qualityState: quality.qualityState };
}
export function sourceProof(run, jobs, versionId, now) {
  if (run?.path !== REFRESH || run.head_branch !== "main" || !["schedule", "workflow_dispatch", "push"].includes(run.event) || run.status !== "completed" || run.conclusion !== "success") return null;
  for (const job of jobs) {
    if (job.conclusion !== "success") continue;
    for (const step of job.steps || []) {
      if (step.name !== `Source verified: ${versionId}` || step.conclusion !== "success") continue;
      const at = timestamp(step.completed_at);
      if (at < timestamp(run.created_at) || at > timestamp(run.updated_at) || at > now + 2 * MINUTE) return null;
      return { runId: String(run.id), versionId, checkedAt: iso(at) };
    }
  }
  return null;
}
export function decide({ runs, publication, state, now }) {
  const relevant = runs.filter(r => r.head_branch === "main" && PUBLICATION.has(r.path));
  const active = relevant.filter(r => r.status !== "completed");
  if (active.length) {
    const oldest = Math.min(...active.map(r => timestamp(r.created_at)));
    return { action: "WAIT", reason: now - oldest > 70 * MINUTE ? "RUN_STALLED" : "RUN_IN_PROGRESS" };
  }
  const wanted = publication.aligned ? "REFRESH" : "REDEPLOY";
  const refreshes = relevant.filter(r => r.path === REFRESH).sort((a, b) => timestamp(b.created_at) - timestamp(a.created_at));
  // Use start cadence, not completion time: a 10-minute job must not turn a
  // 15-minute schedule into a 25-minute schedule. This is NOT freshness evidence.
  if (wanted === "REFRESH" && refreshes[0] && now - timestamp(refreshes[0].created_at) < 15 * MINUTE) return { action: "WAIT", reason: "REFRESH_INTERVAL" };
  const target = wanted === "REFRESH" ? REFRESH : REDEPLOY;
  const attempts = relevant.filter(r => r.path === target).sort((a, b) => timestamp(b.created_at) - timestamp(a.created_at));
  let failures = 0;
  for (const run of attempts) { if (run.conclusion === "success") break; failures++; }
  const cooldown = failures ? Math.min(120, 15 * 2 ** Math.min(failures - 1, 3)) * MINUTE : 15 * MINUTE;
  const lastAttempt = Math.max(attempts[0] ? timestamp(attempts[0].created_at) : 0, state.lastDispatchAt ? timestamp(state.lastDispatchAt) : 0);
  if (now - lastAttempt < cooldown) return { action: "WAIT", reason: failures ? "FAILURE_BACKOFF" : "DISPATCH_COOLDOWN" };
  return { action: wanted, reason: wanted === "REFRESH" ? "REFRESH_DUE" : publication.reason };
}
export function publicHealth(state, now = Date.now()) {
  const last = state.checkedAt ? timestamp(state.checkedAt) : 0;
  const age = state.sourceProof?.checkedAt && state.sourceProof.versionId === state.publication?.versionId
    ? now - timestamp(state.sourceProof.checkedAt) : null;
  const verificationAge = age ?? (state.publication?.sourceAt ? now - timestamp(state.publication.sourceAt) : null);
  let status = !last || now - last > 12 * MINUTE ? "MONITOR_STALE" : state.status || "UNKNOWN";
  if (status === "CHECKED" && (verificationAge === null || verificationAge > 30 * MINUTE)) status = "DATA_CHECK_OVERDUE";
  return {
    schemaVersion: 1,
    status,
    checkedAt: state.checkedAt || null,
    publicVersionId: state.publication?.versionId || null,
    publicSourceUpdatedAt: state.publication?.sourceAt || null,
    sourceVerifiedAt: state.sourceProof?.versionId === state.publication?.versionId ? state.sourceProof?.checkedAt || null : null,
    sourceVerificationAgeMinutes: age === null ? null : Math.round(age / MINUTE),
    publicationAligned: state.publication?.aligned === true,
    lastAction: state.action || "NONE", reason: state.reason || "NOT_STARTED",
    failureStage: state.failureStage || null,
    failureKind: state.failureKind || null,
    lastDispatchAt: state.lastDispatchAt || null,
    // Bounded evidence, no tokens, account names, repository URLs or log bodies.
    observationStartedAt: state.observationStartedAt || null,
    observationCount: state.observationCount || 0,
    maximumCheckGapMinutes: state.maximumCheckGapMinutes || 0,
    maximumVerifiedAgeMinutes: state.maximumVerifiedAgeMinutes || 0,
    failedChecks: state.failedChecks || 0,
    recent: state.recent || [],
  };
}
// Workers native fetch requires its global receiver; Node-only injected mocks do
// not reveal an unbound-fetch TypeError. Preserve the receiver in production.
export async function runCheck(env, { fetcher = (input, init) => globalThis.fetch(input, init), now = Date.now() } = {}) {
  if (!env.STATE?.get || !env.STATE?.put) fail("STATE_NOT_CONNECTED");
  const state = await env.STATE.get("watchdog-v1", "json") || {};
  let decision = { action: "NONE", reason: "DISABLED" };
  let status = "DISABLED";
  let stage = "CONFIGURATION";
  state.failureStage = null;
  state.failureKind = null;
  if (env.ENABLED === "true") {
    try {
      const config = configuration(env);
      stage = "AUTHENTICATION";
      const token = await githubToken(env, fetcher, now, value => { stage = value; });
      const headers = githubHeaders(token);
      stage = "RUN_QUEUE";
      const response = await json(fetcher, `${config.api}/actions/runs?branch=main&per_page=50`, { headers });
      if (!Array.isArray(response.workflow_runs)) fail("RUNS_INVALID");
      const runs = response.workflow_runs;
      // If GitHub's queue cannot be inspected, never issue speculative writes.
      for (const r of runs) {
        if (!r.path || !r.status || !Number.isSafeInteger(r.id)) fail("RUNS_INVALID");
        timestamp(r.created_at);
      }
      stage = "TRACKED_HEAD";
      const head = await json(fetcher, `${config.api}/git/ref/heads/main`, { headers }, 16_384);
      // Pin control-file comparisons to one commit; main can advance while the
      // independent check is reading Pages. Never compare two different commits.
      stage = "PUBLICATION";
      const publication = await readPublication({ ...config, commitSha: head.object?.sha }, fetcher, now);
      state.publication = publication;
      const successful = runs.find(r => r.path === REFRESH && r.head_branch === "main" && r.status === "completed" && r.conclusion === "success");
      if (successful && String(successful.id) !== state.sourceProof?.runId) {
        stage = "SOURCE_PROOF";
        const jobs = await json(fetcher, `${config.api}/actions/runs/${successful.id}/jobs?per_page=100`, { headers });
        if (!Array.isArray(jobs.jobs)) fail("JOBS_INVALID");
        const proof = sourceProof(successful, jobs.jobs, publication.versionId, now);
        if (proof) state.sourceProof = proof;
      }
      stage = "DECISION";
      decision = decide({ runs, publication, state, now });
      status = !publication.aligned ? "PUBLICATION_DELAYED" : "CHECKED";
      if (decision.reason === "RUN_STALLED") status = "NEEDS_ATTENTION";
      if (decision.action === "REFRESH" || decision.action === "REDEPLOY") {
        // Reserve before the request. An ambiguous timeout must not cause a new
        // dispatch every five minutes. GitHub concurrency remains the final lock.
        state.lastDispatchAt = iso(now);
        stage = "DISPATCH_RESERVATION";
        await env.STATE.put("watchdog-v1", JSON.stringify(state));
        stage = "DISPATCH";
        const workflow = decision.action === "REFRESH" ? "refresh-tft-data.yml" : "deploy-pages.yml";
        const dispatch = await fetcher(`${config.api}/actions/workflows/${workflow}/dispatches`, {
          method: "POST", redirect: "manual", signal: AbortSignal.timeout(15_000),
          headers: { ...headers, "Content-Type": "application/json" }, body: JSON.stringify({ ref: "main" }),
        });
        if (![200, 204].includes(dispatch.status)) fail(`DISPATCH_HTTP_${dispatch.status}`);
        if (dispatch.body) await dispatch.body.cancel();
      }
    } catch (error) {
      if (error instanceof CheckError && /(?:^|_)401$/.test(error.code)) tokenCache = undefined;
      status = "CHECK_FAILED";
      state.failureStage = stage;
      // Never expose error.message, stack, URLs, credential text or arbitrary names.
      state.failureKind = ["TypeError", "SyntaxError", "DataError", "InvalidCharacterError", "OperationError", "NotSupportedError", "AbortError", "TimeoutError"].includes(error?.name) ? error.name : "OTHER";
      decision = { action: "NONE", reason: error instanceof CheckError ? error.code : "CHECK_UNAVAILABLE" };
      state.failedChecks = (state.failedChecks || 0) + 1;
    }
  }
  const previousAt = state.checkedAt ? timestamp(state.checkedAt) : now;
  state.maximumCheckGapMinutes = Math.max(state.maximumCheckGapMinutes || 0, Math.round((now - previousAt) / MINUTE));
  state.observationStartedAt ||= iso(now);
  state.observationCount = (state.observationCount || 0) + 1;
  Object.assign(state, { checkedAt: iso(now), status, action: decision.action, reason: decision.reason });
  const health = publicHealth(state, now);
  if (health.sourceVerificationAgeMinutes !== null) state.maximumVerifiedAgeMinutes = Math.max(state.maximumVerifiedAgeMinutes || 0, health.sourceVerificationAgeMinutes);
  state.recent = [...(state.recent || []).slice(-19), { at: iso(now), status, action: decision.action, reason: decision.reason }];
  await env.STATE.put("watchdog-v1", JSON.stringify(state));
  return publicHealth(state, now);
}

export default {
  async scheduled(_event, env, ctx) {
    ctx.waitUntil(runCheck(env).then(result => {
      console.log(JSON.stringify({ status: result.status, action: result.lastAction, reason: result.reason }));
    }));
  },
  async fetch(request, env) {
    // There is deliberately no public refresh/dispatch endpoint.
    if (request.method !== "GET" || new URL(request.url).pathname !== "/health") return new Response("Not found", { status: 404 });
    try {
      const state = await env.STATE.get("watchdog-v1", "json") || {};
      const result = publicHealth(state);
      return Response.json(result, { status: ["CHECKED"].includes(result.status) ? 200 : 503, headers: { "Cache-Control": "no-store" } });
    } catch {
      return Response.json({ status: "MONITOR_UNAVAILABLE" }, { status: 503, headers: { "Cache-Control": "no-store" } });
    }
  },
};
