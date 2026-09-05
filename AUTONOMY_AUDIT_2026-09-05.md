# 7ランク無人配信監査 — 2026-09-05

## 2026-09-06 訂正・追加方針

9月5日の「全履歴を配信領域に永久保持するので約25版で停止」という結論は誤り。既存`Select-ActiveDataHistory`/publisherにはMETA_UPDATE 5件＋基準版、合計20版への整理と未参照blob除去が存在した。25版は整理がないと仮定した単純計算であり、本番の残り公開回数ではない。以下の旧容量節は当時の監査誤りの記録として扱い、現行仕様の根拠にしない。

公開承認と「過去分の保管は重視しない」という追加方針により、既存の整理機構を活用して、通常の配信枠を最新込み5版に変更。最新available・stable LKG・直前availableを枠内で保護し、残りを新しい順に選ぶ。新しい保管サービスは追加しない。archive-mapの復旧台帳も直近50件に限定。古いbundleと未参照画像はstagingだけで除去し、最終検証成功後にサイト全体を置換する。Git履歴と端末に保存済みのデータは削除しない。

200回のPATCH/B_PATCH/NEW_SET/META_UPDATE試験で5版以内と正常版保護を確認する。実publisherの隔離試験では物理bundle数・未参照blob除去・保持manifest不変・最終検証失敗時の配信全ファイル維持を検証する。公開後の結果は別途追記する。

実publisher故障試験は既存site全体を複製・複数回検証するためPR CI専用とし、15分ごとの本番refreshでは軽量な200回のpolicy試験だけを実行する。定期更新の待ち行列を故障試験自身が増やさない。

watchdog復旧後も過去の同名alert Issueが複数残る既存状態を確認。警告発生中は1件へ集約し、正常復旧時は同名のopen Issueを一括closeするよう修正。アプリへGitHub URLや生ログを送る処理は追加していない。

## 結論と公開境界

通常の取得・7ランク生成・検証・Pages公開はGitHubのrunnerだけで動作し、PC/Codexの起動は不要。ただし「新しい情報が永久に必ず配信される」保証はない。上流障害時の正常版維持と、新版配信の継続は別の性質である。

今回、監視の見逃し・復旧時の競合・再実行の重複をローカル修正した。本報告作成時点ではpush/PR作成/デプロイしていない。Android/APKも変更していない。Canonical v2 PR #427は対象外。公開承認後の実CI・実デプロイ確認が必要。

作業基点: main `9d4e6b6`。ローカルbranch: `codex/seven-rank-autonomy`。

## 確認した本番状態

- 7ランク: Gold+, Platinum+, Emerald+, Diamond+, Master+, Grandmaster+, Challenger。各18構成。
- latest: `tftset18-18.1-r422-mc213c493d3`、TFTSet18 / 18.1 / revision 422。
- metaFingerprint: `c213c493d3ef2a0c7f4ed1d2983c64a60c055ee78ab98f3fa838ceaf3bfe8be9`。
- manifest SHA-256: `bd32bea2a2ef93dcc47f3ade8277c8577ab246d185525357884084d2e7e0f648`。
- snapshot SHA-256: `754056afb3c2308b9f2feb16a193c78a1552678fd13494ba43e7f14adbce1f50`、8,110,289 bytes。
- 公開index: https://jinbbb0.github.io/tft-mobile-overlay-data/data-index.json
- main/Pages照合: IN_SYNC。今回のremote検証は628 manifest entries中、catalog/snapshot/代表画像の3ファイルを実取得してPASS。今回全628ファイルを再取得したという意味ではない。
- refresh run `33968410853`: push起動、2026-09-05 13:16:16–13:24:32 UTC、success。
- watchdog `33968811184`: workflow_run、success。`33969495988`: schedule、13:38–13:39 UTC、success。
- 最終照会14:23:55 UTC時点で、7ランク変更後のschedule起動refresh成功はまだ観測できていない。観測済みの直近scheduled refresh `33964757474` は変更前の11:58:54–12:03:08 UTC。設定済みと定期実行実証済みを混同しない。
- workflowはactive。refresh cron UTC 7/22/37/52分、watchdog 13/33/53分。実際の起動には間隔の空きがあり、原因をGitHub API結果だけで断定しない。

## 通常の流れと安全境界

1. GitHub schedule、承認された手動実行またはmain変更で起動。
2. `refresh-live-data-gated.ps1` が公開cluster/current-setの準備状況を確認。
3. `refresh-live-data.ps1` がセット/パッチを検出し、Riot/CommunityDragonカタログとMetaTFTを取得。
4. `refresh-ranked-compositions.ps1` がランクregistryを使って7条件を生成。取得成功レスポンスを同一run内で共有し、アプリの操作回数でMetaTFTアクセスを増やさない。
5. 同一Set/Patch/revisionの7条件とID/参照/ファイル/hashを検証。別ランク・旧セットで穴埋めしない。
6. 全条件成功後にだけ候補を採用。内容不変なら新規版・データcommit・不要な再公開を作らない。
7. publication lock内で検証済みsiteをPages artifactへまとめ、公開後にremote検証。
8. アプリは配信済みbundleから選択ランクを表示。既存の保存版・同梱fallbackを維持。

