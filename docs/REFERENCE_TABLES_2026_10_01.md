# Independent Japanese reference tables — current evidence and limits

## Requested contract

Wisp **strength ratings** and **price/effect/offer conditions** are separate features. Never treat a numeric offer tier as an S/A/B rating. Jin subsequently approved **MetaTFT for strength ratings only**. Price/effect/conditions continue using the independently published source and official checks.

## Strength ratings — verified after approval

MetaTFT's public `wisp_tiers` contains 175 editorial entries, updated `2026-10-01T02:58:24.828Z`. Of these, 160 have exact membership in CommunityDragon's current Set18 `setData.items`; one officially disabled Major Polymorph entry is withheld, leaving **159 Japanese rows** (S41/A37/B67/C9/D5). The other 15 are withheld as unconfirmed identities, not guessed from similar names. This is explicitly partial coverage.

The endpoint does not expose a native patch number. Evidence is current-set item membership plus an editorial update after the official patch publication time. The table explains this limitation; it is not claimed as an explicit patch-certified API response. Coverage below 90%, duplicate IDs, wrong entity type, unresolved names, stale pre-patch timestamp or future timestamps fail closed for this optional feature. Source order and tier labels are preserved, not recalculated by the app.

The exact disabled ID `DA_18_MajorPolymorph` was cross-checked against the published Wisp record and official September 28 notice. CommunityDragon calls it `上級変身術`; the official Japanese notice says `変身術(上級)`. No fuzzy name-to-ID resolver is introduced.

The production Japanese MetaTFT lookup inspected separately reports `_metadata.patch: pbe`. Its numerical tooltips are not used for these new reference tables. This is a separate existing-catalog source-provenance concern to audit; a successful reference-table gate does not certify every existing catalog tooltip as current LIVE data.

## Confirmed current facts

- [Riot 18.3 Japanese patch notes](https://teamfighttactics.leagueoflegends.com/ja-jp/news/game-updates/teamfight-tactics-patch-18-3/): normal Blood and Iron cost 4, Combust damage 15%, Mana-Rich Soil reduction 15%, Three Me cost 10. Blossom variants include Combust 18% and Mana-Rich Soil 20%. The article also contains 18.3B and September 28 updates. Major Polymorph and Dark Ritual are disabled; do not display Dark Ritual AP as an active Coven reward.
- [Little Buddy Bot publicly embedded Wisp sheet](https://www.littlebuddybot.com/tft-wisps): the normal and upgraded rows were retrieved and checked separately. All eight included rows match the checked current fields. The `Tier` column is NOT a strength rating. Re-offer cooldown is measured in Wisp **shops**, not rounds or gold.
- CommunityDragon Japanese item names are matched by exact ApiName. Its effect constants for Combust/Mana-Rich Soil were stale at inspection; they are NOT used as current effect values in this table.

The table includes only **four Wisp families / eight variants**, with an explicit partial-coverage note. Japanese descriptions are short factual paraphrases, not copied page artwork/layout. Exact price, effect, stage bands, special conditions, exclusions, normal-mode eligibility and cooldown are rechecked before display. An unknown ID is not guessed. The table timestamp is the curated table's verification time, not an invented upstream update time.

## Pipeline

Once per existing catalog refresh: public page + its public sheet → exact Set/Patch and field checks → optional catalog `systemData.referenceTables` → existing semantic fingerprint/SHA/immutable bundle → shared Android/overlay native table renderer. No app calls to the sheet, and no sevenfold per-rank fetches. HTTPS-only curl redirects, 25-second timeout, 4 MiB cap, no automatic retry loop.

Unavailable strength ratings do not hide verified factual rows. A failed optional fetch emits an unavailable table, without substituting a previous patch or blocking otherwise validated composition datasets. A new Set/Patch with no definition yields **no old table categories**, not Set18 placeholders.

Definitions are exact-patch reviewed translations. A changed source field or a new patch needs a newly verified translation definition; **this is not a completed unattended future-patch reference-table generator**. The existing seven-rank composition pipeline remains automatic. No source-clock-only content churn is added: the stable verification timestamp is in the definition, not regenerated each poll.

## Sources not adopted / remaining gaps

- [TFTips terms](https://tftips.app/terms) prohibit automated collection; no collector created.
- [TFTraits terms](https://www.tftraits.com/terms/) restrict harvesting for redistribution; not adopted.
- [Little Buddy terms](https://www.littlebuddybot.com/terms-of-service) attribute TFT content to Riot. No explicit commercial redistribution license or partnership is claimed. Riot/product-policy requirements remain separate from a technical PASS.
- Wisp S/A/B: approved MetaTFT editorial provider added; 159 exact-current-set rows verified, 15 unresolved identities and one disabled entry withheld. No fake rating generated.
- Coven: inspected current [18.3 source graphic](https://www.littlebuddybot.com/tft-coven), SHA-256 `d70ae115a048040d8c37a50755bec3157536033b7328e6c15094b0678ac1a9e6`. Full reward translation/identity verification and robust acquisition remain unfinished. Graphic is not shipped or copied into the public site. Do not silently replace the requested reward table with an essence-only summary.

## Verification

- Reference-table regression: exact identity, content/condition changes, duplicate IDs, separate unavailable ratings, future set absence, and timeout fail-closed.
- Real public sheet + exact CommunityDragon Japanese names: READY, eight rows. This is data-side verification, not Android device E2E.
- Real public editorial endpoint + native current-set membership: READY, 159 rows; disabled Major Polymorph absent. Still not device E2E or proof of native patch metadata.
- Existing real seven-rank production dry-run with situational metadata: PASS; mixed-set input preserved LKG. One earlier run failed because of Git worktree ownership, not source correctness; fixed using process-scoped `safe.directory`, no global trust change.
- Full production dry-run including the new optional table path and public CI remain separate checks; do not infer them from the earlier run.

Canonical draft PR #427 is not merged or modified by this feature.
