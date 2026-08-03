# Recovery Procedure

## GitHub Actions失敗時

Run Summaryの `Failed stage` と14日保持の failure Artifactを確認します。再実行は一時障害のときだけ1回行います。同じ失敗を3回繰り返しません。失敗runはsiteをコミット・配信しないため、公開中の正常版は維持されます。

## GitHub Pages停止時

`Validate and redeploy Pages` を手動実行します。追跡済みsiteを全検証してから再デプロイし、固定HTTPS URLを確認します。

## data-index.json破損・誤ったlatest・壊れたbundle

`Restore a validated version as latest` を開き、直前の正常な `version_id` を指定します。workflowは対象manifestと全siteを検証し、`data-index.json` と `health.json` のlatest情報だけを安全に変更してPagesへ再公開します。bundle自体の検証に失敗した対象は選べません。

## リポジトリ削除・停止

ローカルの `tft-mobile-overlay-data` とAndroidアプリ側の固定URL記録を使い、同名公開リポジトリを復元します。名前が変わる場合は新しいPages URLを公開・検証し、アプリのURL変更を含む新APKが必要です。既存APKはURLを動的に差し替えられません。

## GitHubユーザー名・Pages URL変更

標準Pages URLが変わるため、リポジトリ内workflowと文書、Android `data_index_url` を更新します。HTTPS、HTTP 200、JSON、manifest、bundle、blob、SHA-256の公開E2E後に新APKを配布します。

## 250MiB上限接近

自動削除しません。70/85/95%の警告を受け、履歴保持、別リポジトリ、Release asset、オブジェクトストレージ等を比較します。ユーザー承認なしに古い版を消しません。

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
