---
title: "毎回 op run を付けるのが面倒なので、Snowflake CLIの1Password Shell Pluginを作ってPRを出した"
emoji: "❄️"
type: "tech" # tech: 技術記事 / idea: アイデア
topics:
  - snowflake
  - 1password
  - snowflakecli
  - security
published: false
published_at: "2026-10-26 07:30"
publication_name: fusic
---

## はじめに

前回の記事では、Snowflake CLI（`snow` コマンド）のキーペア認証で使う秘密鍵を1Passwordに保管し、`op run` で必要なときだけ取り出す方法を紹介しました。

https://zenn.dev/fusic/articles/snowflake-cli-openssl-auth-1password

この方法で、秘密鍵をPCに置かずに済むようになりました。ただ、しばらく使っていると、次のような手間が気になってきます。

- `op run -- snow ...` と毎回打つか、自分でエイリアスを用意する必要がある
- `SNOWFLAKE_CONNECTIONS_<コネクション名>_PRIVATE_KEY_RAW` という長い環境変数名を、コネクションごとに `.envrc` に書く必要がある
- そのために direnv も入れておく必要がある

実は1Password CLIには、こうした「CLIに認証情報を渡す」作業を肩代わりしてくれる **Shell Plugins** という仕組みがあります。AWS CLIやGitHub CLIなど多くのCLIに対応していますが、Snowflake CLI向けのものはまだありませんでした。

そこで、Snowflake CLI用のShell Pluginを実装し、1Password公式のリポジトリにPRを出しました。

https://github.com/1Password/shell-plugins/pull/694

このプラグインを使うと、`snow` コマンドを実行したときに、次のような流れで1Passwordの認証情報が渡されます。

![](/images/snowflake-cli-1password-shell-plugin/overview.drawio.png)

本記事では、このプラグインを**利用者としてどういう手順で使うのか**を中心に紹介します。1Password CLIのShell Pluginsを触ったことがない方にも分かるよう、仕組みの説明から始めます。後半では、設計で考えたことも少しだけ紹介します。

:::message alert
2026年10月時点で、このPRはまだマージされていません。そのため、本記事の手順では、プラグインを手元でビルドして使います。マージ後は、プラグインのビルドの手順が不要になる見込みです。また、レビューの結果によって、仕様が変わる可能性があります。
:::

:::message
動作確認は Snowflake CLI 3.27.0、1Password CLI 2.39.0 で行っています。
:::

## 1Password Shell Pluginsとは

Shell Pluginsは、1Password CLI（`op`）の機能の1つです。ひとことで言うと、**CLIを実行する瞬間に、1Passwordに保管した認証情報をそのCLIに渡してくれる仕組み**です。

https://developer.1password.com/docs/cli/shell-plugins/

例えばAWS CLI用のプラグインを設定すると、`aws` コマンドは次のようなエイリアスに置き換わります。

```bash
alias aws="op plugin run -- aws"
```

この状態で `aws s3 ls` と打つと、裏では次のことが起こります。

```mermaid
sequenceDiagram
  actor U as ユーザー
  participant OP as 1Password CLI<br/>(op plugin run)
  participant APP as 1Passwordアプリ
  participant CLI as 対象のCLI<br/>(aws, snowなど)

  U->>OP: aws s3 ls
  OP->>APP: 認証情報をリクエスト
  APP->>U: Touch ID などでロック解除
  APP-->>OP: 認証情報
  OP->>CLI: 環境変数などに認証情報をセットして起動
  CLI-->>U: 実行結果
```

ポイントは次の3つです。

- **認証情報はディスクに書き出されない**：環境変数として子プロセスに渡されるだけなので、`~/.aws/credentials` のようなファイルは不要になります
- **普段通りのコマンドで使える**：エイリアスが設定されるので、`op run` などを付ける必要がありません
- **使う認証情報をディレクトリごとに切り替えられる**：「このディレクトリ以下ではこのアイテムを使う」という設定を、`op` 側で管理してくれます

前回の記事で、`op run`・エイリアス・direnvを組み合わせて自前で実現していたことを、まとめて面倒見てくれるイメージです。

対応しているCLIは、ドキュメントの一覧で確認できます。対応していないCLIでも、自分でGo言語でプラグインを書いて、手元でビルドして使えます。今回は、この仕組みを使ってSnowflake CLI用のプラグインを作りました。

### 既存の `snowflake` プラグインとの違い

実は、Shell Pluginsにはすでに `snowflake` という名前のプラグインが存在します。ただし、こちらは旧来のCLIである **SnowSQL**（`snowsql` コマンド）向けで、パスワード認証にのみ対応しています。

今回作ったのは、新しいCLIである **Snowflake CLI**（`snow` コマンド）向けの `snowflakecli` プラグインです。

