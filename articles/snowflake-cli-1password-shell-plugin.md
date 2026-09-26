---
title: "Snowflake CLI用の1Password Shell Pluginを拡張して、キーペア認証にも対応させてみた"
emoji: "❄️"
type: "tech" # tech: 技術記事 / idea: アイデア
topics:
  - snowflake
  - 1password
  - cli
  - oss
published: false
publication_name: fusic
---

## はじめに

TODO: 以前[Snowflake CLIのOAuth認証設定についての記事](https://zenn.dev/fusic/articles/snowflake-cli-oauth)を書いたが、今回はOAuth以外（パスワード認証・キーペア認証）の認証情報を1Passwordでどう安全に管理・注入するかを調べた話を書く、という導入を書く。
1PasswordのCLI連携機能である[Shell Plugins](https://developer.1password.com/docs/cli/shell-plugins/)を使うと、対象CLIの実行時に環境変数へ動的に認証情報を注入でき、平文でパスワードや秘密鍵をディスクに置かずに済む、という前提知識を書く。
[こちらのAWS CLI/CDKの記事](https://dev.classmethod.jp/articles/1password-shell-plugins-aws-cli-cdk/)のように、普段は`aws`や`cdk`と同じ感覚でコマンドを打つだけで裏で1Passwordの生体認証を挟んで認証情報が注入される体験を、Snowflake CLI(`snow`)でも実現したい、というモチベーションを書く。

## 1Password Shell PluginsにSnowflake CLI用のプラグインはあるか調べた

TODO: [1Password/shell-plugins](https://github.com/1Password/shell-plugins)の`plugins/snowflake`を調査した結果を書く。
既存の`snowflake`プラグインは**モダンなSnowflake CLI(`snow`)ではなく、レガシーな`snowsql`専用**であり、しかも**パスワード認証のみでキーペア認証には対応していない**ことを、一次情報（GitHubリポジトリ、[https://www.1password.dev/cli/shell-plugins/snowflake](https://www.1password.dev/cli/shell-plugins/snowflake)）へのリンク付きで示す。

## 方針転換: 新規プラグインを自作する？ それとも既存プラグインを拡張する？

TODO: 当初は「`snow`用の新規プラグインを自作する」つもりで作業を始めたが、既存の`plugins/snowflake`のソースコードとSDKの内部実装（`Executable`ごとに`Provisioner`を上書きできる仕組み、複数の`CredentialType`を1プラグインに持たせられる仕組み）を調べた結果、**既存プラグインに「`snow`への対応」と「キーペア認証への対応」を追加する拡張PRにする方が、新規プラグインを一から作るよりも実装量・レビューされやすさの両面で有利**と判断した、という思考の転換過程を書く。
既存のnpm/pnpmプラグイン（同じCredentialTypeを異なる環境変数名にマッピングして2つのExecutableで使い分けている実例）へのリンクも貼る。

## Snowflake CLIはどうやって認証情報を受け取れるか

TODO: `snow`と`snowsql`それぞれの認証情報の渡し方の違いを整理する。特に、`snow`は秘密鍵の中身をそのまま環境変数`SNOWFLAKE_PRIVATE_KEY_RAW`に渡せるのに対し、`snowsql`は秘密鍵をファイルパス（`--private-key-path`）でしか受け取れない、という非対称性が実装方針に影響した点を書く（[snowコマンドの公式ドキュメント](https://docs.snowflake.com/en/developer-guide/snowflake-cli/connecting/configure-connections)、[snowsqlの公式ドキュメント](https://docs.snowflake.com/en/user-guide/snowsql-start)）。

## 既存プラグインを拡張する

TODO: `1Password/shell-plugins`をフォークし、`plugins/snowflake`配下に手を入れた手順を、実際に実行したログ・変更したファイル一覧とともに書く。

### キーペア認証用のCredentialType（`private_key.go`）を追加する

TODO: 実際に書いたGoコードを貼る。`Account`/`Username`/`PrivateKey`（複数行シークレット）/`Passphrase`（任意）というフィールド構成にした理由、`snow`向けのデフォルトProvisioner（`SNOWFLAKE_PRIVATE_KEY_RAW`への環境変数マッピング）を書く。

### `snow`用のExecutable（`snow.go`）を追加する

TODO: パスワード認証・キーペア認証のどちらでも使えるようにした`Uses`の設計と、実際に動かして分かった`CredentialUsage.Optional`の挙動（期待通り「どちらか一方でOK」という動きになったか、ならなかった場合はどう回避したか）を書く。これが本記事のハマりどころの目玉になる想定。

### (発展) `snowsql`側にもキーペア認証を追加する

TODO: 時間内に対応できた場合、秘密鍵を一時ファイルに書き出して`--private-key-path`引数として渡す独自Provisionerの実装を書く。対応できなかった場合はその理由を正直に書く。

### ローカルでビルド・テストする

TODO: `make snowflake/validate`、`make snowflake/example-secrets`、`make snowflake/build`、`make test`（プラグイン単位のテストターゲットは存在せず、リポジトリ全体の`go test ./...`しか無かった、という発見も含めて）の実行結果を貼る。既存のsnowsql用テストを壊していないことの確認結果も書く。

## 1Passwordにアイテムを登録して動かしてみる

TODO: `op plugin init snow`を実行して1Passwordの新規アイテムを作成する流れ（実際の画面のキャプチャは認証情報が映り込まないよう注意して用意する）を書く。
`op plugin init`が生成した`~/.config/op/plugins.sh`（`alias snow="op plugin run -- snow"`が書かれているはず）の中身と、それを`.zshrc`等に`source`させることで、以降は普段通り`snow`と打つだけでプラグイン経由の実行になる、という設定を書く（[AWS CLI/CDKの記事](https://dev.classmethod.jp/articles/1password-shell-plugins-aws-cli-cdk/)と同じ体験）。

## 動作確認

TODO: シェルを開き直し、いつも通り`snow sql -q "..."`と打つだけで1Passwordの生体認証プロンプトが表示され、承認するとパスワード認証・キーペア認証どちらでも接続できたことを確認した結果を書く。
`env | grep SNOWFLAKE`でコマンド実行後に環境変数が残っていないことを確認した結果も書く。

## 複数のSnowflakeアカウントを使い分ける

TODO: 実務では本番・検証・客先ごとなど複数のSnowflakeアカウントを切り替えて使うことが多いが、1Password Shell Pluginsがこれにどう対応しているかを書く。
[公式ドキュメント](https://developer.1password.com/docs/cli/shell-plugins/multiple-accounts/)にある「現在のターミナルセッションのみ／このディレクトリとサブディレクトリで使用／グローバルデフォルト」という3段階のスコープを使って、実際に2つのSnowflakeアカウント用ディレクトリを用意し、`cd`するだけで自動的に紐付けたアカウントに切り替わることを確認した結果を書く。
`op plugin inspect`で現在の紐付け状況を確認する方法、`op plugin clear`で紐付けを解除する方法も書く。
また、ディレクトリ単位の切り替えでは対応しきれないケース（同じディレクトリで本番/検証を切り替えたい場合など）について、`snow`自体が持つ複数コネクション機能（`snow connection add --connection-name`）との役割分担をどう整理したかを書く。

## (比較) プラグインを使わない簡易な方法

TODO: `op run -- snow sql ...`による環境変数注入を実際に試した結果を書き、プラグインとの体験の違い（コマンド実行のたびに`op run --`を付ける必要があるかどうかなど）を比較する。

## ハマったところ

TODO: 実際に手を動かして詰まった点（SDKの型名、`CredentialUsage.Optional`の挙動、`fieldname`パッケージにキーペア関連のフィールドが無かった場合の対処など）を書く。

## 本家にコントリビュートする

TODO: [1Password/shell-plugins](https://github.com/1Password/shell-plugins)の[CONTRIBUTING.md](https://github.com/1Password/shell-plugins/blob/main/CONTRIBUTING.md)に沿って準備したこと（コミット署名、`sdk/plugintest`によるテスト、既存プラグインへの後方互換な追加であることの強調）を書き、実際に出したPRへのリンクを貼る。
公開時点でPRがマージ済みか、レビュー中かの状態を明記する。

## おわりに

TODO: まとめと所感。「新規プラグインを自作する」という当初の想定から「既存プラグインを拡張する」に方針転換した経緯を振り返り、OSSへのコントリビュートを検討する際は既存実装を読み込むことの重要性、といった気づきを書く。PRの今後の見通しも書く。
