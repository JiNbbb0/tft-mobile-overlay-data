# Data delivery validation — 2026-08-09

## Local result

- `tools/validate-static-meta.ps1`: PASS (`TFTSet17`, 18 compositions, 1,007 item-stat records)
- `tools/validate-offline-catalog.ps1`: PASS (63 champions, 36 traits, 663 items, 273 augments)
- `tools/validate-site.ps1`: PASS (one version, 901 manifest files, latest `tftset17-17.8-r409`)
- `tools/test-new-set-readiness.ps1`: PASS. It creates a synthetic `TFTSet18` catalog-only update, validates the staged site, rolls latest back to Set 17, and validates again. It does not modify `site/`.
- `tools/get-meta-fingerprint.ps1`: PASS; the current snapshot's semantic fingerprint is deterministic.

## Delivery behavior covered

- A `META_UPDATE` is issued only when the normalized tactical content changes. Fetch timestamps, sample-count drift, and URL noise are excluded from its SHA-256 fingerprint.
- Version identity, manifest, and index retain `readiness`, `sourceTimestampUtc`, and `metaFingerprint`.
- A catalog-only new set may be published as `CATALOG_READY` / `META_COLLECTING`; it deliberately contains no old-set composition rows. A stable meta remains `META_STABLE`.
- The 100-version limit remains fail-safe: this change does not delete old history automatically.

## Title provenance check

The live MetaTFT public `latest_cluster_info` endpoint returned published `TFTSet17`, cluster `409` on 2026-08-09. Its composition-name entries are source keys such as `TFT17_Augment_JaxCarry`, not Japanese display titles. The pipeline therefore records that original key in `titleKey`, resolves every key through CommunityDragon Japanese localization, writes the final result to required `displayNameJa`, and rejects missing mappings. It does not scrape ranking HTML.

The pre-existing Set 17 historical artifact is schema 4 and retains its historical `name` values. New pipeline output is schema 5 and requires `displayNameJa`, `titleKey`, and `titleSource`; the Android reader treats schema 4 only as an explicit historical compatibility case.

## Publication status

All checks above ran locally. No Git push, GitHub Pages deployment, or production data refresh was performed.