| | `snowflake`（既存） | `snowflakecli`（今回のPR） |
|---|---|---|
| 対象のCLI | SnowSQL（`snowsql`） | Snowflake CLI（`snow`） |
| 認証方式 | パスワード | キーペア（`SNOWFLAKE_JWT`） |
| 設定ファイル | `~/.snowsql/config` | `config.toml` / `connections.toml` |

対象のコマンドが異なるので、2つのプラグインは同時に使っても衝突しません。

## 使い方

ここからは、実際にプラグインを使うまでの手順を紹介します。全体の流れは次の通りです。

1. 前提を準備する
2. プラグインをビルドする（PRのマージ前のみ）
3. `op plugin init snow` で認証情報を登録する
4. いつも通り `snow` コマンドを使う

### 1. 前提を準備する

次のものを用意しておきます。

- **1Passwordアプリと1Password CLI**：1Passwordアプリの「設定」→「開発者」から、「1Password CLIと連携」を有効にしておきます。これで、`op` の認証にTouch IDなどが使えるようになります
- **Snowflake CLI**
- **キーペアを登録したSnowflakeユーザーと、対応する秘密鍵（PKCS#8形式）**：作り方は前回の記事の「キーペアの生成」「キーペアの登録」を参照してください
- **Go**：PRのマージ前は、プラグインのビルドに必要です

### 2. プラグインをビルドする

PRのマージ前は、PRのブランチを手元でビルドしてインストールします。

```bash
git clone https://github.com/yuuu/shell-plugins.git
cd shell-plugins
git switch add-snowflakecli-plugin
make snowflakecli/build
```

`make snowflakecli/build` を実行すると、ビルドされたプラグインが `~/.config/op/plugins/local/` に配置されます。`op` はこのディレクトリにあるプラグインを自動的に読み込むので、インストールの作業はこれだけです。

:::message
PRがマージされ、1Password CLIのリリースに含まれれば、このビルドの手順は不要になります。
:::

### 3. `op plugin init snow` で認証情報を登録する

次に、`op plugin init` で、`snow` コマンドに使う認証情報を登録します。
このプラグインで1Passwordに保存する項目は次の通りです。

| 項目 | 必須 | 説明 |
|---|---|---|
| Account | ✅ | アカウント識別子（例：`myorg-myaccount`） |
| Username | ✅ | Snowflakeのユーザー名 |
| Private Key | ✅ | 秘密鍵（PKCS#8 PEM形式）の中身 |
| Private Key Passphrase | | 秘密鍵を暗号化している場合のパスフレーズ |
| Role / Warehouse / Database / Schema | | 接続時に使うロール・ウェアハウスなど |

これらを手で入力してもよいのですが、複数行ある秘密鍵をプロンプトに貼り付けるのは少し面倒です。
そこで、このプラグインには、**既存の設定から認証情報を読み取って1Passwordに取り込む機能**（インポーター）を用意しました。取り込み元として、次の2つに対応しています。

#### パターンA：環境変数と鍵ファイルから取り込む

秘密鍵のファイルが手元にある場合は、環境変数でアカウントやユーザー名、鍵ファイルのパスを指定して `op plugin init snow` を実行します。

```bash
SNOWFLAKE_ACCOUNT=myorg-myaccount \
SNOWFLAKE_USER=MY_USER \
SNOWFLAKE_PRIVATE_KEY_FILE=./rsa_key.p8 \
op plugin init snow
```

`SNOWFLAKE_PRIVATE_KEY_FILE` で指定したファイルの中身が、Private Keyの項目として読み込まれます。
同様に、`SNOWFLAKE_ROLE` や `SNOWFLAKE_WAREHOUSE`、`PRIVATE_KEY_PASSPHRASE` を指定しておけば、それらも一緒に取り込まれます。

#### パターンB：`config.toml` / `connections.toml` から取り込む

すでにSnowflake CLIで、キーペア認証のコネクションを設定している場合は、何も指定せずに `op plugin init snow` を実行するだけで構いません。

```bash
op plugin init snow
```

次の場所にある `config.toml` / `connections.toml` から、`authenticator = "SNOWFLAKE_JWT"` のコネクションが取り込みの候補として表示されます。
`private_key_file` で鍵ファイルを指定している場合は、そのファイルも読み込まれます。

- `~/.snowflake/`
- `~/Library/Application Support/snowflake/`（macOS）
- `~/.config/snowflake/`（Linux）

パスワード認証など、キーペア認証以外のコネクションは候補に出てきません。

#### 取り込む

