# Automation Operations

## 通常運用

初回公開後は、人間のPCやAndroid APKの再生成は不要です。GitHub Actionsが15分間隔で変更を確認し、変更または公開状態のずれがある場合に次の順で処理します。

1. 公開中のセット、公式パッチ、構成revisionを確認
2. 新しい識別子か判定
3. カタログ、統計、画像、出典台帳を一時生成
4. 差分 `CHANGE_SUMMARY.json/.md` を生成
5. JSON、参照、画像、SHA-256、サイズ、件数減少などを検証
6. 検証済みbundleを履歴へ追加
7. 最後に `data-index.json` のlatestを更新
8. 変更をコミットする。変更がなくてもGitHub mainとPagesが不一致なら、検証済みsiteを再デプロイ
9. 公開HTTPS URLからindex、manifest、主要JSON、サンプル画像を再検証

### 新セット初動の統計母集団

構成統計は通常どおりMetaTFTのプラチナ以上を優先します。ただし、各5,000試合以上の構成が12件未満しかない新セット初動では、全ランク統計を1回だけ確認し、対象構成数が増える場合だけ一時採用します。再試行ループは行いません。全ランクでも不足する場合は既存の `META_COLLECTING` フェイルセーフへ進み、直前の正常版を壊しません。

次回以降の定期実行でプラチナ以上が条件を満たせば自動的に通常母集団へ戻ります。生成スナップショットの `statisticsScope` に、採用母集団、判定件数、切替理由を記録します。

## Workflows

- `Refresh and publish TFT data`: UTC毎時7/22/37/52分、および手動実行。変更なしならコミットせず、Pagesが不一致の時だけ再配信。
- `Watch unattended data automation`: 毎時11分と更新workflow終了後に実行。取得処理と独立してGitHub mainとPagesを照合し、404、旧版、manifest SHA不一致を検出したら検証済みsiteを自動再配信。修復不能または連続失敗時だけ重複しないIssueを1件作成し、回復時に閉じる。
- `Validate and redeploy Pages`: データを再取得せず、現在の追跡済みsiteを検証して手動再配信。
- `Restore a validated version as latest`: 既存versionIdを指定して検証し、latestだけを戻して再配信。
- `Keep scheduled automation active`: UTC毎月1日17:13。小さなheartbeat状態だけを更新し、配信データは変更しない。

## 監視

通常成功は追加の外部通知を発生させません。一時的な取得・push・Pages障害は次の定期実行またはwatchdogが自動修復します。4回連続失敗、6時間成功なし、または公開不一致を自動修復できない場合だけ、公開リポジトリに `automation-health` Issueを1件作成します。Summaryには版、セット、パッチ、revision、変更・公開有無、失敗工程、固定URL、次の対応が記録されます。

## 手動実行

GitHubの `Actions` から対象workflowを選び `Run workflow` を押します。同一版IDの再生成・置換は公開ツール側で拒否されます。

## 容量

配信サイトは250MiBを上限とし、70%（175MiB）、85%（212.5MiB）、95%（237.5MiB）で警告します。active配信履歴はlatest、直近のMETA_UPDATE最大5件、セット・PATCH・B_PATCHの基準版を保護しつつ最大20件へ自動整理します。外れた版は `archive-map.json` に復旧情報を残します。上限そのものは自動拡張せず、整理後も警告域へ達した場合だけ人間が配信先や保持方針を判断します。
