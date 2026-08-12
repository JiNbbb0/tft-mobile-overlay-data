# 17.9 live-meta publication incident

Date: 2026-08-12

## Impact

GitHub Pages remained on `tftset17-17.9-r409-m2a8c26d30a`. Android correctly reported patch 17.9, but that published snapshot no longer matched the current MetaTFT Platinum+ composition leaderboard.

## Proven failure chain

1. CommunityDragon added playable unit `TFT17_IvernMinion`. A derived ability tooltip token was unresolved, so catalog validation rejected every refresh.
2. After that input was handled, publication still failed because older index records contained both ISO timestamps and PowerShell-localized timestamps. String sorting selected an old 17.8 record instead of `latestVersionId`.
3. The misclassified update attempted to reuse `tftset17-17.9-r409` and was rejected by the append-only collision guard.
4. A fixed 5,000-match filter also excluded current high-ranking MetaTFT rows such as Stargazer Mountain Xayah and Timebreaker Pantheon.

GitHub Actions recorded nine consecutive refresh failures after the last successful 2026-08-11 publication. The old valid Pages release remained intact as intended.

## Remediation

- Use `data-index.json.latestVersionId` as the previous-version authority.
- Normalize parsed timestamps to invariant UTC ISO strings before sorting/serialization.
- Unit-test mixed timestamp formats, dangling latest IDs, same-fingerprint republishing, and META_UPDATE IDs.
- Preserve Platinum+ as the preferred scope while adapting the minimum sample threshold to retain a 36-row candidate pool for an 18-row visible leaderboard.
- Fall back to all ranks only once when a new set cannot supply enough Platinum+ candidates.
- Render unresolved derived tooltip values as `戦闘中に変動`; never invent a numeric value and do not block the entire catalog for a legitimate new playable unit.

## Validated local candidate

- version: `tftset17-17.9-r409-m8173a6264c`
- kind: `META_UPDATE`
- fingerprint: `8173a6264c1d9644b1e5f7e6c2a2a7cc23f0acfcb00e9b27f669831438ae14a6`
- snapshot SHA-256: `bfc7436dad4eb4ad6daabe7794422ce67bc9b3fbe9ee6549c09c6ee2b7d48083`
- scope: Platinum+, 1,000-match threshold, 36 candidates, top 18 published
- site validation: PASS, 57 versions, 51,357 manifest file references, 50.03% of the configured 250 MiB ceiling
