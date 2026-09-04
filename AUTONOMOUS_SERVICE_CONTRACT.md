# Autonomous Service Contract

## 結論

初回公開と対応APKの導入が完了した後、通常のTFT更新はユーザーPC、Codex、手動取得、手動push、APK再生成なしで処理する。

この契約でいう「手入れ不要」は、GitHubと採用済み公開データ源が通常提供されている範囲を指す。GitHubアカウント停止、ActionsまたはPagesの無効化、取得元の廃止・認証化・利用条件変更、意味が変わる非互換schema変更まで永久に自動修復できるとは表現しない。

GitHubからAndroid描画までの全経路と監査結果は `END_TO_END_AUTONOMY_AUDIT_2026-08-17.md` を正本とする。

## 定常運用の収束条件

定期処理は毎回、次の3状態を比較する。

1. Source observed: Riot、CommunityDragon、公開統計源から取得・検証した状態
2. Repository desired: GitHub mainの検証済み `site/` が示す配信予定状態
3. Public observed: GitHub Pagesで実際に取得できる状態

`Repository desired` と `Public observed` のlatest version IDまたはmanifest SHAが異なる場合、Sourceに新しい変更がなくても、検証済みsiteを再デプロイする。これにより「データcommitは成功したがPages公開だけ失敗した」状態は、次回の定期実行で人手なしに収束する。

## 自動処理する更新

- NEW_SET
- PATCH
- B_PATCH
- META_UPDATE
- カタログだけの変更
- 日本語名・説明文だけの変更
- 参照画像だけの変更
- 新セット初動の統計不足から通常統計への昇格
- 一時的なHTTP、runner、push、Pages障害からの復旧

## SLO

- 通常運用操作: 0回
- ユーザーPCまたはCodex: 不要
- 通常時の取得元更新から端末反映: 15〜30分を目標（GitHub Actionsの遅延時を除く）
- 単発の取得・push・deploy障害: 次の2回の定期実行以内に自動収束
- 不完全bundleの端末適用: 0件
- オフライン時: 直前の正常版を継続
- 通信復旧時: 次回アプリ起動時、またはオーバーレイ稼働中15分以内に再確認

GitHubのscheduleは時刻保証ではなく遅延・取りこぼしがあり得るため、「15分ごとに必ず成功」ではなく「次の実行で望ましい状態へ収束する」ことを保証軸にする。

## 版と容量

- ユーザーに見える数値、sample count、名称、Tier、盤面、装備、図鑑、画像の変化はすべて不変bundleとして公開する。
- 取得時刻だけが変わり内容が同一なら、重複bundleを作らない。
- active履歴は直近META_UPDATE 5件と節目版を合わせて最大20件。
- 旧版は復旧台帳とGit履歴から復元可能にする。
- 公開siteの70%、85%、95%容量警告を維持する。

## 自動停止する安全条件

次の場合は誤ったデータで穴埋めせず、直前の正常版を維持する。

- set、patch、revision、rank scopeが一致しない
- 取得元が暗黙にrank条件を変更した
- JSON、画像、参照、SHA、件数ゲートが不正
- 新セットのCommunityDragonデータがまだ揃っていない
- 統計源が認証化、廃止、または非互換変更された

既知の一時障害は次回実行で自動再試行する。意味を推測しなければ直せない未知の契約変更だけを、人間対応が必要な例外とする。

## 正式版と先行版

- `latestStableVersionId`: Riot、CommunityDragon、MetaTFTの取得元整合性と主要機能をすべて検証した正式最新版。
- `latestAvailableVersionId`: 新セット直後の図鑑先行版を含む、検証済みの最新利用可能版。
- 旧APK向け `latestVersionId` は必ず `latestStableVersionId` と同じ値にする。
- 新セット直後は図鑑だけを `READY`、構成を `COLLECTING` とした単一bundleを公開し、旧構成を混ぜない。
- 構成、盤面、装備など主要機能が揃った時だけ同じ版を `STABLE` へ昇格する。
- 表示データが6時間古いと警告、24時間古いと強い警告にする。

## 一度だけ必要なこと

1. この自動化をmainへ公開する。
2. GitHub PagesとActionsの権限を有効な状態にする。
3. 対応APKを端末へ一度導入する。

以後の通常PATCH、B_PATCH、META_UPDATE、新セットで、ユーザーがPCを起動したりAPKを作り直したりする必要はない。
