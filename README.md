# TFT Mobile Overlay Data

TFT Mobile Overlay の個人利用版へ、検証済み戦術データと画像を配信する公開リポジトリです。Androidアプリのソース、APK、署名鍵、認証情報は含みません。

## 固定エンドポイント

- サイト: https://jinbbb0.github.io/tft-mobile-overlay-data/
- インデックス: https://jinbbb0.github.io/tft-mobile-overlay-data/data-index.json
- ヘルス: https://jinbbb0.github.io/tft-mobile-overlay-data/health.json

## 自動運用

`refresh-tft-data.yml` が UTC の毎時 7・22・37・52分にMetaTFTの Diamond+・現行パッチ・直近3日を確認します。画面に出る構成名、順位、Tier、盤面、レベル別編成、装備、オーグメント、カタログ文面、参照画像のcontent fingerprintが同じなら不要な版を増やしません。新しい版だけを一時領域で生成し、全検証に合格した後にGitHub Pagesへ公開します。

更新時と毎時11分のwatchdogは、GitHub mainの検証済みsiteと実際のPagesをlatest ID・manifest SHAで照合します。Pagesだけ失敗、404、旧版、同一IDの内容不一致が起きても、取得処理とは独立して正常siteを再デプロイします。一時障害で直らない場合だけ重複しないIssueを作り、回復時に自動で閉じます。

公開単位は不変の `bundles/<version-id>/` とSHA-256名の共有 `blobs/` です。最新版ポインタは全ファイルの検証後に `data-index.json` へ反映します。Pagesのactive履歴は最新META_UPDATE 5件と新セット・パッチ・Bパッチの基準版を合わせて最大20件に制限します。外れた版は `archive-map.json` に復旧情報を残し、Git履歴から戻せます。

`latestStableVersionId` は取得元整合性と主要機能が全て検証済みの正式最新版、`latestAvailableVersionId` は新セット直後の図鑑先行版を含む最新利用可能版です。旧クライアント向け `latestVersionId` は常に正式最新版を指します。新セット先行版では構成を `COLLECTING` とし、旧セットの構成を混在させません。

表示される数値、sample count、名称、Tier、盤面、装備、図鑑、画像の変化はcontent fingerprintへ含め、同一パッチ内でもMETA_UPDATEとして公開します。取得時刻だけの変化では重複bundleを作りません。鮮度は6時間で警告、24時間で強い警告です。

## 安全性

- HTTPSのみをアプリで受け入れます。
- active履歴最大20版、1版1,500ファイル、単一30MiB、全体250MiBを配信ゲートとします。
- manifest SHA、表示内容fingerprint、集計条件hashを別々に検証し、同一IDの内容差し替えを拒否します。
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
