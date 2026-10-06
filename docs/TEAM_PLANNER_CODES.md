# チームプランナーコード

各rank snapshotのcompositionに、任意項目`teamPlannerCode`を追加する。旧APK/旧snapshotの互換性を維持する。

- Riotのteam planner datasetをCommunityDragonから取得。7ランクの同一バッチ内は既存ResponseCacheで成功/失敗を共有する。任意取得は1試行20秒・最大3試行とし、失敗をrankごとに繰り返さない。
- 対象`TFTSetN`の`character_id`とcurrent catalogのIDを完全一致で結合する。名前/prefixによる推測をしない。
- Riot v2形式: `02` + 完成編成順の3桁hex ID×10スロット + `TFTSetN`。空きは`000`、同一ユニットの複数配置を保持。位置・星・装備はコードに含まれない。
- コードはsnapshot/manifestの既存SHA検証対象。コード変更もmetaFingerprintへ含め、META_UPDATEとして配信する。
- 別set/不足ID/10枠超過/上流障害時は空コードとする。この任意のコピー機能の失敗だけで、正常なメタ更新を止めない。前setのIDを補完しない。
- `validate-static-meta.ps1`がset/形式/実盤面の枠数を検証。新しいformatや4095を超えるIDは受け付けない。
- App側は表示sessionのsetと完成編成枠数を再検証してclipboardへ書き込む。コピー時の外部アクセスはない。

局所検証: `test-team-planner-contract.ps1`。現行65ユニットを完全一致で解決、7ランク126/126構成を生成可能と確認（2026-10-07 JST）。TFTクライアントへの実貼り付けは未確認。

取得元: https://raw.communitydragon.org/latest/plugins/rcp-be-lol-game-data/global/default/v1/tftchampions-teamplanner.json
形式の実装資料: https://github.com/nkhoit/tftkit#team-planner-codes

`add-team-planner-codes.ps1`は取得済み同setソースから同梱asset/fixtureを再生成する。通常の本番生成は`refresh-static-meta.ps1`が同じ契約を用い、取得hash/日時を既存source observationへ記録する。
