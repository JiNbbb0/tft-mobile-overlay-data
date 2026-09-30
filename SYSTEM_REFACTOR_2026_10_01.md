# Update/publication contract refactor — 2026-10-01

Baseline: main `1753848`. The separate Canonical v2 draft PR #427 remains untouched.
No app sources, APKs, signing keys, or credentials are included in this repository.

## Observed production failure

Refresh run `36779354546` failed at `validate-static-meta.ps1` for
`425049/Lv4/DA_18_Camille`. The production generator selected tier 4, while its
validator allowed only 0/2/3. The public MetaTFT response was independently read:
`unit_stats`: `tier=4`, `count=14`, `pcnt=1`; `tft_set=TFTSet18`, `cluster_id=425`.
Observed response SHA-256: `307595924716e34f581ea98a7bd080802ef6e387cd1248b3abf9db6ea9a5d2b3`.

`board-star-policy.ps1` now owns the shared generation/validation policy.
Four-star data is preserved; existing statistical selection thresholds stay intact.
Unsupported future tiers and invalid rates remain fail-closed. No set-specific
champion exception, guessed board, or alternate rank population is introduced.

## Publication responsibility boundaries

- `published-data-contract.ps1`: index-selected immutable bundle, manifest SHA,
  catalog/snapshot payload SHA/bytes and complete Set/Patch/revision identity.
- `write-data-quality-status.ps1`: status comes from those verified bundle bytes,
  not mutable acquisition workspaces; optional caller inputs must hash-match.
  UTC ISO 8601 timestamps and atomic status replacement.
  Generated status must pass the published quality JSON schema before replacement;
  optional catalog/snapshot hashes are defined in that backward-compatible schema.
- `verify-publication.ps1`: one bounded remote verification entrypoint for refresh,
  manual redeploy, rollback and watchdog repair. A bad/mismatching quality status
  is a failure, not merely an attention message followed by a misleading PASS.
  The quality URL retains the index verification cache-buster, avoiding stale
  edge-cached quality during an otherwise successful deployment.
- Rollback commits index, health AND matching quality. User input is passed as an
  environment value, not interpolated into executable PowerShell.
- Any workflow change now triggers code-change CI; deterministic fixtures remain
  outside the 15-minute live refresh. Actual candidate and public gates remain.

## Added regressions

Source-backed four-star fixture; old thresholds; unsupported/non-finite values;
immutable bundle-owned quality; timestamp normalization; stale workspace rejection;
mixed patch/revision; payload corruption; traversal; failure preserves old quality;
four workflow entrypoints; bad quality blocks remote PASS; collecting/optional
data stays explicitly publishable. The complete existing retention, new-set,
rank separation, reconciliation and LKG regressions are retained.

## Remaining boundaries

GitHub schedules can still be delayed or dropped. Two jobs on that scheduler are
not an independent clock or a strict 15–30-minute SLA. Unknown upstream contracts
still require a targeted adapter update after safe rejection. A public data-side
verification is not Android device E2E. The Android repository contains the app
refactor and matching release/verification report; it is not published here.

See the PR checks and follow-up evidence section for executed results.
