// Independent clock only. Source acquisition, validation, atomic publication,
// rollback and seven-rank identity remain owned by the existing GitHub pipeline.
const MINUTE = 60_000;
const REFRESH = ".github/workflows/refresh-tft-data.yml";
const REDEPLOY = ".github/workflows/deploy-pages.yml";
const PUBLICATION = new Set([REFRESH, REDEPLOY, ".github/workflows/rollback-latest.yml", ".github/workflows/automation-watchdog.yml"]);
const HASH = /^[0-9a-f]{64}$/;
const ID = /^[a-z0-9][a-z0-9._-]{0,159}$/;
const encoder = new TextEncoder();
const STATE_KEY = "watchdog-v1";
const RESERVATION_KEY = "dispatch-reservation-v1";
const TOKEN_KEY = "sealed-installation-token-v1";
const TOKEN_REJECTION_KEY = "token-rejection-v1";
const CLOCK_KEY = "clock-v2";
const CLOCK_RESERVATION_KEY = "clock-reservation-v2";
const ACTIVE_STATUSES = ["queued", "in_progress", "waiting", "requested", "pending"];
let tokenCache;

class CheckError extends Error {
  constructor(code) { super(code); this.code = code; }
}
const fail = code => { throw new CheckError(code); };
const iso = value => new Date(value).toISOString();
async function readState(env, key) {
  try { return await env.STATE.get(key, "json"); }
  catch { fail("STATE_READ_FAILED"); }
}
async function writeState(env, key, value) {
  try { await env.STATE.put(key, JSON.stringify(value)); }
  catch { fail("STATE_WRITE_FAILED"); }
}
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
// GitHub run lists are large. Keep the size gate, but let the runtime decode
// and parse JSON without JS chunk concatenation + UTF-8 decoding copies.
async function json(fetcher, url, options = {}, maximum = 1_048_576) {
  const response = await fetcher(url, { ...options, redirect: "manual", signal: AbortSignal.timeout(15_000) });
  if (!response.ok) fail(`HTTP_${response.status}`);
  if (Number(response.headers.get("content-length")) > maximum) fail("RESPONSE_TOO_LARGE");
  if (!response.body) fail("EMPTY_RESPONSE");
  let size = 0;
  const limited = response.body.pipeThrough(new TransformStream({
    transform(chunk, controller) {
      size += chunk.byteLength;
      if (size > maximum) fail("RESPONSE_TOO_LARGE");
      controller.enqueue(chunk);
    },
  }));
  return new Response(limited).json();
}
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
async function tokenSealingKey(env, identity) {
  if (typeof env.GITHUB_APP_PRIVATE_KEY !== "string" || env.GITHUB_APP_PRIVATE_KEY.length > 8192) fail("APP_KEY_INVALID");
  // The high-entropy private key remains only in the encrypted runtime secret.
  // KV gets authenticated ciphertext, never a plaintext credential or key.
  const material = await crypto.subtle.digest("SHA-256", encoder.encode(`TFT-WATCHDOG-TOKEN-V1\n${identity}\n${env.GITHUB_APP_PRIVATE_KEY}`));
  return crypto.subtle.importKey("raw", material, "AES-GCM", false, ["encrypt", "decrypt"]);
}
const unbase64 = value => Uint8Array.from(atob(value), c => c.charCodeAt(0));
const base64 = value => btoa(String.fromCharCode(...new Uint8Array(value)));
async function githubToken(env, fetcher, now, setStage) {
  // A scoped token is supported for bootstrap only. Production should use an
  // installation token renewed automatically, not a PAT with a renewal deadline.
  if (env.GITHUB_TOKEN) return env.GITHUB_TOKEN;
  if (!/^\d+$/.test(env.GITHUB_APP_ID || "") || !/^\d+$/.test(env.GITHUB_INSTALLATION_ID || "")) fail("GITHUB_NOT_CONNECTED");
  const identity = `${env.GITHUB_APP_ID}:${env.GITHUB_INSTALLATION_ID}:${env.GITHUB_REPOSITORY}`;
  const rejected = await readState(env, TOKEN_REJECTION_KEY);
  const rejectedThrough = rejected?.identity === identity ? timestamp(rejected.at) : 0;
  if (rejectedThrough > now + 2 * MINUTE) fail("AUTH_REJECTION_TIME_INVALID");
  if (tokenCache?.identity === identity && tokenCache.issuedAt > rejectedThrough && tokenCache.expires > now + 5 * MINUTE) return tokenCache.token;
  const sealed = await readState(env, TOKEN_KEY);
  const sealingKey = await tokenSealingKey(env, identity);
  if (sealed?.version === 1 && typeof sealed.iv === "string" && sealed.iv.length === 16 && typeof sealed.data === "string" && sealed.data.length <= 8192) {
    try {
      const decrypted = await crypto.subtle.decrypt({ name: "AES-GCM", iv: unbase64(sealed.iv), additionalData: encoder.encode(identity) }, sealingKey, unbase64(sealed.data));
      const saved = JSON.parse(decode(new Uint8Array(decrypted)));
      if (saved.identity === identity && typeof saved.token === "string" && saved.token && saved.token.length <= 2048 && Number.isSafeInteger(saved.issuedAt) && saved.issuedAt > rejectedThrough && saved.issuedAt <= now + 2 * MINUTE && Number.isSafeInteger(saved.expires) && saved.expires > now + 5 * MINUTE && saved.expires <= now + 65 * MINUTE) {
        setStage("TOKEN_CACHE_HIT");
        tokenCache = saved;
        return saved.token;
      }
    } catch { /* Expired, rotated or tampered cache: renew from GitHub, never trust it. */ }
  }
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
  if (typeof result.token !== "string" || !result.token || result.token.length > 2048 || timestamp(result.expires_at) <= now || timestamp(result.expires_at) > now + 65 * MINUTE) fail("APP_TOKEN_INVALID");
  tokenCache = { identity, token: result.token, expires: timestamp(result.expires_at), issuedAt: now };
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const encrypted = await crypto.subtle.encrypt({ name: "AES-GCM", iv, additionalData: encoder.encode(identity) }, sealingKey, encoder.encode(JSON.stringify(tokenCache)));
  // One extra write per token renewal, not per Cron. KV TTL is bounded and
  // stale ciphertext cannot extend the authenticated token's actual expiry.
  try { await env.STATE.put(TOKEN_KEY, JSON.stringify({ version: 1, iv: base64(iv), data: base64(encrypted) }), { expirationTtl: Math.min(3600, Math.max(60, Math.floor((tokenCache.expires - now) / 1000))) }); }
  catch { tokenCache = undefined; fail("STATE_WRITE_FAILED"); }
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
export function decide({ runs, publication, state, now, minimumInterval = 15 * MINUTE }) {
  minimumInterval = Number.isFinite(minimumInterval) ? Math.max(14 * MINUTE, Math.min(15 * MINUTE, minimumInterval)) : 15 * MINUTE;
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
  if (wanted === "REFRESH" && refreshes[0] && now - timestamp(refreshes[0].created_at) < minimumInterval) return { action: "WAIT", reason: "REFRESH_INTERVAL" };
  const target = wanted === "REFRESH" ? REFRESH : REDEPLOY;
  const attempts = relevant.filter(r => r.path === target).sort((a, b) => timestamp(b.created_at) - timestamp(a.created_at));
  let failures = 0;
  for (const run of attempts) { if (run.conclusion === "success") break; failures++; }
  const cooldown = failures ? Math.min(120, 15 * 2 ** Math.min(failures - 1, 3)) * MINUTE : minimumInterval;
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
export function publicClockHealth(state, now = Date.now()) {
  const checked = state.checkedAt ? timestamp(state.checkedAt) : 0;
  const accepted = state.lastAcceptedAt ? timestamp(state.lastAcceptedAt) : 0;
  let status = !checked || now - checked > 12 * MINUTE ? "MONITOR_STALE" : state.status || "UNKNOWN";
  if (checked > now + 2 * MINUTE || accepted > now + 2 * MINUTE) status = "CLOCK_TIME_INVALID";
  if (status === "CLOCK_ALIVE" && (!accepted || now - accepted > 30 * MINUTE)) status = "CLOCK_TRIGGER_OVERDUE";
  // Clock evidence is NOT source-freshness or publication-validation evidence.
  return { schemaVersion: 2, mode: "CLOCK_ONLY", dataVerification: "GITHUB_WORKFLOW", status,
    checkedAt: state.checkedAt || null, lastAcceptedAt: state.lastAcceptedAt || null,
    lastDispatchAt: state.lastDispatchAt || null, lastAction: state.action || "NONE",
    reason: state.reason || "NOT_STARTED", observationCount: state.observationCount || 0,
    failedChecks: state.failedChecks || 0, recent: state.recent || [] };
}
export async function runClockTick(env, { fetcher = (input, init) => globalThis.fetch(input, init), now = Date.now(), onStage = (_stage) => {} } = {}) {
  if (!env.STATE?.get || !env.STATE?.put) fail("STATE_NOT_CONNECTED");
  const state = await readState(env, CLOCK_KEY) || {};
  const reserved = await readState(env, CLOCK_RESERVATION_KEY);
  const slot = Math.floor(now / (15 * MINUTE));
  if (reserved?.at) {
    const at = timestamp(reserved.at);
    if (at > now + 2 * MINUTE) fail("RESERVATION_TIME_IN_FUTURE");
    if (!state.lastDispatchAt || at > timestamp(state.lastDispatchAt)) state.lastDispatchAt = iso(at);
    if (Number.isSafeInteger(reserved.slot)) state.lastSlot = Math.max(state.lastSlot ?? -1, reserved.slot);
  }
  state.action = "NONE";
  if (env.ENABLED !== "true") {
    state.status = "DISABLED"; state.reason = "DISABLED";
  } else {
    const failures = state.dispatchFailures || 0;
    const cooldown = (failures ? Math.min(120, 15 * 2 ** Math.min(failures - 1, 3)) : 15) * MINUTE;
    const last = Math.max(state.lastDispatchAt ? timestamp(state.lastDispatchAt) : 0, state.lastFailureAt ? timestamp(state.lastFailureAt) : 0);
    if (failures ? now - last < cooldown : state.lastSlot === slot) {
      state.action = "WAIT";
      state.reason = failures ? "CLOCK_FAILURE_BACKOFF" : "CLOCK_TRIGGER_INTERVAL";
      state.status = failures ? "CHECK_FAILED" : state.lastAcceptedAt ? "CLOCK_ALIVE" : "CLOCK_TRIGGER_UNCONFIRMED";
    } else {
      try {
        const config = configuration(env);
        const token = await githubToken(env, fetcher, now, onStage);
        state.lastDispatchAt = iso(now);
        state.lastSlot = slot;
        await writeState(env, CLOCK_RESERVATION_KEY, { at: state.lastDispatchAt, slot });
        // Only enqueue the bounded GitHub inspector. It performs the full queue,
        // commit-pinned SHA/source checks BEFORE any refresh/redeploy dispatch.
        const response = await fetcher(`${config.api}/actions/workflows/independent-refresh-check.yml/dispatches`, {
          method: "POST", redirect: "manual", signal: AbortSignal.timeout(15_000),
          headers: { ...githubHeaders(token), "Content-Type": "application/json" }, body: JSON.stringify({ ref: "main" }),
        });
        if (![200, 204].includes(response.status)) fail(`DISPATCH_HTTP_${response.status}`);
        if (response.body) await response.body.cancel();
        Object.assign(state, { status: "CLOCK_ALIVE", action: "TRIGGER_CHECK", reason: "GITHUB_CHECK_ACCEPTED", lastAcceptedAt: iso(now), dispatchFailures: 0, lastFailureAt: null });
      } catch (error) {
        if (error instanceof CheckError && /(?:^|_)401$/.test(error.code)) {
          tokenCache = undefined;
          try { await env.STATE.put(TOKEN_REJECTION_KEY, JSON.stringify({ identity: `${env.GITHUB_APP_ID}:${env.GITHUB_INSTALLATION_ID}:${env.GITHUB_REPOSITORY}`, at: iso(now) }), { expirationTtl: 3600 }); }
          catch { error = new CheckError("STATE_WRITE_FAILED"); }
        }
        Object.assign(state, { status: "CHECK_FAILED", action: "NONE", reason: error instanceof CheckError ? error.code : "CHECK_UNAVAILABLE", lastFailureAt: iso(now), dispatchFailures: failures + 1, failedChecks: (state.failedChecks || 0) + 1 });
      }
    }
  }
  state.checkedAt = iso(now);
  state.observationCount = (state.observationCount || 0) + 1;
  state.recent = [...(state.recent || []).slice(-19), { at: state.checkedAt, status: state.status, action: state.action, reason: state.reason }];
  await writeState(env, CLOCK_KEY, state);
  return publicClockHealth(state, now);
}
// Workers native fetch requires its global receiver; Node-only injected mocks do
// not reveal an unbound-fetch TypeError. Preserve the receiver in production.
export async function runCheck(env, { fetcher = (input, init) => globalThis.fetch(input, init), now = Date.now(), onStage = (_stage) => {} } = {}) {
  if (env.MODE === "CLOCK_ONLY") return runClockTick(env, { fetcher, now, onStage });
  if (!env.STATE?.get || !env.STATE?.put) fail("STATE_NOT_CONNECTED");
  const state = await readState(env, STATE_KEY) || {};
  // KV is limited to one write/second/key. Keep the durable pre-dispatch
  // reservation separate from the final health record, with no artificial sleep.
  // A failed final health write must not erase the ambiguous-POST cooldown.
  const reservation = await readState(env, RESERVATION_KEY);
  if (reservation?.lastDispatchAt) {
    const reservedAt = timestamp(reservation.lastDispatchAt);
    if (reservedAt > now + 2 * MINUTE) fail("RESERVATION_TIME_IN_FUTURE");
    if (!state.lastDispatchAt || reservedAt > timestamp(state.lastDispatchAt)) state.lastDispatchAt = iso(reservedAt);
  }
  let decision = { action: "NONE", reason: "DISABLED" };
  let status = "DISABLED";
  let stage = "CONFIGURATION";
  state.failureStage = null;
  state.failureKind = null;
  if (env.ENABLED === "true") {
    try {
      const config = configuration(env);
      stage = "AUTHENTICATION"; onStage(stage);
      const token = await githubToken(env, fetcher, now, value => { stage = value; onStage(value); });
      const headers = githubHeaders(token);
      stage = "RUN_QUEUE"; onStage(stage);
      const history = [];
      const historyLimit = env.RUN_HISTORY_LIMIT === "50" ? 50 : 5;
      const pageSize = Math.min(10, historyLimit);
      for (let page = 1; history.length < historyLimit; page++) {
        const response = await json(fetcher, `${config.api}/actions/runs?branch=main&exclude_pull_requests=true&per_page=${pageSize}&page=${page}`, { headers });
        if (!Array.isArray(response.workflow_runs) || response.workflow_runs.length > pageSize) fail("RUNS_INVALID");
        history.push(...response.workflow_runs);
        if (response.workflow_runs.length < pageSize) break;
      }
      // Do not merely truncate the old list: an older queued publication could
      // be hidden behind recent completed CI. Query every active status too.
      // A crowded queue fails closed instead of guessing beyond the page bound.
      const activePages = await Promise.all(ACTIVE_STATUSES.map(status =>
        json(fetcher, `${config.api}/actions/runs?branch=main&exclude_pull_requests=true&status=${status}&per_page=10`, { headers })));
      for (const page of activePages) {
        if (!Array.isArray(page.workflow_runs) || !Number.isSafeInteger(page.total_count) || page.total_count < 0) fail("RUNS_INVALID");
        if (page.total_count > 10 || page.workflow_runs.length !== page.total_count) fail("ACTIVE_QUEUE_TOO_LARGE");
      }
      const runs = [...new Map([...history, ...activePages.flatMap(page => page.workflow_runs)].map(run => [run.id, run])).values()];
      // If GitHub's queue cannot be inspected, never issue speculative writes.
      for (const r of runs) {
        if (!r.path || !r.status || !Number.isSafeInteger(r.id)) fail("RUNS_INVALID");
        timestamp(r.created_at);
      }
      stage = "TRACKED_HEAD"; onStage(stage);
      const head = await json(fetcher, `${config.api}/git/ref/heads/main`, { headers }, 16_384);
      // Pin control-file comparisons to one commit; main can advance while the
      // independent check is reading Pages. Never compare two different commits.
      stage = "PUBLICATION"; onStage(stage);
      const publication = await readPublication({ ...config, commitSha: head.object?.sha }, fetcher, now);
      state.publication = publication;
      const successful = runs.find(r => r.path === REFRESH && r.head_branch === "main" && r.status === "completed" && r.conclusion === "success");
      if (successful && String(successful.id) !== state.sourceProof?.runId) {
        stage = "SOURCE_PROOF"; onStage(stage);
        const jobs = await json(fetcher, `${config.api}/actions/runs/${successful.id}/jobs?per_page=100`, { headers });
        if (!Array.isArray(jobs.jobs)) fail("JOBS_INVALID");
        const proof = sourceProof(successful, jobs.jobs, publication.versionId, now);
        if (proof) state.sourceProof = proof;
      }
      stage = "DECISION"; onStage(stage);
      decision = decide({ runs, publication, state, now, minimumInterval: env.CLOCK_JITTER_TOLERANCE === "true" ? 14 * MINUTE : 15 * MINUTE });
      status = !publication.aligned ? "PUBLICATION_DELAYED" : "CHECKED";
      if (decision.reason === "RUN_STALLED") status = "NEEDS_ATTENTION";
      if (decision.action === "REFRESH" || decision.action === "REDEPLOY") {
        // Reserve before the request. An ambiguous timeout must not cause a new
        // dispatch every five minutes. GitHub concurrency remains the final lock.
        state.lastDispatchAt = iso(now);
        stage = "DISPATCH_RESERVATION";
        await writeState(env, RESERVATION_KEY, { lastDispatchAt: state.lastDispatchAt });
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
      if (error instanceof CheckError && /(?:^|_)401$/.test(error.code)) {
        tokenCache = undefined;
        // Never reuse a revoked ciphertext after a new isolate starts. Use a
        // separate key so first-issue + rejection cannot double-write TOKEN_KEY.
        try { await env.STATE.put(TOKEN_REJECTION_KEY, JSON.stringify({ identity: `${env.GITHUB_APP_ID}:${env.GITHUB_INSTALLATION_ID}:${env.GITHUB_REPOSITORY}`, at: iso(now) }), { expirationTtl: 3600 }); }
        catch { error = new CheckError("STATE_WRITE_FAILED"); stage = "AUTH_CACHE_INVALIDATION"; }
      }
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
  await writeState(env, STATE_KEY, state);
  return publicHealth(state, now);
}

export default {
  async scheduled(_event, env, ctx) {
    ctx.waitUntil(runCheck(env, { onStage: stage => console.log(JSON.stringify({ stage })) }).then(result => {
      console.log(JSON.stringify({ status: result.status, action: result.lastAction, reason: result.reason }));
    }).catch(error => {
      // Storage failure happens outside the API-check catch. Preserve an aged
      // health record (not false green), and log only an allowlisted code.
      const reason = error instanceof CheckError && ["STATE_READ_FAILED", "STATE_WRITE_FAILED", "STATE_NOT_CONNECTED", "RESERVATION_TIME_IN_FUTURE"].includes(error.code)
        ? error.code : "CHECK_UNAVAILABLE";
      console.error(JSON.stringify({ status: "CHECK_FAILED", action: "NONE", reason }));
    }));
  },
  async fetch(request, env) {
    // There is deliberately no public refresh/dispatch endpoint.
    if (request.method !== "GET" || new URL(request.url).pathname !== "/health") return new Response("Not found", { status: 404 });
    try {
      const clockOnly = env.MODE === "CLOCK_ONLY";
      const state = await readState(env, clockOnly ? CLOCK_KEY : STATE_KEY) || {};
      const result = clockOnly ? publicClockHealth(state) : publicHealth(state);
      return Response.json(result, { status: ["CHECKED", "CLOCK_ALIVE"].includes(result.status) ? 200 : 503, headers: { "Cache-Control": "no-store" } });
    } catch {
      return Response.json({ status: "MONITOR_UNAVAILABLE" }, { status: 503, headers: { "Cache-Control": "no-store" } });
    }
  },
};
