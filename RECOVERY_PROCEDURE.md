# Recovery Procedure

## GitHub Actions失敗時

一時的なHTTP、runner、push失敗は次の15分実行で自動再試行します。失敗runは未検証siteをコミット・配信しないため、公開中の正常版は維持されます。4回連続失敗または6時間成功なしの場合、watchdogが重複しない `automation-health` Issueを1件作成します。その時だけRun Summaryの `Failed stage` と14日保持のfailure Artifactを確認します。回復するとIssueは自動で閉じます。

## GitHub Pages停止時

毎時watchdogと更新workflow終了後の監視が、GitHub mainのlatest ID・manifest SHAとPagesを比較します。404、旧版、同一IDの異なるSHAを検出すると、取得処理とは独立して追跡済みsiteを全検証し、自動再デプロイして公開URLを再確認します。GitHub PagesまたはActions自体が停止して自動修復できない場合だけ、復旧後に `Validate and redeploy Pages` を手動実行します。

## data-index.json破損・誤ったlatest・壊れたbundle

`Restore a validated version as latest` を開き、直前の正常な `version_id` を指定します。workflowは対象manifestと全siteを検証し、`data-index.json` と `health.json` のlatest情報だけを安全に変更してPagesへ再公開します。bundle自体の検証に失敗した対象は選べません。

## リポジトリ削除・停止

ローカルの `tft-mobile-overlay-data` とAndroidアプリ側の固定URL記録を使い、同名公開リポジトリを復元します。名前が変わる場合は新しいPages URLを公開・検証し、アプリのURL変更を含む新APKが必要です。既存APKはURLを動的に差し替えられません。

## GitHubユーザー名・Pages URL変更

標準Pages URLが変わるため、リポジトリ内workflowと文書、Android `data_index_url` を更新します。HTTPS、HTTP 200、JSON、manifest、bundle、blob、SHA-256の公開E2E後に新APKを配布します。

## 250MiB上限接近

新版公開時に、active履歴を最新版込み5版へ整理します。最新available・stable正常版・直前availableの枠を確保し、残りを新しい順に残します。整理対象の直近50件は `archive-map.json` にmanifest SHAと元commitを残します。古いbundleと未使用blobの整理はstaging内だけで行い、最終検証失敗時は現在の配信サイトを変更しません。整理後も70/85/95%へ達した場合は自動上限拡張せず、画像増加や未参照blobを調査します。

## archive-mapから旧版を復旧

`archive-map.json` で対象IDと `archivedFromCommit` を確認します。該当commitからbundleと参照blobを一時領域へ取り出し、manifest SHAを台帳と照合してからactive indexへ追加します。台帳は直近50件のみなので、それ以前はGit履歴の調査が必要です。`validate-site.ps1` に合格するまでPagesへ公開しません。端末へ既に保存済みの版は、Pagesから外れた後もオフラインで利用できます。ただし未保存の過去版の再ダウンロードは保証しません。古いindexを保持した端末の途中ダウンロードが404になった場合も不完全版を採用せず、次のindex取得から最新版で再試行します。

## データ提供元の形式変更

更新workflowを失敗状態のままにして正常版を維持します。取得レスポンスを必要最小限のArtifactで調査し、パーサーとスキーマ・fixtureを同時更新します。存在しない統計値で穴埋めしません。

## アプリ側スキーマ変更が必要な時

既存schemaVersionの配信を維持したまま、後方互換または新schemaVersion対応のAPKを先に配布します。新アプリの普及前に互換性を壊すlatestを公開しません。`minimumAppVersionCode` で未対応APKへの確定を拒否します。

## ローカル緊急確認

```powershell
./tools/validate-site.ps1
./tools/set-latest-version.ps1 -VersionId <known-good-version-id>
```

ローカル変更だけでは本番に反映されません。通常は上記workflow_dispatchを使用します。
