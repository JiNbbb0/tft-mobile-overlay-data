# GitHub Pages Deployment

## Production URLs

- Repository: https://github.com/JiNbbb0/tft-mobile-overlay-data
- Pages: https://jinbbb0.github.io/tft-mobile-overlay-data/
- Data index: https://jinbbb0.github.io/tft-mobile-overlay-data/data-index.json
- Health: https://jinbbb0.github.io/tft-mobile-overlay-data/health.json

## Source

GitHub PagesのSourceは `GitHub Actions` です。branch配信は使いません。`site/` を `actions/upload-pages-artifact@v4` で固め、`actions/deploy-pages@v4` でデプロイします。

## Publication contract

サイトルートに `data-index.json` と `health.json`、版ごとの `bundles/<version-id>/manifest.json`、不変の共有 `blobs/<sha256>.<extension>`、schemaを配置します。公開前にローカル完全検証、公開後にHTTPS E2Eを実行します。

## First-time setup

公開リポジトリの Settings > Pages でSourceをGitHub Actionsに設定します。その後 `Validate and redeploy Pages` を1回実行します。以降は変更検出workflowが自動公開します。
