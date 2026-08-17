# End-to-End Autonomy Audit

## 判定

TFT Overlayの通常運用は「ユーザーPC、Codex、手動push、パッチごとのAPK更新を必要としない」設計を正本とする。公開データはGitHub上で望ましい状態へ繰り返し収束し、Androidは検証済みの新しいデータだけを適用する。

外部サービスの廃止、認証化、利用条件変更、意味を推測しなければ直せない非互換schema変更、GitHubアカウントやActions自体の停止は、安全に自動修復できる範囲外とする。その場合も誤データは公開せず、直前の正常版を維持してIssueを1件だけ作る。

## 全経路

### 1. GitHub側の通常更新

1. UTC毎時7、22、37、52分に定期処理を起動する。
2. MetaTFTの公開cluster、Riot公式パッチ記事、CommunityDragonの現在セットを独立取得する。
3. セット、パッチ、revision、実効rank、cluster混在、暗黙のfilter変更を検証する。
4. 空の候補領域へチャンピオン、特性、アイテム、オーグメント、構成、配置、装備統計、参照画像を生成する。
5. カタログ、構成、参照画像SHAを合わせたcontent identityを計算する。
6. 表示内容に実質変更がなければ版を増やさない。観測時刻だけの更新は6時間単位に集約する。
7. JSON、参照、画像、件数、サイズ、SHA、文字化け、セット整合性を検証する。
8. 検証済みの不変bundleを追加し、最後に `data-index.json` のlatestを更新する。
9. active履歴を最新META_UPDATE 5件と節目版、合計最大20件に整理する。外れた版は復旧台帳へ記録する。
10. GitHub mainへcommitし、Pagesへ原子的にデプロイする。
11. 公開HTTPSからindex、manifest、主要JSON、画像を再取得して検証する。

### 2. 変更なし・Pagesだけ古い場合

1. 取得元に変更がなくても、GitHub mainのlatest IDと実manifest SHAをPagesの実体と比較する。
2. 404、旧版、同一IDの異なるmanifestを検出したら、main上の直前正常siteを再配信する。
3. 更新処理自体が失敗しても、独立watchdogが同じ照合と再配信を行う。
4. 修復できなければ重複しない `automation-health` Issueを1件だけ作り、回復後に自動で閉じる。

### 3. 新セット初動

1. MetaTFTのset ID変更を検出する。
2. CommunityDragonが新セットをまだ配信していなければ旧正常版を維持し、次回再試行する。
3. カタログが揃い統計が不足している間は準備状態として扱い、存在しない数値を生成しない。
4. Platinum+の十分な母数を優先し、不足時だけ明示的に全ランクを1回比較する。
5. Platinum+が十分になった後は自動的に通常母集団へ戻す。
6. 新セットから参照されない旧セット画像は新bundleへ混入させない。

### 4. Android側

1. アプリ起動時に自動更新が有効なら確認する。オーバーレイ稼働中は30分間隔で確認する。
2. PagesとGitHub raw mainを別々に取得・検証する。
3. set、patch、元データ時刻、完全なcontent identityで新しい候補を選ぶ。
4. 選択したindexと同じHTTPS配信元からmanifestと全ファイルを取得する。
5. manifest SHA、全ファイルSHA、サイズ、JSON schema、set、patch、revision、fingerprintを検証する。
6. 全件成功後だけactive版を切り替え、図鑑・構成一覧・オーバーレイへ同じdata sessionを通知する。
7. 失敗時は端末のlast-known-goodを維持し、古い予備経路へdowngradeしない。
8. 保存版を明示選択中は勝手にlatestへ切り替えず、「最新版」とも表示しない。
9. 端末bundleは選択中を保護しながら最大5件へ整理する。

## 設計思想との照合

| 要求 | 実装判断 |
|---|---|
| 普段の手入れをゼロにする | GitHub schedule、reconcile、watchdog、Android起動時・30分確認で自動収束 |
| 古いのに最新版と表示しない | source時刻が6時間超なら遅延表示。保存版と配信latestを分離 |
| 壊れた新版を使わない | 候補領域で全検証後にlatest更新。Androidも全件成功後だけactive化 |
| 新セットへ柔軟に追随する | set IDから動的抽出し、カタログ準備待ちとrank母数不足を状態として扱う |
| ストレージを増やし続けない | Pagesはbounded history、画像GC、Androidは最大5bundle |
| パッチごとにAPKを作らない | schema契約内のデータ・画像・説明・構成変更はオンラインbundleで処理 |
| 障害を隠さない | Actions Summary、公開health、重複しないIssue、アプリの遅延・失敗表示 |

## 今回の監査で修正した問題

1. 生成・deploy後の検証が更新前commitをcheckoutし、正常な公開を失敗扱いしていた。後続検証とwatchdogを常に最新mainへ固定した。
2. watchdog自身の検査が失敗した場合、専用Issue作成処理までskipされていた。失敗時もhealth判定を必ず実行する。
3. PowerShell 7がJSONのISO時刻をDateTimeへ自動変換し、文化依存形式でmanifestへ再保存していた。UTC ISOへ正規化する。
4. 公式パッチ判定が英語の表示文言1種類だけに依存していた。英語・日本語の公式記事一覧と安定したURL slugを併用し、未知形式はfail-closedにした。
5. セット固有アイテム判定にSet 17の固定prefixが残っていた。現在のset番号から動的に判定する。
6. Androidの保存bundle実体が増え続けた。選択中を保護しつつ最大5件へ自動整理する。
7. Androidのオーバーレイ監視が「自動更新OFF」を無視していた。既定ONを維持しながら設定を正しく尊重する。
8. 予備indexのlatestに完全identityがなくても候補になれた。manifest SHA、meta fingerprint、query hashの3点を必須にした。
9. Pages ActionsがNode.js 20世代の旧majorだった。公式のNode.js 24対応majorへ更新した。

## 人間対応が残る例外

- MetaTFT、Riot、CommunityDragonの廃止・認証化・利用条件変更
- 意味を推測しなければ変換できない非互換schema変更
- GitHubアカウント停止、ActionsまたはPagesの無効化、GitHub全体の長期障害
- Android側が未対応の新しい配信schemaを必要とする機能追加

これらは通常PATCH、B_PATCH、META_UPDATE、新セット初動とは分ける。通常更新と一時障害はユーザー操作なしで処理し、未知の契約変更だけを安全停止と通知の対象にする。
