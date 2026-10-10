---
title: "Snowflake CLIのキーペア認証を1Password CLIと連携して、秘密鍵をPCに残さず使い分ける"
emoji: "❄️"
type: "tech" # tech: 技術記事 / idea: アイデア
topics:
  - snowflake
  - 1password
  - snowflakecli
  - security
published: true
published_at: "2026-10-12 07:30"
publication_name: fusic
---

## はじめに

Snowflake CLI（`snow` コマンド）からSnowflakeに接続する際、パスワード認証は手軽ですが、MFAの有効化や、パスワードそのものの管理が悩みの種になります。

そこで有力な選択肢となるのが**キーペア認証**です。公開鍵をSnowflakeのユーザーに登録し、秘密鍵で署名することで認証します。パスワードもMFAのプロンプトも不要になり、自動化にも向いています。

https://docs.snowflake.com/ja/user-guide/key-pair-auth

一方で、秘密鍵を `~/.snowflake/rsa_key.p8` のようにPCへ置きっぱなしにするのは、できれば避けたいところです。

そこで本記事では、次の内容を順に紹介します。

- キーペアの生成と、Snowflakeユーザーへの登録
- Snowflake CLIでのキーペア認証
- 1Password CLIと連携し、秘密鍵をPCに残さない方法
- プロジェクトごとに鍵・コネクションを切り替える方法

