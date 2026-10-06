# Independent update clock

## Deployment state

Provisioning checkpoint (2026-10-07 JST): the Worker code is deployed to
`tft-data-watchdog.raizin20050317.workers.dev`, the `STATE` KV binding is attached,
and the five-minute Cron configuration has been saved. `ENABLED=false` is deliberate.
The private GitHub App `tft-data-watchdog-jinbbb0` (App ID `5214289`) is registered,
but key handoff and repository installation are still pending. No private key is
stored in this repository. The identifiers in `wrangler.jsonc` are not credentials.

Local fault-injection tests (38 cases) and the independent-watchdog CI have passed.
The complete pipeline regression is still being checked. Actual scheduled invocation,
scoped dispatch, real recovery and the 48-hour unattended check are **not yet verified**.
The service is **not enabled** and this checkpoint is not production acceptance.

## Why it exists

On 2026-10-06, the 15-minute refresh schedule had a 406-minute gap. The GitHub-hosted
watchdog had roughly seven-hour gaps too. It did recover when it ran (run
37491615920, source age 396.9 minutes), but could not rescue its own missing clock.
The independent service addresses that shared scheduler dependency, not every
possible GitHub, Pages, Cloudflare or upstream outage.

## Contract

- Cloudflare Cron checks every five minutes. No user's PC or Codex process is involved.
- It reads the GitHub run queue and one commit-pinned tracked publication, then
  compares the real HTTPS index, manifest SHA-256 and data-quality identity/content.
- When due, it dispatches the existing `refresh-tft-data.yml` on **main only**.
  Source fetching, all seven ranks, Set/Patch/Rank safety, schema/hash gates,
  retention, immutable bundles and last-known-good remain in the existing pipeline.
- For missing/mismatching public data it instead dispatches `deploy-pages.yml`.
  That workflow revalidates and atomically redeploys the tracked site; no fabricated
  candidate or unvalidated latest change is permitted.
- Existing active publication jobs suppress dispatch. Successful start cadence is
  15 minutes. Failures back off to 15/30/60/120 minutes; an ambiguous POST is reserved
  in state before sending. GitHub's publication concurrency lock remains authoritative.
- A run older than 70 minutes that is still active is reported, not cancelled blindly.
- A successful run is not source-freshness proof. Only a successful whole main run
  with the matching successful `Source verified: <versionId>` step qualifies.
  `SOURCE_NOT_READY`, failed publication and another version never advance that clock.
- `NO_CHANGE` can advance the verification time without making a data commit,
  immutable bundle, or fake source-update timestamp.
- Public `/health` is read-only, recalculates clock age and reveals no credentials,
  account names, repository URLs, or raw exception bodies. There is no public trigger.
- GitHub's existing watchdog can check this independent clock through repository
  variable `INDEPENDENT_WATCHDOG_URL`; an unhealthy result uses the existing single
  sanitized automation-health issue. No new email/Slack/Discord service is added.

## Free-only provisioning

Use **Workers Free**, one Cron and one KV namespace bound as `STATE`. Do not upgrade
or attach paid services. Config starts with `ENABLED=false`; change it only after
credentials, the health endpoint and a live read-only probe have been checked.

Nominal volume: 288 scheduled checks/day, at most 384 KV writes/day with normal
15-minute dispatch. State stores counters and the last 20 observations, not bundles
or unbounded logs. Free quota/CPU errors must be reported as failures, never trigger
an automatic paid upgrade. Actual Worker CPU usage still needs production verification.

Production authentication is a **private GitHub App**, installed only on this data
repository with `Actions: read/write`, `Contents: read`, and mandatory metadata read.
No Android repository access, Contents write, webhooks, user OAuth or account-wide
administration is required. The Worker requests short-lived installation tokens and
renews them automatically. Store these in Cloudflare configuration:

- `GITHUB_APP_ID` and `GITHUB_INSTALLATION_ID` (identifiers, not secrets)
- `GITHUB_APP_PRIVATE_KEY` (**encrypted Worker secret**, never Git or logs)
- `GITHUB_REPOSITORY`, `DATA_INDEX_URL`, `ENABLED` (non-secret variables)

`GITHUB_TOKEN` is supported only for scoped bootstrap diagnostics; it must be removed
for unattended production. Never embed a credential in an APK, config file, URL,
workflow argument or public repository. User authorization is required at installation
and before placing the private key in Cloudflare. Never put the key in chat.

## Verification and acceptance

Run `node --test external-watchdog/worker.test.mjs`. The tests inject missing GitHub
ticks, wrong/missing public data, SHA mismatch, API failure, rapid retries, an ambiguous
dispatch, no-change evidence, SOURCE_NOT_READY, branch/version changes and UTC offsets.
The accelerated 48-hour fixture proves **bounded storage only**, not live uptime.
Disabled provisioning ticks are not autonomous-operation evidence. Start the live
48-hour acceptance window only after enablement and the first authenticated check;
preserve its start time and evaluate subsequent events, not `observationStartedAt`
alone (that field includes pre-enablement observations).

`node external-watchdog/probe-publication.mjs` is a read-only public smoke check.
CI also runs existing publication/LKG/concurrency regressions. It never deploys this
Worker or grants credentials automatically from a pull request.

Live acceptance requires: observed Cloudflare Cron invocation; scoped dispatch;
existing generation/deploy/remote verification success; independent `/health` agrees;
missing-tick and publication-failure recovery; and at least 48 hours of real evidence.
The 15–30-minute source-to-app objective is not a hard uptime guarantee. GitHub runner
queues, deployment propagation and Android's polling/session pinning remain relevant.
Future unknown upstream formats must still fail closed rather than publish wrong data.

## Recovery

- Set `ENABLED=false` to stop external dispatch without changing public latest. GitHub's
  native schedules keep working. Keep the KV evidence for diagnosis.
- Fix an App permission/key failure in the private installation and Worker secret;
  do not widen access beyond the data repository or paste keys into an issue.
- For Pages mismatch, the existing validated redeploy is safe. Never force-push or
  skip validation. For a bad candidate, preserve LKG and repair the generating contract.
- A GitHub/platform-wide outage cannot be fixed by repeatedly dispatching; inspect
  the status code and wait/back off. A source outage cannot be replaced by invented stats.

Sources: [GitHub schedule limitations](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#schedule),
[Workers Free limits](https://developers.cloudflare.com/workers/platform/limits/),
[GitHub workflow dispatch permissions](https://docs.github.com/en/rest/actions/workflows#create-a-workflow-dispatch-event).