ランク統計が実際に少ない場合のPARTIAL/空データと、取得失敗・不正JSON・混在clusterは別。後者は全体の新版を止めてLKGを維持する。非default rankの正当な少数標本は既存契約に従って扱う。新セットは既存のcatalog-first/統計収集中契約を維持する。現在正常な版がある限り、更新失敗だけで公開中の版を消す処理にはしない。

## 発見事項と今回のローカル修正

| 発見事項 | 修正 |
|---|---|
| SOURCE_NOT_READYがexit 0になるため、実データが古くても直近run成功で健康判定され得た | 公開/取得確認の経過時間とrun成否を分離。6時間/24時間、検査不能をhealth判定へ追加 |
| 内容不変は意図的にcommitしないため、bundleの古い時刻だけでは確認停止と区別不能 | 成功runの小さな検証Artifactを7日保持。版ID/run ID一致・NO_CHANGE/PUBLISHED・正常完了main runのみ確認時刻として採用。SOURCE_NOT_READYは採用しない |
| watchdogがロック取得前に作った古いartifactで新しい公開を巻き戻し得た | 修復jobがpublication lockを取得した後にmain再checkout・再照合・検証・artifact生成・deploy |
| remote payload検証失敗でもindex照合だけでalertを閉じ得た | verify-repairの失敗も健康判定へ伝播 |
| stale監視が稼働中のrefreshと重複して再実行を要求 | queued/in_progress等があれば要求しない。直近起動から30分cooldown。有限の再試行を維持 |
| timeout/cancel等がfailure連続回数に入らない | timed_out/cancelled/action_requiredも対象化 |
| 容量警告がlogだけに留まる | 250MiBの70/85/95%、または100版の70/85/95版で単一health issueの対象にする |
| 新しいGitHub側scriptが構文検査から漏れる | toolsだけでなく.github/scriptsもPS syntax gate対象化。watchdog変更をrank CI対象へ追加 |

観測時刻は「同じ内容であることを取り直して確認した時刻」であり、MetaTFT自体の情報発生時刻ではない。immutable bundleの取得日時・統計値を書き換えず、verification basisを別出力する。上流が古い内容を正常応答する場合の真の鮮度までは、この確認時刻だけでは保証できない。

## 容量評価の訂正と採用した対策

現在siteは55,249,674 bytes、1,270物理ファイル、8版。250MiBまで206,894,326 bytes。

前報告の「約25版」は整理がないと仮定した計算で、既存の最大20版への整理を見落としていた。本番の残り配信回数ではない。この評価は撤回する。

新方針は最大5版への整理。隔離publisher試験では35,491,211 bytesへ減少し、保持manifestのSHA不変、不要bundle/blob除去、最終検証失敗時の現行サイト全ファイル維持を確認した。この数値はfixture結果であり、本番サイズは公開後に測定する。

長期保管の優先度は低いため、新しい外部保管サービスは不要と判断した。5版でも将来の1版サイズ次第で250MiBに達し得るため、容量警告・上限検証は残す。Git履歴の容量増加はPages容量とは別の長期監視対象。

## テスト

- production workflow掲載の回帰22スクリプト: PASS。7rank、未来セット/カタログ先行、混在Set拒否、rollback等を含む。
- `test-autonomous-recovery.ps1`: PASS。green-but-stale、6h/24h、容量、有限復旧、run/version違い、未来時刻、SOURCE_NOT_READY拒否、UTC往復、修復lock構造。
- `test-watchdog-runtime.ps1`: PASS。HTTPをfixtureに置換して実watch scriptを実行。成功run＋古いデータで単一alert、正常時は無通知。出力のissue #1はmockでありGitHubへの実投稿ではない。
- tools/.github/scripts全PowerShell syntax: PASS。
- `git diff --check`: PASS。source/currentとsiteに差分なし。
- 公開URLのindex/manifest/代表3payload検証: PASS。
- 未実施: 今回変更の実GitHub CI、認証付きArtifact取得の実運用、修復jobの実deploy、変更後のscheduled refresh実証。YAML専用parserはローカル環境になく、追加依存は導入していない。PS構文/差分/構造regressionをYAMLサーバー検証の代替成功とは扱わない。

## 完全無人の限界と次の順序

外部の統計がまだ存在しない、429/5xxや形式変更、GitHub/Pages障害、容量不足の場合、正しい新版は作れない。その際は「不正データを配る」ではなく「LKGを残して、利用可能範囲と停止理由を知らせる」が採用方針。

GitHub scheduleは遅延・dropの可能性があり、public repositoryは活動停止60日でschedule無効化の対象になる。同じGitHub上のwatchdogはGitHub全体停止から独立ではない。15～30分以内の常時保証や人間の保守ゼロを宣言しない。[GitHub公式 schedule仕様](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#schedule)

1. 承認後に今回の修正を公開し、CI→手動run→NO_CHANGE Artifact採用→watchdog→scheduled runを実確認する。
2. 5版整理後の実容量を測定し、将来のセットで単一版が大きくなった場合は警告を確認する。過去版用の外部保管は追加しない。
3. 実Set/Patch移行時にも契約試験を継続。source形式変更時は失敗閉鎖とLKGを維持してadapterを修正する。

今回の変更ファイル: `.github/scripts/check-refresh-freshness.ps1`、新規`request-refresh-recovery.ps1`、refresh/watchdog/rank-validationの3workflow、`tools/automation-health-policy.ps1`、`tools/watch-automation-health.ps1`、新規回帰2本、本報告書。
