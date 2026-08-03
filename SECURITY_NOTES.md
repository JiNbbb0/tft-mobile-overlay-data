# Security Notes

- 公開リポジトリにAndroidソース、APK、署名鍵、GitHub token、APIキー、Cookie、環境変数ファイルを置きません。
- GitHub認証はGitHubの認証機構だけを利用し、資格情報をファイルやworkflowログへ保存しません。
- Actionsの権限はworkflowごとに最小化します。Pages配信時だけ `pages: write` と `id-token: write`、コミット時だけ `contents: write` を使います。
- URLはHTTPSに限定し、リダイレクト後もHTTPSであることを公開E2Eで確認します。
- 絶対パス、Windowsドライブ、`../`、重複パス、大文字小文字衝突、不正拡張子を拒否します。
- indexは100版、manifestは1,500ファイル、単一ファイル30MiB、siteは250MiBに制限します。
- ファイルサイズとSHA-256をmanifestに固定し、Android側もダウンロード後に照合します。
- 失敗Artifactは生の認証情報を含めず、工程名と安全化したエラーだけを14日保持します。
- 公開統計取得は認証回避、ブラウザCookie、CAPTCHA回避、非公開APIを利用しません。公開先の利用条件と可用性は継続監視が必要です。
- GitHub Pagesは公開配信であり、秘密情報の保存場所ではありません。