:::message
動作確認は Snowflake CLI 3.27.0 で行っています。設定項目やコマンドは、バージョンによって異なる場合があります。
また、本記事で解説する「秘密鍵をPCに残さない方法」においては、[direnv](https://direnv.net/) が必要です。
:::

## キーペアの生成

まず、`openssl` で秘密鍵と公開鍵を生成します。
秘密鍵はパスフレーズで暗号化しておくと、万一ファイルが漏れても、そのままでは使えないので安心です。

```bash
# 暗号化された秘密鍵（PKCS#8形式）を生成。パスフレーズの入力を求められる
openssl genrsa 2048 | openssl pkcs8 -topk8 -v2 aes256 -inform PEM -out rsa_key.p8

# 秘密鍵から公開鍵を生成
openssl rsa -in rsa_key.p8 -pubout -out rsa_key.pub
```

パスフレーズなしの秘密鍵を作る場合は、2行目の `-v2 aes256` の代わりに `-nocrypt` を指定します。

```bash
openssl genrsa 2048 | openssl pkcs8 -topk8 -inform PEM -out rsa_key.p8 -nocrypt
```

:::message alert
`rsa_key.p8`（秘密鍵）は絶対に公開しないでください。Gitリポジトリにもコミットしないよう注意が必要です。
:::

## キーペアの登録

次に、公開鍵をSnowflakeのユーザーに登録します。
`rsa_key.pub` の中身から `-----BEGIN PUBLIC KEY-----` と `-----END PUBLIC KEY-----` の行を除き、改行を取り除いた文字列を使います。

```bash
# ヘッダー・フッターと改行を除いた公開鍵を表示
grep -v "PUBLIC KEY" rsa_key.pub | tr -d '\n'
```

表示された文字列を、`ALTER USER` で登録します。
なお、他のユーザーの公開鍵を設定するには `SECURITYADMIN` 以上のロールが必要です。自分自身のユーザーであれば、通常は自分で設定できます。

```sql
ALTER USER my_user SET RSA_PUBLIC_KEY = 'MIIBIjANBgkqh...';
```

登録できたか確認するには、`DESC USER` を実行し、`RSA_PUBLIC_KEY_FP` にフィンガープリントが表示されていればOKです。

```sql
DESC USER my_user;
```

Snowflakeでは、ユーザーに公開鍵を2つ（`RSA_PUBLIC_KEY` と `RSA_PUBLIC_KEY_2`）まで登録できます。
この仕組みは鍵のローテーションに利用できます。新しい鍵を `RSA_PUBLIC_KEY_2` に登録して切り替えたあと、古い鍵を削除します。

```sql
-- 古い鍵を削除
ALTER USER my_user UNSET RSA_PUBLIC_KEY;
```

## 認証する

登録した鍵を使って、Snowflake CLIから接続してみましょう。
コネクションは `config.toml`（`~/.snowflake/config.toml` など）に定義します。

```toml
[connections.myproject]
account = "myorg-myaccount"
user = "MY_USER"
authenticator = "SNOWFLAKE_JWT"
private_key_file = "~/.snowflake/rsa_key.p8"
```

ポイントは `authenticator = "SNOWFLAKE_JWT"` と `private_key_file` です。
秘密鍵をパスフレーズで暗号化している場合は、環境変数 `PRIVATE_KEY_PASSPHRASE` にパスフレーズを設定しておきます。

```bash
export PRIVATE_KEY_PASSPHRASE='your-passphrase'
snow connection test -c myproject
```

接続に成功すれば、次のように接続情報が表示されます。

```
+----------------------------------------------------+
| key             | value                            |
|-----------------+----------------------------------|
| Connection name | myproject                        |
| Status          | OK                               |
| ...             | ...                              |
+----------------------------------------------------+
```

あとは `snow sql -c myproject -q "SELECT CURRENT_USER()"` のように、`-c`（`--connection`）でコネクション名を指定すれば、パスワードなしでクエリを実行できます。

## 1Passwordとの連携方法

ここまでの方法では、秘密鍵ファイルとパスフレーズがPCに残ってしまいます。
そこで、秘密鍵を1Passwordの「SSH Key」型アイテムとして保管し、必要なときだけ [1Password CLI](https://developer.1password.com/docs/cli/)（`op`）経由で取り出す方法を紹介します。

Snowflake CLIには、秘密鍵の中身を直接渡す `private_key_raw` という設定があります。
環境変数 `SNOWFLAKE_CONNECTIONS_<コネクション名>_PRIVATE_KEY_RAW` で与えることができるので、これを `op run` と組み合わせます。

### 1. 1Passwordに秘密鍵を保存する

1Passwordアプリで「新規アイテム」→「SSH Key」を選び、「既存の鍵をインポート」から `rsa_key.p8` を読み込みます。ここでは例として、`Development` Vaultに `snowflake-myproject` という名前で保存するとします。

秘密鍵をパスフレーズで暗号化している場合、インポート時にそのパスフレーズの入力を求められます。

:::message
ここで入力するパスフレーズは、鍵をインポートする際に復号するためだけに使われます。1PasswordはSSH Key型アイテムに復号後の秘密鍵を保存するため、パスフレーズ自体を後から `op` コマンドで取り出すことはできません。そのため、以降の手順でもパスフレーズは不要になります。
:::

保存できたら、PC上の `rsa_key.p8` は削除してしまって構いません。

```bash
# 内容を確認できたらローカルの鍵を削除
op read "op://Development/snowflake-myproject/private key" | head -1
shred -u rsa_key.p8   # macOSの場合は rm -P rsa_key.p8
```

`op read` はデフォルトで、復号済みのPKCS#8 PEM形式（`-----BEGIN PRIVATE KEY-----`）の秘密鍵を返します。

### 2. 環境変数に参照をエクスポートする

`op://` 形式の「シークレット参照」を環境変数としてexportしておきます。シークレット参照自体には秘密情報が含まれないため、Gitにコミットしても問題ありません。

[direnv](https://direnv.net/) と組み合わせると、ディレクトリに入るだけでこの環境変数が読み込まれて便利です。

```bash:.envrc
export SNOWFLAKE_CONNECTIONS_MYPROJECT_PRIVATE_KEY_RAW=op://Development/snowflake-myproject/private key
```

`config.toml` の側は、`private_key_file` を削除します。

```toml
[connections.myproject]
account = "myorg-myaccount"
user = "MY_USER"
authenticator = "SNOWFLAKE_JWT"
```

### 3. `op run` 経由でsnowを実行する

`op run` は、現在の環境変数の中から `op://` 参照を見つけて実際の値に置き換え、子プロセスを起動します。
`--env-file` でファイルを指定しなくても、すでにexportされている環境変数が自動的にスキャン対象になります。
値は子プロセスの環境変数にのみ存在し、ディスクには書き出されません。

```bash
op run -- snow connection test -c myproject
op run -- snow sql -c myproject -q "SELECT CURRENT_USER()"
```

実行時には1Passwordのロック解除（生体認証など）を求められるため、PCが盗まれても、そのままでは鍵を使われません。

毎回 `op run ...` と打つのは面倒なので、シェルのエイリアスにしておくと便利です。

```bash
alias snow='op run -- snow'
```

:::message
`private_key_raw` が使えない古いバージョンの場合は、`op read` で一時ファイルに書き出す方法もあります。ただし、その場合はディスクに鍵が残る時間が生じるため、`private_key_raw` の利用をおすすめします。
:::

## プロジェクトごとにキーペアを切り替えるには

プロジェクトごとにSnowflakeのアカウントやユーザーが違う場合、鍵も別々に管理したくなります。
ここでは、これまでの仕組みを使った切り替え方を紹介します。

### コネクションを複数定義して `-c` で指定する

`config.toml` にコネクションを複数定義しておけば、`-c` で切り替えられます。

```toml
[connections.project_a]
account = "org-account_a"
user = "USER_A"
authenticator = "SNOWFLAKE_JWT"

[connections.project_b]
account = "org-account_b"
user = "USER_B"
authenticator = "SNOWFLAKE_JWT"
```

鍵の参照も、プロジェクトごとの `.envrc` に分けてexportしておきます。コネクション名ごとに環境変数名が異なるため、同じファイルにまとめて書くこともできます。

```bash:project_a/.envrc
export SNOWFLAKE_CONNECTIONS_PROJECT_A_PRIVATE_KEY_RAW=op://Development/snowflake-project-a/private key
```

```bash:project_b/.envrc
export SNOWFLAKE_CONNECTIONS_PROJECT_B_PRIVATE_KEY_RAW=op://Development/snowflake-project-b/private key
```

これで、各プロジェクトのディレクトリに入る（`direnv allow` 実行後）だけで環境変数が読み込まれ、次のように実行すれば、そのプロジェクト用の鍵が使われます。

```bash
cd project_a
op run -- snow sql -c project_a -q "SELECT CURRENT_ACCOUNT()"
```

### デフォルトのコネクションを切り替える

毎回 `-c` を指定したくない場合は、デフォルトのコネクションを設定します。

```bash
# config.toml のデフォルトを変更する
snow connection set-default project_a
```

プロジェクトごとに切り替えるには、環境変数 `SNOWFLAKE_DEFAULT_CONNECTION_NAME` を使うと便利です。先ほどの `.envrc` に追記しておきます。

```bash:project_a/.envrc
export SNOWFLAKE_DEFAULT_CONNECTION_NAME=project_a
export SNOWFLAKE_CONNECTIONS_PROJECT_A_PRIVATE_KEY_RAW=op://Development/snowflake-project-a/private key
```

あわせて、`alias snow='op run -- snow'` としておけば、ディレクトリに入って `snow sql -q "..."` と打つだけで、そのプロジェクトのコネクションと鍵が使われます。

### 設定ファイル自体を分ける

プロジェクトのリポジトリに設定を同梱したい場合は、`--config-file` で `config.toml` を指定する方法もあります。

```bash
op run -- snow --config-file ./config.toml sql -q "SELECT 1"
```

なお、コネクションのパラメーターには優先順位があります。**コマンドラインの引数 > 環境変数 > `config.toml`** の順に優先されます。そのため、`config.toml` には共通の設定を、環境変数には秘密情報や環境ごとの差分を、という使い分けがしやすいです。

## おわりに

本記事では、Snowflake CLIのキーペア認証の設定から、1Password CLIと連携して秘密鍵をPCに残さない方法、さらにプロジェクトごとに鍵とコネクションを切り替える方法を紹介しました。

- キーペア認証にすると、パスワードなしで接続できる
- 秘密鍵は1Passwordに保管し、`op run` で環境変数として渡せば、ディスクに残らない
- コネクション名ごとの環境変数やデフォルトコネクションの切替で、プロジェクトごとの使い分けができる

パスワードや秘密鍵ファイルの管理から解放されると、日々の作業がぐっと快適になります。ぜひお試しください。