`op plugin init snow` を実行すると、まず認証情報をどこから用意するかを聞かれます。
「Import into 1Password...」を選ぶと、上記の環境変数や設定ファイルから見つかった候補が表示されるので、取り込みたいものを選びます。保存先のVaultとアイテム名を指定すると、1Passwordに新しいアイテムが作られます。

すでに1Passwordにアイテムを作ってある場合は、「Search in 1Password...」から既存のアイテムを選ぶこともできます。

<!-- TODO: op plugin init snow の実行画面のスクリーンショット -->

取り込みが終わったら、手元の秘密鍵ファイルは削除して構いません。

```bash
shred -u rsa_key.p8   # macOSの場合は rm -P rsa_key.p8
```

#### 使う範囲を選ぶ

続いて、登録した認証情報を**どの範囲で使うか**を聞かれます。選択肢は次の3つです。

| 選択肢 | 意味 |
|---|---|
| Prompt me for each new terminal session | ターミナルのセッションごとに、使うアイテムを都度選ぶ |
| Use automatically when in this directory or subdirectories | 今いるディレクトリとその配下では、このアイテムを自動で使う |
| Use as global default on my system | どこにいても、このアイテムを使う |

使うSnowflakeアカウントが1つだけなら、「Use as global default on my system」を選ぶのが手軽です。
プロジェクトごとにアカウントやユーザーを分けたい場合は、「Use automatically when in this directory or subdirectories」を使います（後述）。

#### エイリアスを読み込む

最後に、シェルの設定ファイルに `plugins.sh` を読み込む設定を追加するよう案内されます。案内に従って、例えばbashなら次のように追記します。

```bash
echo "source ~/.config/op/plugins.sh" >> ~/.bashrc && source ~/.bashrc
```

`~/.config/op/plugins.sh` の中身を見ると、`snow` コマンドが `op plugin run` 経由で実行されるよう設定されていることが分かります。

```bash:~/.config/op/plugins.sh
export OP_PLUGIN_ALIASES_SOURCED=1
snow() {
    op plugin run -- snow "$@"
}
```

これで準備は完了です。

### 4. いつも通り `snow` コマンドを使う

あとは、普段通りに `snow` コマンドを実行するだけです。

```bash
snow connection test
snow sql -q "SELECT CURRENT_USER()"
```

初回は、1Passwordのロック解除（Touch IDなど）を求められます。ロックを解除すると、1Passwordに保管した秘密鍵で認証され、コマンドが実行されます。

前回の記事の方法と比べると、次の点が変わりました。

- `op run --` を付けなくてよい
- `-c` でコネクション名を指定しなくてよい
- `.envrc` に `op://` の参照を書かなくてよい
- `config.toml` にコネクションを定義しておく必要もない

:::message
このプラグインは、Snowflake CLIの設定ファイル（`config.toml` など）を使わず、1Passwordのアイテムの内容だけで接続します。そのため、ロールやウェアハウスを指定したい場合は、アイテムのRole・Warehouseの項目に設定しておくか、`--role` などのオプションで都度指定してください。
:::

## プロジェクトごとに認証情報を切り替える

前回の記事では、プロジェクトごとの `.envrc` に環境変数を書き分けて、コネクションを切り替えていました。
Shell Pluginsでは、この切り替えを `op` が管理してくれます。

例えば、プロジェクトAとプロジェクトBで、別のSnowflakeアカウントを使うとします。それぞれのディレクトリで `op plugin init snow` を実行し、使う範囲として「Use automatically when in this directory or subdirectories」を選びます。

```bash
cd ~/work/project_a
op plugin init snow   # プロジェクトA用のアイテムを選び、ディレクトリに紐付ける

cd ~/work/project_b
op plugin init snow   # プロジェクトB用のアイテムを選び、ディレクトリに紐付ける
```

これで、各ディレクトリで `snow` を実行するだけで、そのプロジェクト用の鍵とアカウントが使われます。

```bash
cd ~/work/project_a
snow sql -q "SELECT CURRENT_ACCOUNT()"   # プロジェクトAのアカウントで実行される
```

どのディレクトリにどのアイテムが紐付いているかは、`op plugin inspect` で確認できます。設定をやり直したいときは `op plugin clear` を使います。

```bash
op plugin inspect snow   # 今の設定を確認する
op plugin clear snow     # 今いるディレクトリの設定を削除する
```

紐付けの情報は `op` が管理するので、リポジトリに `.envrc` を置く必要もありません。

## 既存の設定と共存させる

プラグインを入れたあとも、これまで通り `config.toml` のコネクションを使いたい場面はあると思います。そこで、次のように**接続先を明示した場合は、プラグインは何もしない**ようにしています。

