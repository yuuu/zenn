# Snowflake CLIの認証情報を1Password Shell Pluginで管理する 検証手順

記事: `articles/snowflake-cli-1password-shell-plugin.md`（雛形作成済み）

## 方針転換: 新規プラグインの自作 → 既存プラグイン(`plugins/snowflake`)の拡張

最初の調査では「`snow`（モダンなSnowflake CLI）用のプラグインは存在しないので、新規プラグイン(`snowflakecli`)を自作する」という方針を立てていた。
しかし、既存の[`plugins/snowflake`](https://github.com/1Password/shell-plugins/tree/main/plugins/snowflake)（`snowsql`専用・パスワード認証のみ）のソースコードと、SDK内部（`sdk/schema/executable.go`, `sdk/provisioner.go`, `sdk/provision/*.go`）を実際に読んだ結果、**新規プラグインを一から作るより、この既存プラグインを拡張する方が小さく確実なPRになる**と判断し、方針を転換する。

拡張する内容は次の2点:

1. **キーペア認証用の`CredentialType`を追加する**（今回の発端になった質問）
2. **`snow`（モダンなCLI）を2つ目の`Executable`として追加する**（前回までの計画の目的）

この2つは同じプラグインパッケージ内で自然に両立できる。以下、その根拠を示す。

### 既存コードの確認結果

- `plugins/snowflake/plugin.go`: `Credentials: []schema.CredentialType{LoginDetails()}`, `Executables: []schema.Executable{SnowflakeCLI()}` という構成。1プラグインが複数の`CredentialType`・複数の`Executable`を持てることは構造上明らか。
- `plugins/snowflake/login_details.go`: `Account`/`Username`/`Password`の3フィールドを`provision.EnvVars`で`SNOWSQL_ACCOUNT`/`SNOWSQL_USER`/`SNOWSQL_PWD`にマッピングしているだけのシンプルな実装。
- `plugins/snowflake/snowsql.go`: `Runs: []string{"snowsql"}`。`Uses: []schema.CredentialUsage{{Name: credname.LoginDetails}}`。
- `sdk/schema/executable.go`（`CredentialUsage`構造体）: `Provisioner`フィールドで**Executableごとに`DefaultProvisioner`を上書きできる**（コメント: "Overrides the DefaultProvisioner ... should only be used if this executable requires a custom configuration"）。実際に[`plugins/npm/npm.go`](https://github.com/1Password/shell-plugins/blob/main/plugins/npm/npm.go)で`executable.Uses[0].Provisioner = pnpmProvisioner()`として、npmとpnpmという2つの`Executable`が同じ`CredentialType`を別々の環境変数名にマッピングしている実例がある。→ `snowsql`用は`SNOWSQL_*`、`snow`用は`SNOWFLAKE_*`という異なる環境変数名へのマッピングも、この仕組みでそのまま実現できる。
- `sdk/provisioner.go`（`ProvisionOutput`）: `AddEnvVar` / `AddArgs` / `AddSecretFile`が公開APIとして提供されている。つまり「一部フィールドは環境変数、一部フィールドはファイル」という**混在した独自Provisioner**を1つの`Provision()`関数の中で自由に書ける。
- `sdk/provision/file_provisioner.go`（`provision.TempFile`）: シークレットを一時ファイルに書き出し、`AddArgs("--xxx", "{{ .Path }}")`でコマンドライン引数にそのパスを渡す、という既製のヘルパーが既に存在する。

### 認証方式ごとの受け渡し方法の違い（要確認だが公式ドキュメントで確認済みの範囲）

| CLI | パスワード認証 | キーペア認証 |
| --- | --- | --- |
| `snowsql`（レガシー） | 環境変数 `SNOWSQL_ACCOUNT`/`SNOWSQL_USER`/`SNOWSQL_PWD` | 秘密鍵は**ファイルパスのみ**受け付ける（`--private-key-path`引数 or configの`private_key_path`）。環境変数はパスフレーズ用の`SNOWSQL_PRIVATE_KEY_PASSPHRASE`のみで、鍵の内容やパス自体を渡す環境変数は無い（[参照](https://docs.snowflake.com/en/user-guide/snowsql-start)）。 |
| `snow`（モダン） | 環境変数 `SNOWFLAKE_ACCOUNT`/`SNOWFLAKE_USER`/`SNOWFLAKE_PASSWORD` | 秘密鍵の**中身を直接**環境変数`SNOWFLAKE_PRIVATE_KEY_RAW`に渡せる（ファイルパス版の`SNOWFLAKE_PRIVATE_KEY_FILE`/`SNOWFLAKE_PRIVATE_KEY_PATH`もあるが`RAW`と併用不可）。パスフレーズは`PRIVATE_KEY_PASSPHRASE`系の環境変数（正確な変数名・プレフィックスの有無は実機で確認する）（[参照](https://docs.snowflake.com/en/developer-guide/snowflake-cli/connecting/configure-connections)）。 |

:::message
`snow`のパスフレーズ用環境変数が`PRIVATE_KEY_PASSPHRASE`なのか`SNOWFLAKE_PRIVATE_KEY_PASSPHRASE`なのか、ドキュメントの表記だけでは確定できなかった。**実機検証で確定させる項目。**
:::

この違いにより、**`snow`向けは`provision.EnvVars`だけで完結する**（鍵の中身をそのまま環境変数に渡せるため）一方、**`snowsql`向けは「一時ファイル書き出し＋`--private-key-path`引数追加」という独自Provisionerが必要**になる。後者は前回懸念していた「新規プラグインを自作する場合と同程度の実装コスト」がそのままかかるため、**今回のPRでは`snow`のキーペア認証対応を主目的とし、`snowsql`側のキーペア対応は発展（stretch）扱いとする**。

### コントリビュートにあたっての制約（前回調査済み、[CONTRIBUTING.md](https://github.com/1Password/shell-plugins/blob/main/CONTRIBUTING.md)より）

- Shell Pluginsのスコープは「認証が必要なプラットフォームのCLI（SaaS、クラウドベンダー、データベースなど）」。Snowflakeは対象内。
- サードパーティ依存の追加は極力避ける。今回の拡張はSDK標準機能（`provision.EnvVars`, `provision.TempFile`, カスタムProvisioner）だけで実現できるため、新規依存は不要な見込み。
- コミット署名が必須。
- `sdk/plugintest`パッケージでテストを書く。`make <plugin>/example-secrets`でテストフィクスチャを生成する。
- ドキュメント執筆は不要（採用されれば1Password側が書く）。PR本文に認証が必要な実行例コマンドを書く。
- 既存の`plugins/snowflake`への**機能追加**であり、新規プラグイン追加よりレビューの範囲が狭く済む可能性が高い（ただし後方互換性を壊さないことがより強く求められる点には注意）。

`{ }` で囲った値は各自の環境・アカウントの値に読み替える。まだ何も実行していないため、本ファイルの手順・コード片は**SDKソースコード・公式ドキュメント調査に基づく想定手順**であり、実際にビルド・テストした結果ではない。実機検証で細部が変わる可能性が高い。

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
Snowflake側は、パスワード認証・キーペア認証それぞれのテスト用ユーザー/コネクションが最低1つずつ必要。
`snowflake-cli-oauth.md`はOAuth前提だったため、今回は別途パスワード認証ユーザー、およびキーペア認証用のRSA鍵ペアを生成してSnowflakeユーザーに公開鍵を登録する必要がある（[公式手順](https://docs.snowflake.com/en/user-guide/key-pair-auth)）。
**実機検証で確定させる**: 検証用にSnowflake側でどのユーザー・ロールを使うか。
:::

## 1. 1Password/shell-plugins リポジトリをフォーク・クローンする

```sh
gh repo fork 1Password/shell-plugins --clone
cd shell-plugins
git checkout -b add-snow-keypair-support
```

確認:

```sh
ls plugins/snowflake/
# => plugin.go, login_details.go, snowsql.go, snowflake_test.go, test-fixtures/ など
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

## 2. キーペア認証用の`CredentialType`を追加する（`private_key.go`）

`plugins/snowflake/private_key.go`として新規作成する。

```go
package snowflake

import (
	"github.com/1Password/shell-plugins/sdk"
	"github.com/1Password/shell-plugins/sdk/provision"
	"github.com/1Password/shell-plugins/sdk/schema"
	"github.com/1Password/shell-plugins/sdk/schema/fieldname"
)

func PrivateKey() schema.CredentialType {
	return schema.CredentialType{
		Name:          "privatekey",
		DocsURL:       sdk.URL("https://docs.snowflake.com/en/user-guide/key-pair-auth"),
		ManagementURL: sdk.URL("https://docs.snowflake.com/en/user-guide/admin-user-management"),
		Fields: []schema.CredentialField{
			{
				Name:                fieldname.Account,
				MarkdownDescription: "Snowflake account name.",
			},
			{
				Name:                fieldname.Username,
				MarkdownDescription: "Snowflake username.",
			},
			{
				Name:                fieldname.PrivateKey,
				MarkdownDescription: "PEM形式のRSA秘密鍵（PKCS8）。",
				Secret:              true,
				MultiLine:           true,
			},
			{
				Name:                fieldname.Passphrase,
				MarkdownDescription: "秘密鍵がパスフレーズで保護されている場合のパスフレーズ（任意）。",
				Secret:              true,
				Optional:            true,
			},
		},
		// snowコマンド向けのデフォルト。snowsqlコマンドで使う場合はExecutable側でProvisionerを上書きする。
		DefaultProvisioner: provision.EnvVars(map[string]sdk.FieldName{
			"SNOWFLAKE_ACCOUNT":            fieldname.Account,
			"SNOWFLAKE_USER":               fieldname.Username,
			"SNOWFLAKE_PRIVATE_KEY_RAW":    fieldname.PrivateKey,
			"SNOWFLAKE_PRIVATE_KEY_PASSPHRASE": fieldname.Passphrase,
		}),
	}
}
```

:::message
- `fieldname.PrivateKey` / `fieldname.Passphrase` という定数がSDKの`sdk/schema/fieldname`パッケージに既に存在するか（無ければ新規追加が必要）は未確認。**実機検証で確定させる項目。**
- `schema.CredentialField`に`MultiLine`のようなフィールドが実在するか（PEM形式の複数行テキストを1Passwordの1フィールドにどう保存させるのが適切か）もSDKの型定義を見て確定させる。**実機検証で確定させる項目。**
- パスフレーズ用の環境変数名（`SNOWFLAKE_PRIVATE_KEY_PASSPHRASE`と仮定）は上述の通り未確定。
:::

## 3. `snow`用の`Executable`を追加する（`snow.go`）

`plugins/snowflake/snow.go`として新規作成する。パスワード認証（既存の`LoginDetails`を`SNOWFLAKE_*`環境変数に上書きマッピング）とキーペア認証（`PrivateKey`、デフォルトのまま）の両方を使えるようにする。

```go
package snowflake

import (
	"github.com/1Password/shell-plugins/sdk"
	"github.com/1Password/shell-plugins/sdk/needsauth"
	"github.com/1Password/shell-plugins/sdk/provision"
	"github.com/1Password/shell-plugins/sdk/schema"
	"github.com/1Password/shell-plugins/sdk/schema/credname"
	"github.com/1Password/shell-plugins/sdk/schema/fieldname"
)

func SnowCLI() schema.Executable {
	return schema.Executable{
		Name:    "Snowflake CLI",
		Runs:    []string{"snow"},
		DocsURL: sdk.URL("https://docs.snowflake.com/en/developer-guide/snowflake-cli/index"),
		NeedsAuth: needsauth.IfAll(
			needsauth.NotForHelpOrVersion(),
			needsauth.NotWhenContainsArgs("--account"),
			needsauth.NotWhenContainsArgs("--user"),
			needsauth.NotWhenContainsArgs("--password"),
			needsauth.NotWhenContainsArgs("--private-key-path"),
			needsauth.NotWhenContainsArgs("--private-key-file"),
			needsauth.NotWhenContainsArgs("--private-key-raw"),
		),
		Uses: []schema.CredentialUsage{
			{
				Name: credname.LoginDetails,
				Provisioner: provision.EnvVars(map[string]sdk.FieldName{
					"SNOWFLAKE_ACCOUNT":  fieldname.Account,
					"SNOWFLAKE_USER":     fieldname.Username,
					"SNOWFLAKE_PASSWORD": fieldname.Password,
				}),
				Optional: true,
			},
			{
				Name:     "privatekey",
				Optional: true,
			},
		},
	}
}
```

:::message
- `Uses`に2つの`CredentialUsage`を並べて両方`Optional: true`にすることで「パスワード認証かキーペア認証のどちらか一方（または両方）を設定できる」という挙動になることを期待しているが、`CredentialUsage.Optional`の実際のセマンティクス（フィールドコメントが額面通りだと「trueだと逆に必須」とも読めて曖昧）は、既存プラグインでの利用実績が見当たらなかった。**実機検証で確定させる最重要項目。**期待通りに動かない場合は、パスワード認証用とキーペア認証用で`Executable`自体を分ける（`SnowCLIWithPassword()` / `SnowCLIWithKeyPair()`のように2つ用意し、`Runs`は両方とも`["snow"]`にできるか、それとも1つの`Executable`しか同じコマンドに紐付けられないかも要確認）などの代替案を検討する。
- `snow connection add`のように認証情報を新規登録するサブコマンドでは注入がむしろ邪魔になる可能性がある。`NeedsAuth`の除外条件をサブコマンド単位でも検討する。
:::

## 4. `plugin.go`を更新する

```go
package snowflake

import (
	"github.com/1Password/shell-plugins/sdk"
	"github.com/1Password/shell-plugins/sdk/schema"
)

func New() schema.Plugin {
	return schema.Plugin{
		Name: "snowflake",
		Platform: schema.PlatformInfo{
			Name:     "Snowflake",
			Homepage: sdk.URL("https://snowflake.com"),
		},
		Credentials: []schema.CredentialType{
			LoginDetails(),
			PrivateKey(),
		},
		Executables: []schema.Executable{
			SnowflakeCLI(), // 既存: snowsql
			SnowCLI(),      // 追加: snow
		},
	}
}
```

## 5. (発展/stretch) `snowsql`側にもキーペア認証を追加する

時間が許せば、`snowsql`の`Uses`にも`privatekey`を追加する。ただしこちらは`snow`と違い秘密鍵をファイルとして渡す必要があるため、独自のProvisionerを書く。

```go
package snowflake

import (
	"context"

	"github.com/1Password/shell-plugins/sdk"
	"github.com/1Password/shell-plugins/sdk/schema/fieldname"
)

type snowsqlPrivateKeyProvisioner struct{}

func (snowsqlPrivateKeyProvisioner) Description() string {
	return "Provisions Snowflake key pair credentials for snowsql via a temporary key file"
}

func (snowsqlPrivateKeyProvisioner) Provision(ctx context.Context, in sdk.ProvisionInput, out *sdk.ProvisionOutput) {
	out.AddEnvVar("SNOWSQL_ACCOUNT", in.ItemFields[fieldname.Account])
	out.AddEnvVar("SNOWSQL_USER", in.ItemFields[fieldname.Username])
	if passphrase, ok := in.ItemFields[fieldname.Passphrase]; ok && passphrase != "" {
		out.AddEnvVar("SNOWSQL_PRIVATE_KEY_PASSPHRASE", passphrase)
	}

	keyPath := in.FromTempDir("rsa_key.p8")
	out.AddSecretFile(keyPath, []byte(in.ItemFields[fieldname.PrivateKey]))
	out.AddArgs("--private-key-path", keyPath)
}

func (snowsqlPrivateKeyProvisioner) Deprovision(ctx context.Context, in sdk.DeprovisionInput, out *sdk.DeprovisionOutput) {
	// 一時ファイルの削除はSDKが自動で行う。
}
```

`snowsql.go`の`Uses`に追記する:

```go
Uses: []schema.CredentialUsage{
	{Name: credname.LoginDetails, Optional: true},
	{Name: "privatekey", Provisioner: snowsqlPrivateKeyProvisioner{}, Optional: true},
},
```

:::message
- `in.ItemFields`のマップのキーが`fieldname.XXX`型でそのままアクセスできるかはSDKの型定義（`sdk.ProvisionInput.ItemFields map[FieldName]string`）を見る限り妥当そうだが、実際にコンパイルが通るかは未確認。**実機検証で確定させる項目。**
- 時間の都合でこの発展部分は記事に含めない可能性がある。**採用するかも含めて実機検証で確定させる。**
:::

## 6. スキーマの検証・テスト・ローカルビルド

```sh
make snowflake/validate
make snowflake/example-secrets
make snowflake/build
```

確認:

```sh
ls ~/.op/plugins/local
op plugin list | grep -i snowflake
```

PRを出す前提なので、`sdk/plugintest`パッケージのヘルパーを使ったテストコードを`snowflake_test.go`に追記し（既存のパスワード認証のテストケースに加えて、キーペア認証のテストケースを追加する）、`make snowflake/example-secrets`の出力をテストフィクスチャとして使う。

```sh
make snowflake/test
```

## 7. 1Passwordにアイテムを登録して動かしてみる

```sh
op plugin init snow
```

:::message
プラグイン(`plugins/snowflake`)が複数の`Executable`（`snowsql`と`snow`）を持つ場合、`op plugin init`にどちらのコマンド名を渡すべきか、また対話フローでパスワード認証とキーペア認証のどちらの`CredentialType`を使うか選択できるかは未確認。**実機検証で確定させる項目（プロンプトの正確な文言・生成される`~/.config/op/plugins.sh`へのエイリアス内容）。**
本手順は実際のSnowflakeアカウント（テスト用ユーザー・パスワード・鍵ペア）を用意しないと検証できない。この環境には認証情報がないため未実施。
:::

`op plugin init`実行後、`~/.config/op/plugins.sh`（または同等のファイル）に`alias snow="op plugin run -- snow"`が書き込まれるので、これを`.zshrc`/`.bashrc`（`fish`の場合は`config.fish`）に`source`する設定を行い、新しいターミナルセッションで`snow`と打つだけでプラグイン経由になることを確認する（[AWS CLI/CDKの記事](https://dev.classmethod.jp/articles/1password-shell-plugins-aws-cli-cdk/)と同じ体験）。

## 8. Snowflake CLIから実際に接続して動作確認する

```sh
# パスワード認証で登録した場合
snow sql -q "SELECT CURRENT_USER(), CURRENT_ACCOUNT();"

# 明示的にワンショットで確認する場合
op plugin run -- snow sql -q "SELECT CURRENT_USER(), CURRENT_ACCOUNT();"
```

確認する観点:

1. パスワード認証・キーペア認証それぞれで接続できること
2. 生の`SNOWFLAKE_PASSWORD`/`SNOWFLAKE_PRIVATE_KEY_RAW`がシェル履歴・環境変数に残らないこと（`env | grep SNOWFLAKE`をコマンド終了後に確認し、クリアされているか）
3. `~/.snowflake/config.toml`にパスワードや鍵を書かなくても接続できること
4. 1Passwordアプリの生体認証プロンプトが表示され、承認しないと接続できないこと
5. Shell Pluginを一時的に無効化して素の`snow`バイナリを直接叩く方法（判明した場合はその方法、判明しなかった場合はエイリアスを一時的にunaliasする等の代替策）

```sh
env | grep SNOWFLAKE
```

## 9. (比較) プラグインを使わない簡易な方法

記事内で「プラグインを使うほどではない場合の代替案」として紹介する候補。実際に試して比較する。

```sh
# op run: op://参照を環境変数に展開してsnowを実行
op run --env-file=./snowflake.env -- snow sql -q "SELECT CURRENT_USER();"
```

`snowflake.env`（1Passwordのop://参照を記載するテンプレート）:

```
SNOWFLAKE_ACCOUNT=op://{vault名}/{item名}/account
SNOWFLAKE_USER=op://{vault名}/{item名}/username
SNOWFLAKE_PRIVATE_KEY_RAW=op://{vault名}/{item名}/private_key
```

:::message
`op run`方式は1Password Shell Pluginのような「対象コマンドの実行を検知して自動的に認証情報を注入する」仕組みではなく、毎回コマンドの前に`op run --`を付ける必要がある点がプラグイン方式との違い。この体験差を実際に両方試して記事内で比較する。
:::

## 10. Pull Requestを作成する

手順6のテスト・ビルドが通ったら、本家へPRを出す。**新規プラグインの追加ではなく既存プラグインへの機能追加**であることをPRタイトル・本文で明確にする。

```sh
git add plugins/snowflake
git commit -S -m "Add snow CLI support and key pair authentication to Snowflake plugin"
git push -u origin add-snow-keypair-support

gh pr create \
  --repo 1Password/shell-plugins \
  --title "Add snow CLI support and key pair authentication to Snowflake plugin" \
  --body "$(cat <<'EOF'
## Summary
- The existing Snowflake plugin only supports the legacy `snowsql` CLI with password authentication.
- Snowflake now recommends the modern `snow` CLI (Snowflake CLI) for new projects; this PR adds `snow` as a second supported executable.
- Adds a new `privatekey` credential type for key pair authentication, usable with `snow` (and optionally `snowsql`, which requires the key to be written to a temporary file).

## Example command that requires authentication
snow sql -q "SELECT CURRENT_USER();"
EOF
)"
```

:::message
- CONTRIBUTING.mdの指示通り、PR本文に「認証が必要な実行例コマンド」を含めた。
- 既存プラグインへの後方互換性のある追加であることを強調し、レビューされやすくする。
- Shell Pluginsはベータ版のためレビューに時間がかかったり、実装の手直しを求められる可能性がある。**実機検証（PRを実際に出してからのやり取り）で確定させる項目。** 記事執筆時点でPRがマージされていない場合は、その旨と「レビュー中」であることを正直に書く。
:::

## 11. クリーンアップ

PRは開いたままにする（フォーク・ブランチは削除しない）。ローカル環境の検証用リソースのみ後片付けする。

```sh
# ローカルビルドしたプラグインを削除
make snowflake/remove-local

# op plugin initで作成したエイリアス・設定を削除
op plugin init snow --uninstall 2>/dev/null || true
# 上記コマンドが存在しない場合、~/.config/op/plugins.sh を直接編集して該当行を削除する

# 1Passwordに作成した検証用アイテムを削除
op item delete "{検証用に作成したアイテム名}" --vault {vault名}
```

Snowflake側で検証用に作成したユーザー・公開鍵がある場合、検証後にパスワードのリセット/無効化・公開鍵の削除をしておく。

## 12. 記事執筆

- [ ] `articles/snowflake-cli-1password-shell-plugin.md`の各セクションを実際の実行結果・つまずいた点で埋める
- [ ] 記事冒頭で「最初は新規プラグインを自作しようとしたが、既存プラグインを拡張する方が良いと判断した」という方針転換の経緯自体を書く（読者にとって学びが多いはず）
- [ ] `CredentialUsage.Optional`でパスワード/キーペアの両対応がうまくいったか、うまくいかなかった場合はどう回避したかを書く（読者にとって一番価値のある「ハマりどころ」になりうる）
- [ ] `snowsql`側のキーペア対応（手順5）を採用したかどうかに応じて目次を調整する
- [ ] 手順10で出したPRへのリンクを記事に追記する。公開時点でマージ済みか、レビュー中かの状態も明記する
- [ ] `snowflake-cli-oauth.md`との違い（OAuth vs パスワード/キーペア認証、かつ「認証情報そのものをどう安全に扱うか」という切り口の違い）を「はじめに」で明記する
- [ ] `published: true`にして公開日を設定する
- [ ] 本ファイル（`snowflake-cli-1password-shell-plugin-plan.md`）は記事完成後に削除する
