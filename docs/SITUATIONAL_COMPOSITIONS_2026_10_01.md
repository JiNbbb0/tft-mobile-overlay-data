# Source-backed situational composition metadata

The existing production generator, shared by all seven rank datasets, emits optional `conditionContract: METATFT_SITUATIONAL_V1` and `situationalRequirements`.

Source behavior inspected on 2026-10-01: MetaTFT's public comps display treats a composition as situational when its explicit `name_string` contains `Augment`, or a `top_itemNames` entry has `pcnt >= 0.5` and the item is an emblem. An ordinary recommendation is not proof of a mandatory item.

Resolve identities from the already acquired source lookup. Do not fetch extra per-rank data, guess similar IDs, or infer prerequisites from translated composition names. Missing augment identity remains an explicit generic source marker, not a fake canonical augment. Exact source emblem tags or a one-tool recipe are accepted; two-tool crowns are not trait emblems.

Validation rejects unknown contracts, malformed identities, duplicates, excessive rows and emblem rates below the source threshold. Empty legacy metadata remains compatible. Semantic fingerprints include condition changes so a same-patch change generates a new version. Existing set/patch/cluster, SHA, LKG and rank contracts remain in force.

Android v1.5.7 displays `限定的` and the source-backed condition, without claiming a >=50% adoption condition is mathematically required in every game. Older Android readers can ignore these optional fields.

Japanese Wisp/Coven reference tables are a separate feature. No TFTips collector is added: its terms prohibit automated data collection. No source table is copied or published by this change. Canonical draft PR #427 is not part of this work.
