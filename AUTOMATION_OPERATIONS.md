# Automation Operations

## 通常運用

人間のPCやAndroid APKの再生成は不要です。GitHub Actionsが15分間隔で変更を確認し、変更がある場合だけ次の順で処理します。

1. 公開中のセット、公式パッチ、構成revisionを確認
2. 新しい識別子か判定
3. カタログ、統計、画像、出典台帳を一時生成
4. 差分 `CHANGE_SUMMARY.json/.md` を生成
5. JSON、参照、画像、SHA-256、サイズ、件数減少などを検証
6. 検証済みbundleを履歴へ追加
7. 最後に `data-index.json` のlatestを更新
8. 変更をコミットし、Pages artifactをアトミックにデプロイ
9. 公開HTTPS URLからindex、manifest、主要JSON、サンプル画像を再検証

## Workflows

- `Refresh and publish TFT data`: UTC毎時7/22/37/52分、および手動実行。変更なしならコミット・Pages配信なし。
- `Validate and redeploy Pages`: データを再取得せず、現在の追跡済みsiteを検証して手動再配信。
- `Restore a validated version as latest`: 既存versionIdを指定して検証し、latestだけを戻して再配信。
- `Keep scheduled automation active`: UTC毎月1日17:13。小さなheartbeat状態だけを更新し、配信データは変更しない。

## 監視

通常成功は追加の外部通知を発生させません。失敗時はGitHub標準のActions通知とRun Summaryを確認します。Summaryには版、セット、パッチ、revision、変更・公開有無、失敗工程、固定URL、次の対応が記録されます。

## 手動実行

GitHubの `Actions` から対象workflowを選び `Run workflow` を押します。同一版IDの再生成・置換は公開ツール側で拒否されます。

## 容量

配信サイトは250MiBを上限とし、70%（175MiB）、85%（212.5MiB）、95%（237.5MiB）で警告します。削除は自動化しません。警告後に人間が出典・履歴要件を確認し、別配信先または明示的な保持方針を決めます。
