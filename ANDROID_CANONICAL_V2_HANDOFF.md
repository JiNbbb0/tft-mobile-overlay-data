# Android Canonical Data v2 handoff

## Why this is a handoff

The connected GitHub scope contains `JiNbbb0/tft-mobile-overlay-data`, but not the original Android/Gradle source repository for TFT Overlay. The APK can be inspected for behavior, but a durable UI/data-contract fix should be made in the original source project, built, tested, and signed normally. Do not patch decompiled APK output as production source.

## Required Android changes

### 1. Typed detail-value renderer

Replace ad-hoc string rendering with a typed renderer that understands at least:

- flat number
- percentage fraction
- percentage points
- seconds
- mana
- attack speed
- armor / magic resist
- range
- star-scaled arrays
- `STATIC`, `DYNAMIC`, and `UNRESOLVED` states

Rules:

- Never convert `null` to `0`.
- Never display unresolved source tokens such as `@Foo@` or `{{Foo}}`.
- Never turn an unresolved token into phrases such as `任意の`, `可変値`, or `戦闘中に変動`.
- `DYNAMIC` is valid only when the server explicitly classifies a value as combat-state dependent.
- `UNRESOLVED` must display `データ未取得` or omit the row, depending on screen context.
- Do not display internal float artifacts such as `0.10000000149`; apply unit-aware formatting.

Golden examples:

- raw `0.5`, unit `percentFraction` -> `50%`
- raw `50`, unit `percentPoints` -> `50%`
- raw `0.5`, unit `seconds` -> `0.5秒`
- unresolved -> `データ未取得`, never `0`

### 2. Emblem encyclopedia support

Consume the canonical emblem model instead of relying only on a generic item-name/category search.

Expected minimum fields:

- `traitId`
- `traitName`
- `emblemId`
- `emblemName`
- `craftable`
- `recipe[]`
- `image`
- source/provenance field if present

UX:

- Add an explicit `紋章` category/filter in the encyclopedia.
- Link a trait detail screen to its emblem when one exists.
- Do not imply every trait has an emblem.
- Temporary/copy/phantom emblems must not be shown as the canonical emblem for a trait.

### 3. Feature-level readiness and freshness UX

The app must distinguish:

- valid empty result
- data still collecting
- feature blocked by validation
- stale Last Known Good data
- remote endpoint reachable but source data stale

Do not show `0件` when the server says the feature is `COLLECTING` or `BLOCKED`.
Do not collapse overall `META_COLLECTING` into a generic message such as `構成データを集計中` when compositions themselves are already `READY` and only an optional sub-feature such as composition augments is collecting.

The settings/update screen must display separate concepts instead of one overloaded status line:

- `最終確認`: when the app last reached the publication endpoint successfully
- `最終データ`: timestamp of the active data/source snapshot
- `データ経過時間`: relative age such as `46時間28分前`
- feature status: e.g. `構成 READY / 構成オーグメント COLLECTING`
- stale state: explicit warning once the configured freshness threshold is exceeded

`配信先確認済み` only means the publication endpoint was reachable. It must never be presented as evidence that the underlying gameplay/statistics data is current.

Observed regression to lock down from the 2026-08-31 settings screenshot:

- app check time: `2026/08/31 2:53`
- active source data time: `2026-08-29 04:25 JST`
- age: about `46h28m`
- UI showed `配信先確認済み・元データ更新遅延`
- UI also showed `構成データを集計中`, even though the server quality document reported compositions `READY` and only composition augments `COLLECTING`
- the large bottom status card was horizontally clipped/truncated instead of wrapping or using a concise multi-line layout

Required regression behavior for the same state:

- top-level status: `最後に確認済みのデータを表示中`
- detail: `最終データ 2026-08-29 04:25 JST（約46時間前）`
- feature detail: `構成 READY / 構成オーグメント 収集中`
- endpoint detail may separately say `配信先: 接続正常`
- no text clipping; status cards must wrap or use structured rows and remain readable at supported phone/tablet widths and font scales

Suggested user-facing messages:

- compositions collecting: `構成データを収集中です。`
- optional recommendations collecting: `構成は利用できます。一部のおすすめ情報は収集中です。`
- stale LKG: `最新データを確認できないため、最後に確認済みのデータを表示しています。`

### 4. Board coordinate contract

