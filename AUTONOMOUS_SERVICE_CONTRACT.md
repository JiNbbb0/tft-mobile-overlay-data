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
- 有効な取得元更新から公開: P95 60分、原則2時間以内
- 単発の取得・push・deploy障害: 次の2回の定期実行以内に自動収束
- 不完全bundleの端末適用: 0件
- オフライン時: 直前の正常版を継続
- 通信復旧時: 次回アプリ起動時、またはオーバーレイ稼働中30分以内に追随

GitHubのscheduleは時刻保証ではなく遅延・取りこぼしがあり得るため、「15分ごとに必ず成功」ではなく「次の実行で望ましい状態へ収束する」ことを保証軸にする。

## 版と容量

- 実質的な表示変更は不変bundleとして公開する。
- raw sample countだけの変化では版を増やさない。
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

## 一度だけ必要なこと

1. この自動化をmainへ公開する。
2. GitHub PagesとActionsの権限を有効な状態にする。
3. 対応APKを端末へ一度導入する。

以後の通常PATCH、B_PATCH、META_UPDATE、新セットで、ユーザーがPCを起動したりAPKを作り直したりする必要はない。
