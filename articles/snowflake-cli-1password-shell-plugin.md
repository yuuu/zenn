---
title: "Snowflake CLI用の1Password Shell Pluginがなかったので自作してコントリビュートしてみた"
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
[こちらのAWS CLI/CDKの記事](https://dev.classmethod.jp/articles/1password-shell-plugins-aws-cli-cdk/)のように、普段は`aws`や`cdk`と同じ感覚でコマンドを打つだけで裏で1Passwordの生体認証を挟んで認証情報が注入される体験を、Snowflake CLI(`snow`)でも実現したい、というモチベーションを書く。ただし調べてみると`snow`用のプラグインは存在しなかったので、自作して本家にコントリビュートすることにした、という記事全体の流れを予告する。

## 1Password Shell PluginsにSnowflake CLI用のプラグインはあるか調べた

TODO: [1Password/shell-plugins](https://github.com/1Password/shell-plugins)の`plugins/snowflake`を調査した結果を書く。
既存の`snowflake`プラグインは**モダンなSnowflake CLI(`snow`)ではなく、レガシーな`snowsql`専用**であること（`SNOWSQL_ACCOUNT` / `SNOWSQL_USER` / `SNOWSQL_PWD`という環境変数を使い、パスワード認証のみでキーペア認証は非対応であること、セットアップコマンドが`op plugin init snowsql`であること）を、一次情報（GitHubリポジトリ、[https://www.1password.dev/cli/shell-plugins/snowflake](https://www.1password.dev/cli/shell-plugins/snowflake)）へのリンク付きで示す。

TODO: SnowSQLがレガシー扱いであり、Snowflake自身が新規プロジェクトでは`snow`の利用を推奨している旨（[Migrating from SnowSQL to Snowflake CLI](https://docs.snowflake.com/en/user-guide/snowsql-migrate)へのリンク）を書き、「`snow`用のShell Pluginが存在しないので自作する」という結論に繋げる。

## Snowflake CLIはどうやって認証情報を受け取れるか

TODO: `snow`が対応している認証情報の渡し方（パスワード認証・キーペア認証それぞれについて、環境変数`SNOWFLAKE_ACCOUNT`/`SNOWFLAKE_USER`/`SNOWFLAKE_PASSWORD`/`SNOWFLAKE_PRIVATE_KEY_RAW`、コネクション名指定の`SNOWFLAKE_CONNECTIONS_<NAME>_PASSWORD`、`config.toml`への直接記載）と、それぞれの優先順位（コマンドライン引数 > 接続名指定の環境変数 > `config.toml` > 汎用環境変数）を、[公式ドキュメント](https://docs.snowflake.com/en/developer-guide/snowflake-cli/connecting/configure-connections)を引用しながら整理する。
Shell Pluginsの「環境変数注入」という仕組みと相性が良い点を書く。

## 1Password Shell Pluginを自作する

TODO: `1Password/shell-plugins`をフォークし、`make new-plugin`でプラグインの雛形を生成する手順を、実際に実行したログ・生成されたファイル一覧とともに書く。

### plugin.go / credentials.go / snow.go の実装

TODO: 実際に書いたGoコードを貼る。特に以下の設計判断とその理由を書く。

- クレデンシャルのフィールド構成（アカウント・ユーザー名・パスワード）
- `EnvVarProvisioner`で`SNOWFLAKE_ACCOUNT`/`SNOWFLAKE_USER`/`SNOWFLAKE_PASSWORD`にマッピングした理由（接続名指定の環境変数ではなく汎用環境変数を選んだ理由）
- `NeedsAuth`の実装（`--help`/`--version`実行時や、認証情報を直接指定している場合にプラグインの注入をスキップする条件）
- `~/.snowflake/config.toml`からのインポート機能を実装したか、できたか（TOML対応の可否）

### ローカルでビルド・検証する

TODO: `make <plugin>/validate`、`make <plugin>/example-secrets`、`make <plugin>/build`の実行結果を貼る。

## 1Passwordにアイテムを登録して動かしてみる

TODO: `op plugin init snow`を実行して1Passwordの新規アイテムを作成する流れ（実際の画面のキャプチャは認証情報が映り込まないよう注意して用意する）を書く。
`op plugin init`が生成した`~/.config/op/plugins.sh`（`alias snow="op plugin run -- snow"`が書かれているはず）の中身と、それを`.zshrc`等に`source`させることで、以降は普段通り`snow`と打つだけでプラグイン経由の実行になる、という設定を書く（[AWS CLI/CDKの記事](https://dev.classmethod.jp/articles/1password-shell-plugins-aws-cli-cdk/)と同じ体験）。

## 動作確認

TODO: シェルを開き直し、いつも通り`snow sql -q "..."`と打つだけで1Passwordの生体認証プロンプトが表示され、承認するとパスワードを一切入力せず・環境変数にも平文で残さずに接続できたことを確認した結果を書く。
`env | grep SNOWFLAKE`でコマンド実行後に環境変数が残っていないことを確認した結果も書く。
Shell Pluginを一時的に無効化して素の`snow`バイナリを直接叩きたい場合の対処方法（判明した場合はその方法、判明しなかった場合はエイリアスを一時的にunaliasする等の代替策）も書く。

## (発展) キーペア認証にも対応させる

TODO: 時間内にキーペア認証用のCredentialType（`SNOWFLAKE_PRIVATE_KEY_RAW`への注入）を追加できたかどうかを書く。できなかった場合はその理由（複数行シークレットの扱いなど）を正直に書く。

## (比較) プラグインを自作しない場合の選択肢

TODO: `op run -- snow sql ...`による環境変数注入、`op inject`による`config.toml`テンプレート展開を実際に試した結果を書き、Shell Plugin自作との体験の違い（コマンド実行のたびに`op run --`を付ける必要があるかどうかなど）を比較する。
1Password SSH Agentとキーペア認証の組み合わせを検討した結果（対応可否）も書く。

## ハマったところ

TODO: 実際に手を動かして詰まった点（SDKの型名、`config.toml`との優先順位、1Password側のフィールド設定など）を書く。

## 本家にコントリビュートする

TODO: [1Password/shell-plugins](https://github.com/1Password/shell-plugins)の[CONTRIBUTING.md](https://github.com/1Password/shell-plugins/blob/main/CONTRIBUTING.md)に沿って準備したこと（コミット署名、`sdk/plugintest`によるテスト、サードパーティ依存を増やさないための設計判断）を書き、実際に出したPRへのリンクを貼る。
公開時点でPRがマージ済みか、レビュー中かの状態を明記する。Shell Pluginsがベータ版であるため、レビューでのフィードバックや実装の手直しがあった場合はその顛末も書く。

## おわりに

TODO: まとめと所感。本家にコントリビュートしてみた感想（OSSへの初コントリビュートだった場合はその旨）と、PRの今後の見通しを書く。
