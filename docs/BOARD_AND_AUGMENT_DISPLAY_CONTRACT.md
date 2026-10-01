# MetaTFT board and augment display contract

Verified against the public MetaTFT composition UI and live production acquisition on 2026-10-01. This is an additive extension to snapshot schema 4, not the draft Canonical v2 migration. PR #427 remains separate.

## Final and early boards

- `boardContract: METATFT_SHORTLIST_V1` identifies the new semantics.
- `levelBoards` comes exclusively from `comp_details.results.options`. Preserve upstream candidate order, reject unresolved champion identities, select the first three eligible candidates, then order that shortlist by average placement. Do not promote tiny global-minimum outliers from outside the source shortlist.
- Average placement is clamped to 1–8 after multiplying by `selectedComposition.averagePlacement / comp_details.overall.avg`. This ratio is the public UI's `place_scale`, not an invented adjustment. Preserve `rawAveragePlacement`, `sourceVariantId`, and the source candidate count.
- `earlyBoards` comes exclusively from `early_options`. Keep four popular candidates per level and expose `roundWinRate` separately from final placement. An early board is not a final-level recommendation.
- Canonical current-set IDs and exact source-backed aliases define playable units. Ignore only explicitly declared non-shop, zero-cost, traitless helper entities and their exact asset IDs. Unknown identities stop generation; names and set prefixes are not identity evidence.
- Extra units present in a real source board are not truncated to the level number. The physical grid limit remains 28. No nearby-level board is synthesized.
- Source candidate identity includes both units and trait configuration. Android choices must additionally be scoped to full immutable version, rank, composition, level, and content.

The observed policy covers the standard, unmodified composition view. Advanced user filters and evolution-specific UI transformations are not represented as separate datasets; do not claim all advanced website views are identical.

## Augments

- Composition recommendations are the source's curated Pro Augment tiers, not the statistical `augments` correlation table.
- Each recommendation carries source lookup rarity (`Silver`, `Gold`, `Prismatic`). Missing rarity in the new contract fails validation. Never infer rarity from an icon or suffix.
- Missing recommendations remain empty. Do not pad with generic augments, an older set, another rank, or another composition.
- UI groups the three rarities separately and labels the source as pro evaluation. Unpublished recommendations must not be presented as live win-rate statistics.

## Sample counts and validation

- Composition list count: selected rank/current patch/three-day source composition statistics.
- Board count: source detail candidate observations. Rank-normalized placement does not turn that count into a filtered-rank count.
- Item holder count: three-item-build observations, not all games in the composition.
- Retain source integer counts; abbreviating them or changing a confidence threshold must not change the underlying source count.
- New fields participate in the material fingerprint. Deterministic shortlist/scaling/helper tests are part of `test-refresh-contracts.ps1`; the real seven-rank generation path is tested in an isolated workspace.
- Mixed-set input must preserve the previous index byte-for-byte. Public publication still uses existing schema/hash/content gates and last-known-good behavior.

Sources: [MetaTFT compositions](https://www.metatft.com/comps), the public `comp_details` responses and current-set Japanese lookup already used by this repository. No app source, APK, private source credentials, or device evidence belongs in this repository.
