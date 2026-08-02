---
title: "Snowflake CLIの認証設定、結局どうすればいいのか？調べてみた"
emoji: "❄️"
type: "tech" # tech: 技術記事 / idea: アイデア
topics:
  - snowflake
published: true
published_at: "2026-08-03 07:30"
publication_name: fusic
---

Snowflake CLIとは、Snowflakeが提供する開発者向けのコマンドラインツールです。
スピーディにアプリケーションを構築したり、SQLを実行したりすることができます。

https://docs.snowflake.com/ja/developer-guide/snowflake-cli/index

この記事はOAuthで認証したい場合の設定をどうすればCLIで完結させられるか、まとめたものです。
時間のない人向けに、私が考えた最短の設定コマンドを先に記載しておきます。

```sh
$ snow connection add \
  --connection-name {コネクション名} \
  --account {アカウント名(xxxxxxx-xxxxxxx)} \
  --user {ユーザー名} \
  --authenticator OAUTH_AUTHORIZATION_CODE \
  --role {ロール名} &&
echo 'client_store_temporary_credential = true' >> ~/.snowflake/config.toml &&
snow connection set-default {コネクション名}
```

## 認証どうするか問題

Snowflake CLIを使ってSnowflakeに接続する際の認証ですが、2026年1月のアップデートでSnowflake OAuthが提供開始となりました。

https://docs.snowflake.com/en/release-notes/2026/other/2026-01-21-snowflake-oauth-local-applications

実際にOAuth認証するための方法はこちらの記事が参考になります。
`config.toml` を編集することでOAuth認証するための設定を構成できるようですね。

https://dev.classmethod.jp/articles/snowflake-oauth-local-applications-snowflakecli-try/

## えっ？config.toml を編集する必要があるの？

CLIの認証設定をするのにファイルを開いて書き直さないといけないというのは少々手間ですね。
AWS CLIだと `aws configure --profile` で設定が完結しますし、Snowflake CLIでもできそうなものです。

そこでサブコマンドやコマンドラインオプションを駆使することで、ファイルを開かずとも認証設定できないか調べてみました。

## コネクションの追加

まず `snow connection add` というコマンドを使うことでコネクションを追加できることがわかりました。
「コネクション」とは名前の通り接続の定義であり、AWS CLIでいうところの「プロファイル」が概念としては近いです。

```sh
$ snow connection add --connection-name {コネクション名}
```

そして `snow connection add` コマンドには次のようなコマンドラインオプションが用意されており、実はOAuth認証のための設定はこれだけで完結します。

```sh
$ snow connection add \
  --connection-name {コネクション名} \
  --account {アカウント名(xxxxxxx-xxxxxxx)} \
  --user {ユーザー名} \
  --authenticator OAUTH_AUTHORIZATION_CODE \
  --role {ロール名}
```

## 毎回ブラウザが開かないようにする

上記で認証自体は行えるようになるのですが、何かコマンドを入力するたびにブラウザが開き、認証をやり直す必要があります。
まさにこの記事に書かれている件です。

https://zenn.dev/fusic/articles/0018-snowflake-claude-code-snow-cli-auth

この記事によると `SNOWFLAKE_CLIENT_STORE_TEMPORARY_CREDENTIAL` という環境変数をセットすることで、認証情報を一時ストアに記憶させられるとのことでした。
実際には環境変数をセットせずとも `config.toml` に次の設定を追記するだけでも、同じことを実現可能です。

```toml
[cli]
ignore_new_version_warning = false

[cli.logs]
save_logs = true
path = "/Users/{macOSユーザー名}/.snowflake/logs"
level = "info"

[connections.oauth]
account = "{アカウント名(xxxxxxx-xxxxxxx)}"
user = "{ユーザー名}"
role = "{ロール名}"
authenticator = "OAUTH_AUTHORIZATION_CODE"
client_store_temporary_credential = true # この行を追記する
```

ということは `snow connection add` にもこの1行を追加するためのコマンドラインオプションがあるはず...

と思って調査したのですが、残念ながら現状無いようです😭
仕方がないので `echo` を使って `config.toml` へ追記することにしました。

```sh
$ echo 'client_store_temporary_credential = true' >> ~/.snowflake/config.toml
```

## デフォルトコネクションを設定する（任意）

複数のSnowflakeアカウントを併用する場合においてコネクションを複数作成したとして、デフォルトのコネクションを指定したいことがあります。
この場合は次のコマンドでデフォルトのコネクションを指定できます。

```sh
$ snow connection set-default {コネクション名}
```

`config.toml` の先頭部分にデフォルトのコネクション名が追記されます。

```toml
default_connection_name = "{コネクション名}" # この行が追記される

[cli]
ignore_new_version_warning = false

[cli.logs]
save_logs = true
path = "/Users/{macOSユーザー名}/.snowflake/logs"
level = "info"

[connections.{コネクション名}]
account = "{アカウント名(xxxxxxx-xxxxxxx)}"
user = "{ユーザー名}"
role = "{ロール名}"
authenticator = "OAUTH_AUTHORIZATION_CODE"
client_store_temporary_credential = true
```

## 動作確認

以上の設定方法で、Snowflakeに対してさまざまな操作を行えるようになります。
試しに現在のユーザーを取得するクエリを実行してみます。

```sh
$ snow sql --query "select current_user()" --connection {コネクション名}

select current_user()
+----------------+
| CURRENT_USER() |
|----------------|
| {ユーザー名}     |
+----------------+
```

このように実行ができました。
デフォルトのコネクション名を指定した場合は `--connection` オプションを省略できます。

## まとめ

まとめると、次のようなワンライナーを実行することで、Snowflake CLIをOAuth認証で使用できるようになります。

```sh
$ snow connection add \
  --connection-name {コネクション名} \
  --account {アカウント名(xxxxxxx-xxxxxxx)} \
  --user {ユーザー名} \
  --authenticator OAUTH_AUTHORIZATION_CODE \
  --role {ロール名} &&
echo 'client_store_temporary_credential = true' >> ~/.snowflake/config.toml &&
snow connection set-default {コネクション名}
```

`client_store_temporary_credential` の設定をオプションで指定できない点がイマイチだと感じたため、GitHubにIssuesへ起票しておきました。
もし承認されたら、このコマンドラインオプションを追加するPRを出してみるつもりです。

https://github.com/snowflakedb/snowflake-cli/issues/3152
