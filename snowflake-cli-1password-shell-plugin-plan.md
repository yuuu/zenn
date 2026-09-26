# Snowflake CLIの認証情報を1Password Shell Pluginで管理する 検証手順

記事: `articles/snowflake-cli-1password-shell-plugin.md`（雛形作成済み）

## 方向性の結論（調査結果）

- [1Password/shell-plugins](https://github.com/1Password/shell-plugins) には既に `plugins/snowflake` というプラグインが存在するが、これは **レガシーなSnowSQL (`snowsql` コマンド)専用**で、`SNOWSQL_ACCOUNT` / `SNOWSQL_USER` / `SNOWSQL_PWD` という環境変数にアカウント・ユーザー名・パスワードを注入するだけのもの（パスワード認証のみ、キーペア認証は非対応）。セットアップコマンドも `op plugin init snowsql` であり、モダンな Snowflake CLI (`snow`)向けではない。
  - 参照: https://github.com/1Password/shell-plugins/tree/main/plugins/snowflake, https://www.1password.dev/cli/shell-plugins/snowflake
- SnowSQLはレガシークライアント（サポートは2028-04-16まで継続予定だが新機能は`snow`にしか入らない）で、Snowflakeは新規プロジェクトでは`snow`の使用を推奨している。
  - 参照: https://docs.snowflake.com/en/user-guide/snowsql, https://docs.snowflake.com/en/user-guide/snowsql-migrate
- 一方、`snow`自体は環境変数からの認証情報の受け取りに対応している（`SNOWFLAKE_ACCOUNT` / `SNOWFLAKE_USER` / `SNOWFLAKE_PASSWORD`、キーペア認証なら`SNOWFLAKE_PRIVATE_KEY_RAW`、コネクション名を指定した `SNOWFLAKE_CONNECTIONS_<NAME>_PASSWORD` 等）。1Password Shell Pluginは「対象CLI実行前に環境変数へ動的に認証情報を注入する」仕組みなので、`snow`とは相性が良いはず。
  - 参照: https://docs.snowflake.com/en/developer-guide/snowflake-cli/connecting/configure-connections
- したがって **「`snow`用の1Password Shell Pluginは存在しないので自作する」** を記事の軸にする。既存記事[snowflake-cli-oauth.md](articles/snowflake-cli-oauth.md)がOAuth認証を扱っているため、今回は差別化としてパスワード認証（＋発展としてキーペア認証）にフォーカスする。
- 比較のため、プラグインを自作しない場合の簡易な方法（`op run`, `op inject`）にも触れるが、メインコンテンツはプラグイン自作とする。
- **自作するからには、ローカルで動かして終わりにせず、本家[1Password/shell-plugins](https://github.com/1Password/shell-plugins)へのPull Requestを出すことを前提に進める。** [CONTRIBUTING.md](https://github.com/1Password/shell-plugins/blob/main/CONTRIBUTING.md)によれば、現在のShell Pluginsのスコープは「認証が必要なプラットフォームのCLI（SaaS、クラウドベンダー、**データベース**など）」であり、Snowflake CLIはデータベースのCLIとしてこのスコープに合致する。非公式CLIや複数プラットフォームに認証するCLI（terraform等）は採用されにくいとされているが、`snow`はSnowflakeという単一プラットフォーム専用の公式CLIなのでこの点も問題ない。

**コントリビュートにあたっての制約（CONTRIBUTING.mdより）**:
- サードパーティ依存の追加は極力避ける（依存を増やすPRはレビューが長引く・却下されやすい）。`config.toml`（TOML形式）のインポーター実装でTOMLパースライブラリの追加が必要になりそうな場合、依存追加してまで実装するか、インポーター機能自体を見送るかを判断する。
- コミット署名が必須（`git commit -S`、1PasswordのSSHキーでの署名設定が[ドキュメント化されている](https://developer.1password.com/docs/ssh/git-commit-signing)）。
- テストは`sdk/plugintest`パッケージのヘルパーを使い、`make <plugin>/example-secrets`で生成したテストフィクスチャを使う。
- ドキュメント執筆は不要（採用されれば1Password側のテクニカルライターが書く）。ただしPR本文に「認証が必要な実行例コマンド」を書いておくと、先方のテスト・スクリーンショット作成に使ってもらえる。
- Shell Plugins自体がまだベータ版であり、レビューに時間がかかる／要修正を求められる可能性がある点は記事内でも正直に触れる。

**目指す最終体験**: [こちらのAWS CLI/CDKの記事](https://dev.classmethod.jp/articles/1password-shell-plugins-aws-cli-cdk/)のように、プラグインさえ用意してしまえば普段は`aws ...`と同じ感覚で`snow ...`と打つだけで、裏で1Passwordの生体認証（Touch ID等）が挟まり認証情報が注入される、という体験をゴールにする。具体的には以下を必ず記事・手順に含める。

- `op plugin init snow`実行後に`~/.config/op/plugins.sh`（または同等のファイル）に`alias snow="op plugin run -- snow"`が書き込まれることの確認
- そのファイルを`.zshrc`/`.bashrc`（または`fish`の場合は`config.fish`）に`source`する設定を行い、新しいターミナルセッションで`snow`と打つだけでプラグイン経由になることの確認
- 認証タイミング（毎回のターミナルセッションで確認する／毎回のコマンド実行で確認する等）をどう設定したか
- Shell Pluginを一時的に無効化する方法（本物の`snow`バイナリを直接叩きたい場合の対処）

`{ }` で囲った値は各自の環境・アカウントの値に読み替える。まだ何も実行していないため、本ファイルの手順・コード片は**1Password Shell Pluginsの開発者向けドキュメント調査に基づく想定手順**であり、実際に`make new-plugin`等を実行した結果ではない。実機検証で細部（生成されるファイル名・SDKの正確な型名など）が変わる可能性が高い。

## 0. 前提確認

```sh
# 1Password CLIがインストール・ログイン済みであることを確認
op --version
op vault list

# 開発に必要なツール
go version   # 1.18以上が必要
git --version
make --version

# Snowflake CLI側
snow --version
snow connection list
```

:::message
Snowflake側は、パスワード認証で作成済みのテスト用コネクション（例: `pwtest`）が最低1つ必要。
`snowflake-cli-oauth.md`はOAuth前提だったため、今回は別途パスワード認証ユーザーを用意するか、既存ユーザーにパスワードを設定して検証する。
**実機検証で確定させる**: 検証用にSnowflake側でどのユーザー・ロールを使うか。
:::

## 1. 1Password/shell-plugins リポジトリをフォーク・クローンする

```sh
gh repo fork 1Password/shell-plugins --clone
cd shell-plugins
git checkout -b add-snowflake-cli-plugin
```

確認:

```sh
ls plugins | grep -i snow
# => snowflake （既存のSnowSQL用プラグイン。今回はこれとは別に新しいプラグインを追加する）
```

PRを出す前提なので、コミット署名を有効にしておく（[1Passwordのドキュメント](https://developer.1password.com/docs/ssh/git-commit-signing)に沿って1PasswordのSSHキーで署名する場合）。

```sh
git config commit.gpgsign true
git config gpg.format ssh
git config user.signingkey "{1Password SSH Agentに登録済みの公開鍵、またはそのパス}"
```

:::message
署名鍵をSSH Agent方式(1Password SSH Agent)にするかGPGにするかは環境に合わせて選ぶ。**実機検証で確定させる項目**（1Password SSH Agentが有効化済みか、既に他のGit運用で署名方式が決まっていないか）。
:::

## 2. プラグインの雛形を生成する

```sh
make new-plugin
```

対話プロンプトで以下のように入力する想定:

| プロンプト | 入力値（想定） |
| --- | --- |
| Plugin name | `snowflakecli`（または`snowflake-cli`） |
| Platform display name | `Snowflake CLI` |
| Credential name | `Password` |
| Executable name | `snow` |

:::message
プラグイン名は既存の`snowflake`ディレクトリと衝突しないよう別名にする必要がある。ハイフンを含む名前が許容されるか、Goのパッケージ名として問題ないか（`snowflake-cli`は不可でGoパッケージ名的に`snowflakecli`にせざるを得ないかもしれない）は`make new-plugin`を実際に実行して確定させる。
**実機検証で確定させる項目。**
:::

生成されるディレクトリ構成を確認する:

```sh
ls plugins/snowflakecli/
# 想定: plugin.go, password.go（クレデンシャル定義）, snow.go（実行ファイル定義）, snowflakecli_test.go, test-fixtures/ など
```

## 3. `plugin.go` を実装する

既存プラグイン（[aws/plugin.go](https://github.com/1Password/shell-plugins/blob/main/plugins/aws/plugin.go)、[github/plugin.go](https://github.com/1Password/shell-plugins/blob/main/plugins/github/plugin.go)）の構成を参考に実装する。

```go
package snowflakecli

import "github.com/1Password/shell-plugins/sdk"

func New() sdk.Plugin {
	return sdk.Plugin{
		Name:        "snowflakecli",
		Platform: sdk.PlatformInfo{
			Name:     "Snowflake CLI",
			Homepage: sdk.URL("https://docs.snowflake.com/en/developer-guide/snowflake-cli/index"),
		},
		Credentials: []sdk.CredentialType{
			SnowflakePassword(),
		},
		Executables: []sdk.Executable{
			SnowCLI(),
		},
	}
}
```

:::message
`sdk.Plugin` / `sdk.PlatformInfo` 等の正確な型名・フィールド名は`make new-plugin`が生成する雛形のTODOコメントとSDKのgodoc ( https://pkg.go.dev/github.com/1Password/shell-plugins ) を見て確定させる。上記コードは構成のイメージであり、そのままコンパイルできる保証はない。
**実機検証で確定させる項目。**
:::

## 4. クレデンシャル定義（`password.go`）を実装する

Fields: `Account`（非シークレット）, `Username`（非シークレット）, `Password`（シークレット）。
Provisionerは`EnvVarProvisioner`を使い、`snow`が読む一般環境変数にマッピングする。

```go
package snowflakecli

import (
	"github.com/1Password/shell-plugins/sdk"
	"github.com/1Password/shell-plugins/sdk/schema"
	"github.com/1Password/shell-plugins/sdk/schema/fieldname"
)

func SnowflakePassword() sdk.CredentialType {
	return sdk.CredentialType{
		Name:          "password",
		DocsURL:       sdk.URL("https://docs.snowflake.com/en/developer-guide/snowflake-cli/connecting/configure-connections"),
		ManagementURL: sdk.URL("https://docs.snowflake.com/en/user-guide/admin-user-management"),
		Fields: []sdk.CredentialField{
			{
				Name:                fieldname.Account,
				MarkdownDescription: "Snowflakeのアカウント識別子（例: `xxxxxxx-xxxxxxx`）。",
			},
			{
				Name:                fieldname.Username,
				MarkdownDescription: "Snowflakeのユーザー名。",
			},
			{
				Name:                fieldname.Password,
				MarkdownDescription: "Snowflakeのパスワード。",
				Secret:              true,
			},
		},
		Provisioner: provision.EnvVars(map[string]sdk.FieldName{
			"SNOWFLAKE_ACCOUNT":  fieldname.Account,
			"SNOWFLAKE_USER":     fieldname.Username,
			"SNOWFLAKE_PASSWORD": fieldname.Password,
		}),
		Importer: importer.TryAll(
			// ~/.snowflake/config.toml の [connections.*] を読み取ってインポート候補にする
			// TOMLパーサーが必要になるため、既存プラグインのINI用ヘルパーがそのまま使えるかは要検証
		),
	}
}
```

:::message
- `~/.snowflake/config.toml`はTOML形式であり、SDKの`importer`ヘルパーがINI（`snowsql`用）ほど手厚くTOMLに対応しているかは未確認。もしSDK標準のヘルパーだけで対応できず外部TOMLパースライブラリの追加が必要になる場合、**CONTRIBUTING.mdの「サードパーティ依存を極力避ける」方針に反する**ため、その場合はインポーター機能自体を見送り（`Importer`を省略し、`op plugin init`で毎回手入力する形に割り切る）、記事にもその判断理由を書く。**実機検証で確定させる項目。**
- `SNOWFLAKE_PASSWORD`（汎用環境変数）と`SNOWFLAKE_CONNECTIONS_<接続名>_PASSWORD`（接続名指定）のどちらを使うべきかも検討点。プラグインのFieldは静的な環境変数名しか持てないため、接続名を動的に埋め込む`SNOWFLAKE_CONNECTIONS_<NAME>_PASSWORD`方式はプラグインの仕組みと相性が悪い。汎用の`SNOWFLAKE_ACCOUNT`/`SNOWFLAKE_USER`/`SNOWFLAKE_PASSWORD`を使う方針とするが、**`config.toml`に同名の値が設定済みだと優先順位的に上書きされてしまう**（`config.toml` > 汎用環境変数）ため、検証時は`config.toml`にパスワードを書かない状態で試す必要がある。
**いずれも実機検証で確定させる項目。**
:::

## 5. 実行ファイル定義（`snow.go`）を実装する

```go
package snowflakecli

import (
	"github.com/1Password/shell-plugins/sdk"
	"github.com/1Password/shell-plugins/sdk/schema"
)

func SnowCLI() sdk.Executable {
	return sdk.Executable{
		Name:    "Snowflake CLI",
		Runs:    []string{"snow"},
		DocsURL: sdk.URL("https://docs.snowflake.com/en/developer-guide/snowflake-cli/index"),
		NeedsAuth: schema.CommandNeedsAuth(
			// --help / --version、および認証情報を明示的に渡している場合はプラグインの注入は不要
			schema.NotWhenContainsArgs("-h", "--help", "--version"),
		),
		Uses: []sdk.CredentialUsage{
			{
				Name:              "password",
				Requirement:       sdk.Required,
			},
		},
	}
}
```

:::message
`NeedsAuth`の実装イメージは既存の`snowsql`プラグイン（`-a`/`--accountname`/`-u`/`--username`/`--authenticator`/`--config`指定時はプラグイン注入をスキップ）を参考にしたが、`snow`のフラグ体系（`--connection`/`-c`、`--account`、`--user`など）に合わせて調整が必要。また`snow connection add`のように認証情報を新規登録するサブコマンドでは注入がむしろ邪魔になる可能性がある。
**実機検証で確定させる項目。**
:::

## 6. スキーマの検証・テスト・ローカルビルド

```sh
make snowflakecli/validate
make snowflakecli/example-secrets
make snowflakecli/build
```

確認:

```sh
ls ~/.op/plugins/local
op plugin list | grep -i snowflake
```

PRを出す前提なので、`sdk/plugintest`パッケージのヘルパーを使ったテストコード（`snowflakecli_test.go`、雛形は`make new-plugin`で自動生成済み）を実装し、`make snowflakecli/example-secrets`の出力をテストフィクスチャとして使う。

```sh
make snowflakecli/test
```

:::message
`plugintest`パッケージの具体的なAPI（テストケースの書き方）は既存プラグイン（例: [`plugins/github/github_test.go`](https://github.com/1Password/shell-plugins/blob/main/plugins/github/github_test.go)）を参照して確定させる。**実機検証で確定させる項目。**
:::

## 7. 1Passwordにログイン情報を登録してプラグインを有効化する

```sh
op plugin init snow
```

対話フローで「1Passwordの既存アイテムを使う」か「新規アイテムを作る」かを選べるはず。今回は検証用に新規アイテムを作成し、Snowflakeのテストアカウント（アカウント識別子・ユーザー名・パスワード）を入力する。

:::message
本手順は実際のSnowflakeアカウント（テスト用ユーザー・パスワード）を用意しないと検証できない。この環境には認証情報がないため未実施。
**実機検証で確定させる項目（プロンプトの正確な文言・生成される`~/.config/op/plugins.sh`へのエイリアス内容）。**
:::

## 8. Snowflake CLIから実際に接続して動作確認する

```sh
# op plugin initで有効化したシェルの場合、`snow`実行時に自動でop plugin runが挟まる想定
snow sql -q "SELECT CURRENT_USER(), CURRENT_ACCOUNT();"

# 明示的にワンショットで確認する場合
op plugin run -- snow sql -q "SELECT CURRENT_USER(), CURRENT_ACCOUNT();"
```

確認する観点:

1. 生SNOWFLAKE_PASSWORDがシェル履歴・環境変数に残らないこと（`env | grep SNOWFLAKE`を認証後に確認し、コマンド終了後にクリアされているか）
2. `~/.snowflake/config.toml`にパスワードを書かなくても接続できること
3. 1Passwordアプリの生体認証プロンプトが表示され、承認しないと接続できないこと

```sh
env | grep SNOWFLAKE
```

## 9. (発展) キーペア認証にも対応させる

時間が許せば、2つ目のCredentialType（`keypair`）を追加し、`PrivateKey`（複数行テキスト、シークレット）フィールドを`SNOWFLAKE_PRIVATE_KEY_RAW`にマッピングする案を検証する。

```go
Provisioner: provision.EnvVars(map[string]sdk.FieldName{
	"SNOWFLAKE_ACCOUNT":         fieldname.Account,
	"SNOWFLAKE_USER":            fieldname.Username,
	"SNOWFLAKE_PRIVATE_KEY_RAW": fieldname.PrivateKey,
})
```

:::message
- 秘密鍵（PEM形式、複数行）を1Passwordのフィールドとして保存する場合の項目タイプ（「シークレットノート」的な複数行対応フィールドが必要か）を確認する必要がある。
- `SNOWFLAKE_PRIVATE_KEY_RAW`と`SNOWFLAKE_PRIVATE_KEY_FILE`は同時に設定すると`snow`公式ドキュメント上NGとされている。既存の`config.toml`に`private_key_file`が書かれている環境だと衝突する可能性がある。
- 時間の都合でこの発展部分は記事に含めない可能性がある。**採用するかも含めて実機検証で確定させる。**
:::

## 10. (比較) プラグインを使わない簡易な方法

記事内で「プラグインを自作するほどではない場合の代替案」として紹介する候補。実際に試して比較する。

```sh
# op run: op://参照を環境変数に展開してsnowを実行
op run --env-file=./snowflake.env -- snow sql -q "SELECT CURRENT_USER();"
```

`snowflake.env`（1Passwordのop://参照を記載するテンプレート）:

```
SNOWFLAKE_ACCOUNT=op://{vault名}/{item名}/account
SNOWFLAKE_USER=op://{vault名}/{item名}/username
SNOWFLAKE_PASSWORD=op://{vault名}/{item名}/password
```

```sh
# op inject: config.tomlのテンプレートを展開する場合
op inject -i config.toml.tpl -o ~/.snowflake/config.toml
```

:::message
`op run`方式は1Password Shell Pluginのような「対象コマンドの実行を検知して自動的に認証情報を注入する」仕組みではなく、毎回コマンドの前に`op run --`を付ける必要がある点がプラグイン方式との違い。この体験差を実際に両方試して記事内で比較する。
また1Password SSH Agentとキーペア認証の組み合わせについては、SSH Agentが扱うのはSSH鍵形式であり、Snowflakeのキーペア認証はPKCS8形式のRSA秘密鍵ファイルを直接読む方式のため、SSH Agent経由でそのまま流用できるかは不明。**実機検証で確定させる項目（あるいは記事では非対応と明記する）。**
:::

## 11. Pull Requestを作成する

手順6のテスト・ビルドが通ったら、本家へPRを出す。

```sh
git add plugins/snowflakecli
git commit -S -m "Add Snowflake CLI shell plugin"
git push -u origin add-snowflake-cli-plugin

gh pr create \
  --repo 1Password/shell-plugins \
  --title "Add Snowflake CLI shell plugin" \
  --body "$(cat <<'EOF'
## Summary
- Adds a shell plugin for the Snowflake CLI (`snow`), which currently has no plugin (only the legacy `snowsql` CLI is supported).
- Supports password authentication via `SNOWFLAKE_ACCOUNT` / `SNOWFLAKE_USER` / `SNOWFLAKE_PASSWORD`.

## Example command that requires authentication
snow sql -q "SELECT CURRENT_USER();"
EOF
)"
```

:::message
- CONTRIBUTING.mdの指示通り、PR本文に「認証が必要な実行例コマンド」を含めた（1Password側のテスト・スクリーンショット作成用）。
- Shell Pluginsはベータ版のためレビューに時間がかかったり、実装の手直しを求められる可能性がある。**実機検証（PRを実際に出してからのやり取り）で確定させる項目。** 記事執筆時点でPRがマージされていない場合は、その旨と「レビュー中」であることを正直に書く。
:::

## 12. クリーンアップ

PRは開いたままにする（フォーク・ブランチは削除しない）。ローカル環境の検証用リソースのみ後片付けする。

```sh
# ローカルビルドしたプラグインを削除
make snowflakecli/remove-local

# op plugin initで作成したエイリアス・設定を削除
op plugin init snow --uninstall 2>/dev/null || true
# 上記コマンドが存在しない場合、~/.config/op/plugins.sh を直接編集して該当行を削除する

# 1Passwordに作成した検証用アイテムを削除
op item delete "{検証用に作成したアイテム名}" --vault {vault名}
```

:::message
`op plugin init <cmd> --uninstall`のようなアンインストール専用コマンドが実在するかは未確認。存在しない場合は`~/.config/op/plugins.sh`を直接確認して該当のalias/exportを手動削除する。**実機検証で確定させる項目。**
:::

Snowflake側で検証用にパスワードを設定したユーザーがいる場合、検証後にパスワードをリセット/無効化しておく。

## 13. 記事執筆

- [ ] `articles/snowflake-cli-1password-shell-plugin.md`の各セクションを実際の実行結果・つまずいた点で埋める
- [ ] 最終的にプラグインをどこまで作り込んだか（パスワード認証のみか、キーペア認証も含めるか）に応じてタイトル・目次を調整する
- [ ] 手順11で出したPRへのリンクを記事に追記する。公開時点でマージ済みか、レビュー中かの状態も明記する
- [ ] `SNOWFLAKE_PASSWORD`と`config.toml`の優先順位でハマった場合、その顛末を記事に書く（読者にとって一番価値のある「ハマりどころ」になりうる）
- [ ] `snowflake-cli-oauth.md`との違い（OAuth vs パスワード/キーペア認証、かつ「認証情報そのものをどう安全に扱うか」という切り口の違い）を「はじめに」で明記する
- [ ] `published: true`にして公開日を設定する
- [ ] 本ファイル（`snowflake-cli-1password-shell-plugin-plan.md`）は記事完成後に削除する
