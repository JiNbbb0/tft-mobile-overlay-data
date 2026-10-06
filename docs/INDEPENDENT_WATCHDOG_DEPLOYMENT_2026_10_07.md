# 独立更新監視の導入記録（2026-10-07 JST）

## 原因と対策

GitHubの更新cronとGitHub上の監視cronが共に6〜7時間起動しない区間を実測。
同じ時計だけに依存しないようCloudflare Workers Freeの5分タイマーを追加した。
Cloudflareは既存main workflowを起動するだけで、取得・7ランク生成・検証・公開・LKG保護を置き換えない。
同時実行を検出した場合は待ち、失敗が続く場合は起動間隔を延ばす。料金プランの変更は行っていない。

本番接続試験では、workerdが `redirect: "error"` を拒否してTypeErrorになった。
`manual` とHTTPステータス検証を組み合わせ、リダイレクト拒否を維持したまま修正した。
公式実装: https://github.com/cloudflare/workerd/blob/main/src/workerd/api/http.c++
通信関数のreceiverも保持し、秘密を出さない工程別診断を追加した。

## 確認済み

- PR #490 / main `4c4f0ef`: source確認証跡、公開品質JSONのcache-busting修正、独立監視を追加。
- PR #491 / main `fa6cd1b`: 実環境の通信互換性と安全な診断を修正。
- 完全パイプラインCI `37510293965`: success。以降は全体テストを再実行していない。
- 最終通信修正の局所テスト: 3 PASS。自動CI `37515575622`: success。
- GitHub App: data repo一つのみ、Actions read/write、Contents read。鍵はCloudflare暗号化Secret。
- 2026-10-07 04:03 JST: 独立タイマーが `CHECKED / REFRESH_DUE / REFRESH` を記録。
- 自動起動run `37516029102`: actor `tft-data-watchdog-jinbbb0[bot]`、workflow_dispatch。
- 同runはrefresh / deploy / verify-publication全成功。`Source verified: tftset18-18.4-r425-md6706527db` は2026-10-06 19:15:15 UTCに成功し、同一パッチ内の新メタ版も自動公開した。
- 次の定期確認は `WAIT / RUN_IN_PROGRESS` となり、二重起動せず前回のsourceVerifiedAtを取得。
- 19:18:01 UTCの実Cronで新しい公開版を認識し、sourceVerifiedAtが19:15:15 UTCへ更新。`WAIT / REFRESH_INTERVAL` と判断し、正常な更新直後に余計な起動を行わないことも確認。
- GitHub repository variable `INDEPENDENT_WATCHDOG_URL` の保存を画面で確認。秘密ではないhealth URLのみ。
- その前の本番run `37513312596`: 生成・Pages公開・remote検証全成功。
- 公開版 `tftset18-18.4-r425-md6706527db` とtracked版・manifest SHA・品質JSONが独立した読み取り専用probeでも一致（PUBLICATION_VERIFIED）。sourceAtは2026-10-06 19:05:57 UTC。
- 構成/盤面/推奨装備/図鑑はREADY、構成オーグメントはPARTIAL。欠損をREADYとは報告しない。

## 残る確認

- GitHubから独立監視を確認する逆方向の監視処理の実行結果（設定保存は確認済み）。
- 48時間の無人運転、長時間のCPU/無料枠消費、実機アプリの最新取得。
- 新しい障害全てへの自動復旧や、15〜30分の厳密なSLAは保証しない。

## 停止・復旧

CloudflareのENABLEDをfalseにしてもGitHubの既存cronと現在の正常版は残る。
鍵の更新が必要なときは本人がSecretを更新する。鍵本文をGit・チャット・ログへ保存しない。
PR #427は変更していない。Androidコード・APK・設定も変更していない。
