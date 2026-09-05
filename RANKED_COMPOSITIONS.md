# Ranked composition publication

This extends the existing schema-5 snapshot and production refresh path. It does not replace the catalog, bundle, blob, immutable version, hash, or LKG contracts.

## Contract

- `config/composition-ranks.json` defines rank IDs, labels and exact upstream populations. Default remains Diamond+ for old APKs.
- `compositionRanks` schema 1 inside `tft_static_snapshot.json` binds setId, patch, revision, defaultRankId, options and child datasets. The root is the default dataset; every other option has exactly one child snapshot.
- All seven rank snapshots use the same set/cluster. `permit_filter_adjustment=false` remains mandatory. No all-rank fallback or estimated statistics.
- Composition ranking uses explicit rank statistics. Boards, builds, details and catalog statistics preserve their existing upstream semantics; catalog statistics remain Diamond+.
- A new generator batch caches successful responses by exact URL in memory. No cache crosses batches; rank URLs remain distinct. Shared catalog, cluster, lookup, build and detail responses are fetched once per batch. New rank populations add their necessary stats fetches and any newly encountered composition details.
- All child validation finishes before the source file is replaced. Publication still uses the existing staging/index pipeline. A bad child blocks the candidate and preserves last-known-good. Positive evidence of an empty rank population yields empty/collecting, not another population.
- All rank content affects the material fingerprint, including small numeric changes. Observation clocks alone do not. Per-rank changes are included in CHANGE_SUMMARY.
- The extension remains under existing 30 MiB/file, 250 MiB/site and manifest limits. No new image copies/blobs are required merely for another rank.

## Tests / operation

```powershell
./tools/test-composition-ranks.ps1
./tools/test-source-contract.ps1
./tools/test-content-fingerprint.ps1
./tools/refresh-ranked-compositions.ps1 -OutputPath build/rank-live/tft_static_snapshot.json
./tools/validate-static-meta.ps1 -SnapshotPath build/rank-live/tft_static_snapshot.json
./tools/test-ranked-publication.ps1
./tools/test-ranked-production-refresh.ps1
```

The integration test writes an isolated local site beneath `build/`; it never deploys GitHub Pages. Synthetic regression fixtures must never be promoted to production.

PowerShell 7 with `Test-Json` is required, matching the workflow's `pwsh` runtime. The workflow remains at UTC minutes 7,22,37,52 with existing concurrency/timeouts. Config changes are now included in push path filters.

`validate-ranked-compositions.yml` is a read-only PR/manual pre-publication gate: syntax, rank/source/fingerprint regression, live seven-rank generation, isolated publisher/site verification, and invalid-child last-known-good preservation. It never changes `source/current`, tracked `site`, or public Pages. The existing refresh workflow performs publication only after its production gates pass.

The production dry-run copies only tools, schemas, rank config, source and site into a fresh build workspace, then runs the real refresh pipeline. This acquires current Riot/CommunityDragon/MetaTFT identity evidence rather than relying on a developer machine's prior observation files. No validation condition is relaxed for CI.

2026-09-05: fresh production dry-run passed in [validation run 33967914831](https://github.com/JiNbbb0/tft-mobile-overlay-data/actions/runs/33967914831). The runtime bootstrap now recognizes both the legacy and ranked generator entrypoints without changing the catalog-first/LKG conditions; the isolated CI includes this bootstrap as well.

Production generation, Pages deployment and public verification passed in [refresh run 33968410853](https://github.com/JiNbbb0/tft-mobile-overlay-data/actions/runs/33968410853). Published version `tftset18-18.1-r422-mc213c493d3`: seven ranks x 18 compositions, 54 unique requests, 8,110,289-byte snapshot, SHA-256 `754056afb3c2308b9f2feb16a193c78a1552678fd13494ba43e7f14adbce1f50`. Independent public retrieval verified all seven rank scopes and differing contents. These are capture-time results, not fixed rankings.

Subsequent focused Android device checks verified all seven rank selections against this public bundle, restart persistence, offline last-known-good retention and network recovery. A legacy single-rank rollback picker defect was found and fixed in app v1.5.1; that build rechecked all seven ranks and legacy unavailable-rank -> supported-rank -> latest navigation. This is not a claim of complete Android E2E, long-session overlay stability, future live-set migration or broad device coverage. Android source, APKs and local device artifacts are not published in this data repository.