```bash
snow sql -c myproject -q "SELECT 1"            # -c / --connection でコネクションを指定
snow sql -x --account ... -q "SELECT 1"        # -x / --temporary-connection を指定
snow --config-file ./config.toml sql -q "..."  # --config-file で設定ファイルを指定
```

また、`snow connection list` や `snow init`、`snow helpers` のように、Snowflakeに接続しないコマンドでは、1Passwordのロック解除を求められません。`--help` や `--version` も同様です。

## 設計の話

最後に、プラグインを作るときに考えたことを少しだけ紹介します。

### 認証情報は環境変数で渡し、`-x` を付け足す

Shell Pluginsでは、認証情報をCLIに渡す方法として、主に「環境変数で渡す」か「一時ファイルを作って渡す」かを選べます。
今回のプラグインでは、次のような環境変数を設定したうえで、コマンドの末尾に `-x`（`--temporary-connection`）を付け足すようにしました。

```bash
# 例えば snow sql -q "SELECT 1" と打つと、実際には次のように実行される
SNOWFLAKE_ACCOUNT=myorg-myaccount \
SNOWFLAKE_USER=MY_USER \
SNOWFLAKE_AUTHENTICATOR=SNOWFLAKE_JWT \
SNOWFLAKE_PRIVATE_KEY_RAW='-----BEGIN PRIVATE KEY-----...' \
snow sql -q "SELECT 1" -x
```

`-x` を付けている理由は2つあります。

1つ目は、`snow` が、コネクション名の指定か `-x` のどちらかがないと動かないためです。`config.toml` にデフォルトのコネクションがない環境では、環境変数だけを渡してもエラーになります。

2つ目は、パラメーターの優先順位です。`SNOWFLAKE_ACCOUNT` のような汎用の環境変数は、ユーザーの `config.toml` に書かれた値よりも優先度が低くなっています。そのため、`-x` を付けずに実行すると、ユーザーの設定ファイルの値が混ざってしまう可能性があります。`-x` を付けることで、設定ファイルを読まずに、1Passwordの内容だけで接続できるようにしています。

ちなみに、最初は一時ファイルとして `config.toml` を作り、`--config-file` で渡す方法も試しました。しかし、Shell Pluginsが作る一時ファイルは一度しか読めないのに対し、`snow` は実行中に設定ファイルを何度か開くため、読み込みの途中で止まってしまいました。秘密鍵をディスクに書き出さずに済むという点でも、環境変数で渡す方式の方が良いと判断しました。

### 秘密鍵の改行を復元する

1Passwordに秘密鍵を手で貼り付けると、PEMの改行が失われ、スペースや `\n` という文字列に置き換わってしまうことがあります。そのままでは `snow` が鍵として読み込めません。

そこで、実行時に秘密鍵の形を確認し、改行が失われていれば、正しいPEM形式に戻してから渡すようにしています。インポーターを使えばこの問題は起こりませんが、手で登録した場合でも動くようにしておきたかったためです。

### プラグイン名は `snowflakecli`

プラグイン名は、Goのパッケージ名と一致させる必要があり、ハイフンを含められません。そこで、`snowflake-cli` ではなく `snowflakecli` としました。既存の `snowflake` プラグインと名前が衝突しないようにする意味もあります。

## おわりに

本記事では、Snowflake CLI用に作った1Password Shell Pluginの使い方を紹介しました。

- Shell Pluginsを使うと、1Passwordに保管した秘密鍵で、普段通りに `snow` コマンドを実行できる
- `op plugin init snow` で、既存の鍵ファイルや `config.toml` から認証情報を取り込める
- ディレクトリごとに使う認証情報を切り替えられるので、`.envrc` や direnv が不要になる
- `-c` などで接続先を明示すれば、これまで通りの設定ファイルも使える

前回の記事で自前で組み立てていた仕組みが、`op plugin init` 1回で済むようになりました。
PRはまだマージされていませんが、マージされればビルドの手順も不要になります。キーペア認証でSnowflake CLIを使っている方は、ぜひ試してみてください。

## 参考文献

- [1Password Shell Plugins | 1Password Developer](https://developer.1password.com/docs/cli/shell-plugins/)
- [Build your own shell plugins | 1Password Developer](https://developer.1password.com/docs/cli/shell-plugins/contribute/)
- [1Password/shell-plugins | GitHub](https://github.com/1Password/shell-plugins)
- [Add Snowflake CLI (snow) plugin with key pair authentication #694 | GitHub](https://github.com/1Password/shell-plugins/pull/694)
- [Snowflake CLI の接続を構成する | Snowflake Documentation](https://docs.snowflake.com/ja/developer-guide/snowflake-cli/connecting/configure-connections)
- [キーペア認証とキーペアローテーション | Snowflake Documentation](https://docs.snowflake.com/ja/user-guide/key-pair-auth)
