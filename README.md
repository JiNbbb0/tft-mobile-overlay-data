# TFT Mobile Overlay Data

TFT Mobile Overlay の個人利用版へ、検証済み戦術データと画像を配信する公開リポジトリです。Androidアプリのソース、APK、署名鍵、認証情報は含みません。

## 固定エンドポイント

- サイト: https://jinbbb0.github.io/tft-mobile-overlay-data/
- インデックス: https://jinbbb0.github.io/tft-mobile-overlay-data/data-index.json
- ヘルス: https://jinbbb0.github.io/tft-mobile-overlay-data/health.json

## 自動運用

`refresh-tft-data.yml` が UTC の毎時 7・22・37・52分に最新版を確認します。`setId + patch + revisionId` が既存版と同じなら、コミットも再配信もしません。新しい版だけを一時領域で生成し、全検証に合格した後に履歴へ追加し、GitHub Pagesへ公開します。

公開単位は不変の `bundles/<version-id>/` とSHA-256名の共有 `blobs/` です。最新版ポインタは全ファイルの検証後に `data-index.json` へ反映します。古い版は自動削除しません。

## 安全性

- HTTPSのみをアプリで受け入れます。
- 最大100版、1版1,500ファイル、単一30MiB、全体250MiBを配信ゲートとします。
- SHA-256、サイズ、JSON、ID、参照、セット・パッチ・改訂の整合性を公開前に検証します。
- 異常な件数減少や画像欠損増加時は公開せず、Actions Artifactへ簡潔な失敗レポートだけを保存します。
- APIキー、Cookie、トークン、APK、Androidソースは置きません。

## データについて

Riot Games公式ページと公開データ、CommunityDragon、既存製品で採用済みの公開統計エンドポイントを参照します。出典・取得時刻・応答ハッシュ・件数・利用条件メモは各bundleの `DATA_SOURCE_MANIFEST.json` に保存します。統計値を推測生成しません。

TFT Mobile Overlay Data は Riot Games、MetaTFT、Overwolf の公式サービスではありません。各名称・画像等の権利は各権利者に帰属します。

## 運用文書

- [自動化運用](AUTOMATION_OPERATIONS.md)
- [復旧手順](RECOVERY_PROCEDURE.md)
- [セキュリティ](SECURITY_NOTES.md)
- [配信構成](GITHUB_PAGES_DEPLOYMENT.md)
- [設計判断](DECISIONS.md)
