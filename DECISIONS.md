# Decisions

## 2026-08-17

- 15分監視、頻繁なMETA_UPDATE、最大100版、整理禁止の組み合わせにより、2026-08-14に100版へ到達して自動更新が自己停止した。上限拡張だけでは再発するため、不変bundleを維持したbounded active historyへ変更する。
- Pagesには最新META_UPDATE 5件とNEW_SET/PATCH/B_PATCHの新しい基準版を合わせて最大20件だけ置く。整理版は `archive-map.json` とGit履歴から復旧可能にし、未参照bundle/blobはstagingでのみ除去し、全検証後にsiteを置換する。
- `latestVersionId`、`metaFingerprint`、完全manifest SHA、`sourceQueryHash` を別の契約値として扱う。同一version IDの内容差し替えは許可しない。
- 画面に出るレベル別編成、リロール計画、標本数等もfingerprintへ含める。取得時刻だけの変化は版変更にしない。
- 元データ時刻が6時間を超えて古い場合は正常版を破棄せず、クライアントで配信遅延として表示する。

## 2026-08-09

- 同一set/patch/MetaTFT clusterでも、正規化した構成タイトル、Tier、順位（小数第2位）、盤面、装備順位、推奨オーグメントが変化した場合にだけ `META_UPDATE` を作る。取得時刻、URL、標本数だけの増減はfingerprintから除外し、版の大量発生を防ぐ。
- 構成一覧はMetaTFT公開ページの現行条件（Ranked / current / 3 days / Platinum+ / Avg Placement）と表示閾値を正本にする。独自の全ランクfallbackを禁止し、構成名はMetaTFT日本語lookupを優先する。条件不一致やlookup欠損時は壊れた候補を公開せずLKGを維持する。
- `META_UPDATE` はcluster revisionを保持しつつfingerprint先頭10文字をversion IDへ加える。旧来の無期限append-only方針は2026-08-17のbounded active historyへ置き換えた。
- 新セットはCommunityDragonのカタログが検証できた時点で `META_COLLECTING` として配信できる。構成統計が不足するときは空の構成を新セット名で補わず、アプリに「構成データを集計中」と表示させる。dry-runは架空のSet 18だけを `build/` に生成し、公開siteを変更しない。

## 2026-08-04

- Androidアプリ本体とは別の公開リポジトリにし、公開対象を配信用データ・画像・検証ツール・workflow・運用文書に限定する。
- バージョン識別子は既存設計どおり `setId + patch + revisionId` とする。セット変更を `NEW_SET`、パッチ変更を `PATCH`、同一セット・同一パッチ内のrevision変更を `B_PATCH` とする。
- 公式パッチ番号はRiot Gamesの公開パッチノートから、セットと構成revisionは既存採用済みの公開メタデータから検出する。
- GitHub Pagesの公開元はActionsとし、標準 `github.io` HTTPS URLを固定エンドポイントにする。独自ドメインは使わない。
- 全bundleを不変として残し、重複画像はSHA-256 blobで共有する。容量接近時も自動削除しない。
- 取得失敗、形式変更、件数急減、検証失敗は「更新失敗」とし、現在の公開版を維持する。取得失敗を成功扱いしない。
- テストrevisionは短時間だけlatestにして公開E2Eを行い、確認後は本番版をlatestへ戻し、テスト版をindexから外す。正常な本番bundleは削除しない。
- GitHub Pagesの一般的な上限とは別に、アプリ配信用の保守的な250MiBゲートを維持する。70/85/95%で警告し、自動削除はしない。
- GitHub Actions cronはUTCで評価される。混雑しやすい毎時0分を避け、7/22/37/52分に設定する。
- 公開統計エンドポイントの形式・可用性・利用条件は変化し得るため、各取得版の利用条件メモを記録し、異常時は自動公開を停止する。