The server-side Canonical v2 rule is:

- a level board is shown only when that level exists in the source;
- missing levels are never synthesized from adjacent levels;
- positions are sent only when level-specific source positions exist;
- positions use a single canonical 0..27 cell identity and are not vertically flipped by the adapter.

Android must choose exactly one coordinate transformation layer. Add round-trip/golden tests for all 28 cells and at minimum all four corners. A vertical inversion must not happen in both data adapter and UI.

If `positionsAvailable=false`, display the recommended unit set without a fabricated board position.

### 5. MetaTFT composition/item presentation

Composition list contract:

- Queue: Ranked
- Rank: Platinum+
- Patch: Current
- Window: 3 days
- Sort: average placement ascending

Do not locally change this to All Ranks.

Item contract:

- `recommended` means source-defined MetaTFT overview recommendation only.
- `averagePlacementCorrelations` is a separate statistical view.
- `derivedPopularity` is a separate derived view.
- `threeItemBuilds` is a separate build-statistics view.

Never render a derived average-placement ranking under a UI label that claims it is MetaTFT's recommended order.

### 6. Atomic online update

Download candidate data to a temporary/versioned directory, validate before replacing the active data set, then atomically switch the local pointer.

At minimum validate:

- expected release/version id
- manifest hash
- per-file hash where supplied
- JSON schema version compatibility
- required arrays are arrays, including empty `[]`
- set/patch identity consistency

If any validation fails, retain the currently active Last Known Good data.

### 7. Tests required before release

Run the original project's equivalents of:

```text
./gradlew test
./gradlew lint
./gradlew assembleDebug
./gradlew connectedDebugAndroidTest
```

Add tests for:

- typed numeric rendering
- unresolved/dynamic rendering
- Japanese locale
- emblem list/detail
- compositions `[]` versus collecting state
- feature-level readiness: compositions READY while compositionAugments COLLECTING must not render `構成データを集計中`
- endpoint reachable + stale source data must render stale-LKG state, not a healthy/current state
- freshness age formatting and threshold transitions
- settings/update layout at narrow widths, tablet widths, and enlarged font scale; no horizontal text clipping
- all 28 board cells encode/decode
- no double vertical flip
- server data with missing Lv5 board does not fabricate Lv5 positions
- recommendation order preserved from canonical source
- interrupted/invalid update keeps LKG

## Coding-agent handoff prompt

```text
You are implementing the Android half of TFT Overlay Canonical Data v2.

Use the ORIGINAL Android/Gradle source repository, not decompiled APK output.

Goals:
1. Implement a typed data/detail renderer with STATIC/DYNAMIC/UNRESOLVED semantics.
2. Never convert null/unresolved values to fake values or 0.
3. Add the encyclopedia emblem model and explicit 紋章 UI.
4. Read feature-level readiness and show collecting/blocked/stale states instead of misleading 0件 screens.
5. Separate publication reachability, source freshness, active LKG age, and per-feature readiness. Never show `構成データを集計中` if compositions are READY and only composition augments are collecting. Never treat `配信先確認済み` as proof that source data is current.
6. Make the settings/update status layout responsive and multi-line; no horizontal clipping at supported widths/font scales.
7. Use a single 0..27 board coordinate contract; add all-cell round-trip tests and prevent double vertical inversion.
8. If a level-specific board has no source positions, show units only; do not invent cells.
9. Preserve the canonical MetaTFT Platinum+ composition order and source-defined recommendation order.
10. Keep recommended items, average-placement correlations, derived popularity, and three-item builds as separate concepts.
11. Make online updates transactional: temp/versioned download -> schema/hash/identity validation -> atomic pointer swap; on failure retain LKG.
12. Add JVM/UI/instrumentation regression tests and provide test output, screenshots, build SHA, APK hash, and final commit SHA.

Observed regression fixture to reproduce:
- app endpoint check: 2026-08-31 02:53 JST
- active source timestamp: 2026-08-29 04:25 JST (~46h28m old)
- server composition feature: READY
- server compositionAugments feature: COLLECTING
Expected UI: stale-LKG warning + endpoint reachable + `構成 READY / 構成オーグメント 収集中`; never generic `構成データを集計中`; no clipped status text.

Do not claim success until unit tests, lint, build, connected tests, and representative screenshot/golden tests pass.
```