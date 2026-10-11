// The CPU-intensive inspector runs in GitHub, not in a Free Worker Cron.
import { appendFile } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { runCheck } from "./worker.mjs";

export async function checkFromGitHub(env, options = {}) {
  if (!env.GITHUB_TOKEN || !env.GITHUB_REPOSITORY) throw new Error("GITHUB_CHECK_CONFIGURATION_REQUIRED");
  const records = new Map();
  return runCheck({ ENABLED: "true", GITHUB_TOKEN: env.GITHUB_TOKEN, GITHUB_REPOSITORY: env.GITHUB_REPOSITORY,
    DATA_INDEX_URL: env.DATA_INDEX_URL, RUN_HISTORY_LIMIT: "50", CLOCK_JITTER_TOLERANCE: "true",
    STATE: { get: async key => records.get(key) || null, put: async (key, value) => { records.set(key, JSON.parse(value)); } },
  }, options);
}
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  if (process.env.GITHUB_REF !== "refs/heads/main" || process.env.GITHUB_EVENT_NAME !== "workflow_dispatch") throw new Error("MAIN_DISPATCH_REQUIRED");
  const result = await checkFromGitHub(process.env);
  // No credential, URL or arbitrary exception body is emitted.
  console.log(JSON.stringify({ status: result.status, action: result.lastAction, reason: result.reason, versionId: result.publicVersionId, sourceVerifiedAt: result.sourceVerifiedAt }));
  if (process.env.GITHUB_STEP_SUMMARY) await appendFile(process.env.GITHUB_STEP_SUMMARY, `Independent data check: ${result.status}; ${result.lastAction}; ${result.reason}\n`);
  if (["CHECK_FAILED", "NEEDS_ATTENTION", "DISABLED"].includes(result.status)) process.exitCode = 1;
}
