# 検証手順書: Ruby 4 + Rails 8 から Snowflake に ODBC で接続できるか試す

作成日: 2026-10-03 / 実行状況: Step 1・2・3・4・5・7、Step 6の一部(ODBC単体ベンチのみ)を実施済み(2026-10-03時点)。検証環境は `~/ghq/yuuu/ruby4-rails8-snowflake-odbc/`。代替方式(ruby_snowflake_client・SQL API)との比較、クリーンアップ、upstreamへのPR可否判断は未実施。

## 0. 事前調査で分かっていること(2026-10-03時点)

| 項目 | 内容 | 区分 | 出典 |
|---|---|---|---|
| Snowflake公式のRubyドライバー | 無い。ODBC / コミュニティgem / SQL APIの3択 | 事実 | https://eng.localytics.com/connecting-to-snowflake-with-ruby-on-rails/ |
| `snowflake_odbc_adapter` | 最新 7.2.0.1(2024-09-19)、required_ruby_version >= 3.1.0、activerecord >= 7.2、ruby-odbc に依存。READMEは「very early development」「接続は connection string のみ」 | 事実 | https://rubygems.org/gems/snowflake_odbc_adapter / https://github.com/GuillaumeGillet/snowflake_odbc_adapter |
| README上のruby-odbc | `vhermecz/ruby-odbc` のGitHubフォークをGemfileで指定する案内(元gemがRuby 3+非対応のため) | 事実 | 同上 |
| `ruby-odbc` 本体 | 最新 0.999993(2026-10-03時点のrubygems。0.999992は2024-04-08) | 事実 | https://bundler.rubygems.org/gems/ruby-odbc |
| `ruby-odbc-supported` | 「modern Ruby向け互換性修正のフォーク」。1.0.0 / 1.0.1 が 2025-11-14 | 事実(Ruby 4での動作は未確認) | https://rubygems.org/gems/ruby-odbc-supported |
| Rails 8.1 のRuby要件 | Rails 8.1.2 は Ruby >= 3.2.0, < 4.1.0 | 事実(検索結果の要約) | https://rubygems.org/gems/rails |
| Snowflake ODBC 4.x (Linux) | x86_64 / aarch64、deb/rpm/tar.gz、unixODBC or iODBC が必要、`isql -v` で確認可 | 事実 | https://docs.snowflake.com/en/developer-guide/odbc/odbc-linux |
| ODBCのキーペア認証 | `AUTHENTICATOR=SNOWFLAKE_JWT`、`PRIV_KEY_FILE`、`PRIV_KEY_FILE_PWD` | 事実 | https://docs.snowflake.com/en/developer-guide/odbc/odbc-parameters |
| 日本語の先行記事 | Ruby×Snowflake接続を扱ったものは見つからなかった | 事実(検索範囲内) | - |

### 推測(要検証)
- `snowflake_odbc_adapter` は最終更新が2024年のため、Rails 8.1 / Ruby 4 では動かない可能性が高い(AR内部APIの変更、C拡張のビルドなど)。
- 動かない場合の原因切り分け(ruby-odbc側 / adapter側 / Rails側)自体が記事の価値になる。

## 1. 目的と記事の想定構成

### 目的
「Ruby 4 + Rails 8.x から Snowflake にODBC経由で接続できるか」を段階的に検証し、どこまで動き、どこで壊れるかを明らかにする。最終ゴールは Rails 8 の `ActiveRecord` から SELECT できること。

### 方針: 動かなければforkして直してよい
- 動かない場合は、gemをforkしてコードを改変してよい(個人の判断で許可済み)。
- 改変が小さく、出来が良ければ、upstreamへPRを出すことを検討する(出すかどうかは、出来を見て執筆者が最終判断する。自動では出さない)。
- 改変は「最小限の差分で、原因ごとにコミットを分ける」。記事では差分を載せ、なぜ必要だったかを説明する。

### 検証の段階(後段ほどハードル高)
1. Snowflake ODBCドライバー単体で接続(`isql`)
2. Ruby 4 で `ruby-odbc` 系gemがビルド・ロードできる
3. Ruby 4 + 素のODBC APIで SELECT できる(キーペア認証)
4. `snowflake_odbc_adapter` を ActiveRecord 単体(Railsなし)で使う
5. Rails 8.x アプリから接続する(モデル参照、`rails console`、`db:migrate` が不要な参照専用運用)

### 見出し案
1. Ruby×Snowflakeの接続手段(公式ドライバー無しの現状)
2. 環境構築(Docker / unixODBC / Snowflake ODBC)
3. Ruby 4で ruby-odbc は動くか
4. snowflake_odbc_adapter を Rails 8 で動かす(動いた/動かなかった)
5. 動かすために必要だったパッチ(forkして直した内容、upstreamへのPR) or 代替案(SQL API / ruby_snowflake_client)
6. まとめ

## 2. 前提条件・準備物
- Docker が使えるホスト(Linux)。ホストOSを汚さないよう、検証は全てコンテナ内で行う。Arm Mac(Docker Desktop/Rancher Desktop)の場合、Snowflake ODBCドライバーがx86_64のみの配布のため `--platform=linux/amd64` のエミュレーションが必要(buildx経由、`linux/amd64`対応を確認済み)。
- Snowflakeアカウント(ACCOUNTADMIN前提で簡略化。既存記事と同様)。
- Snowflake CLI(`snow`)が接続済み。接続名は実際の環境に合わせる(本検証では `oauth`。OAuth接続は非対話実行の前に`snow connection test`で対話認証を済ませておく)。
- OpenSSL(キーペア生成用)。
- AWSは使わない。
- 実際の検証ディレクトリ: `~/ghq/yuuu/ruby4-rails8-snowflake-odbc/`(gitリポジトリ化。秘密鍵・`.deb`・`sf_app/`は`.gitignore`対象)。fork した adapter は同ディレクトリ配下の `snowflake_odbc_adapter/`(リモート: https://github.com/yuuu/snowflake_odbc_adapter )。

## 3. Snowflake側の準備(CLI)

```bash
# 作業ディレクトリ(本検証では ~/ghq/yuuu/ruby4-rails8-snowflake-odbc を使用)
mkdir -p ~/ghq/yuuu/ruby4-rails8-snowflake-odbc && cd ~/ghq/yuuu/ruby4-rails8-snowflake-odbc

# 検証用ロール/ユーザー/ウェアハウス/DB/テーブル
snow sql -q "
USE ROLE ACCOUNTADMIN;
CREATE WAREHOUSE IF NOT EXISTS ruby_odbc_wh WAREHOUSE_SIZE=XSMALL AUTO_SUSPEND=60 AUTO_RESUME=TRUE;
CREATE DATABASE IF NOT EXISTS ruby_odbc_db;
CREATE SCHEMA IF NOT EXISTS ruby_odbc_db.app;
CREATE ROLE IF NOT EXISTS ruby_odbc_role;
GRANT USAGE ON WAREHOUSE ruby_odbc_wh TO ROLE ruby_odbc_role;
GRANT USAGE ON DATABASE ruby_odbc_db TO ROLE ruby_odbc_role;
GRANT USAGE ON SCHEMA ruby_odbc_db.app TO ROLE ruby_odbc_role;
GRANT SELECT ON FUTURE TABLES IN SCHEMA ruby_odbc_db.app TO ROLE ruby_odbc_role;
GRANT SELECT ON ALL TABLES IN SCHEMA ruby_odbc_db.app TO ROLE ruby_odbc_role;

CREATE OR REPLACE TABLE ruby_odbc_db.app.products (
  id NUMBER AUTOINCREMENT PRIMARY KEY,
  name VARCHAR NOT NULL,
  price NUMBER(10,2),
  released_at TIMESTAMP_NTZ,
  tags VARIANT,
  is_active BOOLEAN
);
INSERT INTO ruby_odbc_db.app.products (name, price, released_at, is_active) VALUES
  ('Keyboard', 4980.50, '2026-01-15 09:30:00', TRUE),
  ('Mouse', 1980, '2026-02-01 12:00:00', TRUE),
  ('日本語商品', 100, '2026-03-01 00:00:00', FALSE);
GRANT SELECT ON ALL TABLES IN SCHEMA ruby_odbc_db.app TO ROLE ruby_odbc_role;
"
```

### キーペア認証用ユーザー
```bash
openssl genrsa 2048 | openssl pkcs8 -topk8 -inform PEM -out rsa_key.p8 -nocrypt
openssl rsa -in rsa_key.p8 -pubout -out rsa_key.pub
PUBKEY=$(grep -v 'KEY-----' rsa_key.pub | tr -d '\n')

snow sql -q "
USE ROLE ACCOUNTADMIN;
CREATE USER IF NOT EXISTS ruby_odbc_user DEFAULT_ROLE=ruby_odbc_role DEFAULT_WAREHOUSE=ruby_odbc_wh TYPE=SERVICE;
GRANT ROLE ruby_odbc_role TO USER ruby_odbc_user;
ALTER USER ruby_odbc_user SET RSA_PUBLIC_KEY='${PUBKEY}';
"
# 確認
snow sql -q "DESC USER ruby_odbc_user" | grep -i RSA_PUBLIC_KEY
# アカウント識別子(ODBCのserverに使う)
snow sql -q "SELECT CURRENT_ORGANIZATION_NAME() || '-' || CURRENT_ACCOUNT_NAME()"
```
- `rsa_key.p8` は `.gitignore` 対象。リポジトリにコミットしない。
- `TYPE=SERVICE` が使えない場合は `TYPE` を外す(要確認)。

## 4. 検証コンテナの用意

### 4.1 Dockerfile(Ruby 4)
```dockerfile
FROM ruby:4.0
RUN apt-get update && apt-get install -y --no-install-recommends \
      unixodbc unixodbc-dev build-essential libyaml-dev curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*
# Snowflake ODBC (deb) は https://developers.snowflake.com/odbc/ から取得して COPY する
COPY snowflake-odbc-*.deb /tmp/
RUN dpkg -i /tmp/snowflake-odbc-*.deb || apt-get install -f -y
WORKDIR /app
```
- Dockerタグ `ruby:4.0` の存在と、アーキテクチャ(x86_64 / aarch64)に合うdebを選ぶこと(要確認)。
- debのインストール時に `SF_ACCOUNT` 環境変数が必要な場合がある(公式Linux手順参照)。

### 4.2 DSNレスの接続文字列(odbc.iniを使わない)
adapterが接続文字列のみ対応のため、基本は接続文字列で検証する。
```
Driver=Snowflake ODBC;Server=<org>-<account>.snowflakecomputing.com;UID=RUBY_ODBC_USER;AUTHENTICATOR=SNOWFLAKE_JWT;PRIV_KEY_FILE=/secrets/rsa_key.p8;Warehouse=ruby_odbc_wh;Database=ruby_odbc_db;Schema=app;Role=ruby_odbc_role
```
```bash
docker build -t ruby-odbc-sf .
docker run --rm -it -v "$PWD:/app" -v "$PWD/rsa_key.p8:/secrets/rsa_key.p8:ro" ruby-odbc-sf bash
```

## 5. 検証ステップ

### Step 1: ODBCドライバー単体(Rubyなし)
```bash
odbcinst -q -d          # 期待: [Snowflake ODBC] が出る
ruby -v                 # 期待: ruby 4.0.x
# isqlはDSNが要るため、/etc/odbc.ini か ~/.odbc.ini にDSNを作って確認
cat > ~/.odbc.ini <<'INI'
[sf]
Driver=Snowflake ODBC
Server=<org>-<account>.snowflakecomputing.com
UID=RUBY_ODBC_USER
AUTHENTICATOR=SNOWFLAKE_JWT
PRIV_KEY_FILE=/secrets/rsa_key.p8
Warehouse=ruby_odbc_wh
Database=ruby_odbc_db
Schema=app
Role=ruby_odbc_role
INI
echo "SELECT CURRENT_USER(), CURRENT_ROLE(), CURRENT_VERSION();" | isql -v sf
```
- 期待: 接続でき、ユーザー/ロール/バージョンが返る。
- 失敗時: 8章参照。ここで通らない場合はRuby以前の問題。

### Step 2: ruby-odbc系gemのビルド(Ruby 4)
3パターンを順に試し、結果を表にする(Snowflakeドライバー無しのコンテナで可)。

| 試行 | Gemfile | 確認コマンド |
|---|---|---|
| A | `gem 'ruby-odbc'`(rubygems版 0.999993) | `bundle install && ruby -rodbc -e 'puts :loaded'` |
| B | `gem 'ruby-odbc-supported'` (1.0.1) | 同上 |
| C | `gem 'ruby-odbc', github: 'vhermecz/ruby-odbc'`(adapter READMEの指定) | 同上 |

`ODBC::VERSION` 定数は存在しない(参照するとNameError)ため、確認コマンドは `puts :loaded` を使う。

#### 実施結果(2026-10-03、Docker `ruby:4.0` = Ruby 4.0.7、unixODBC、Snowflakeドライバー無し)
| 試行 | 結果 | 原因 |
|---|---|---|
| A | OK(ビルド・ロード) | - |
| B | NG | `ext/odbc.c` で `fetch_first_hash` を arity 0 で登録しているが、関数は `(int argc, VALUE *argv, VALUE self)`。Ruby 4 の `anyargs.h` の型チェックで `-Wincompatible-pointer-types` がエラーになる |
| C | NG | gemspec の `s.has_rdoc = false`(RubyGems 4で `has_rdoc=` が削除済み)で `bundle install` が止まる。拡張自体は無修正でビルドできる |

- 修正後(Step 7 の例として実施済み。ブランチ `fix/ruby4`、ローカルのみでfork・pushは未実施): B は `fetch_first_hash` の arity を `0` → `-1` に変更(1行)、C は `has_rdoc` の行を削除(1行)。どちらもビルド・ロードのみ確認。**SELECTできるかはStep 3で確認する**(未確認)。
- Aが通るため、後続のStep 3〜5はまずAで進める。B・Cの修正は記事の素材とupstream PR候補(Cのvhermeczは最終コミット2023-01で停止、Bのcloudvolumes/ruby-odbc-supportedは2025-11に1.0.1)。

- 期待: どれが Ruby 4 でビルド・ロードできるか。ビルドエラーが出たら全文を記録(記事の素材)。
- 想定される失敗: C拡張が使う古いRuby C API(例: `rb_data_object_*`、`rb_cData`等の削除/警告)によるコンパイルエラー。

### Step 3: 素のODBC APIでSELECT(キーペア認証)
`ruby-odbc` のAPIは版により差があるため、READMEとgem内のサンプルで確認すること。基本形は次のとおり。
```ruby
require 'odbc'
db = ODBC::Database.new
db.drvconnect(ENV.fetch('SF_ODBC_CONN'))
stmt = db.run('SELECT id, name, price, released_at, is_active FROM products ORDER BY id')
stmt.fetch_all.each { |row| p row }
stmt.drop
db.disconnect
```
- 期待: 3行が返る。日本語(`日本語商品`)が文字化けしないこと。
- 確認項目: `price`(NUMBER→BigDecimal/Float/String?)、`released_at`(Timestamp型の変換。ruby_snowflake_clientの説明では「ODBCはタイムスタンプの扱いが悪い」とされる)、`is_active`(BOOLEAN)、`tags`(VARIANT/NULL)。
- 文字コード: `DriverManagerEncoding=UTF-16` を `~/.snowflake/sf.odbc.ini` に設定した場合としない場合を比較。

### Step 4: snowflake_odbc_adapter を ActiveRecord 単体で
```ruby
# Gemfile
source 'https://rubygems.org'
gem 'activerecord', '~> 8.1'
gem 'snowflake_odbc_adapter', '7.2.0.1'
gem 'ruby-odbc' # Step 2で成功した指定に合わせる
```
```ruby
# ar_test.rb
require 'active_record'
require 'snowflake_odbc_adapter'   # 失敗時: require名とアダプター名をgem内で確認
ActiveRecord::Base.establish_connection(
  adapter: 'snowflake_odbc',        # ←要確認。gemの lib/ 配下で実際の名前を確認する
  conn_str: ENV.fetch('SF_ODBC_CONN')
)
class Product < ActiveRecord::Base
  self.table_name = 'products'
end
puts Product.count
Product.order(:id).each { |p| puts [p.id, p.name, p.price, p.released_at, p.is_active].inspect }
puts Product.where(is_active: true).to_sql
```
- 期待: `Product.count` => 3。
- 想定される失敗: `bundle install` の解決失敗(activerecord >= 7.2 制約)、`require` エラー、`ActiveRecord` 内部APIの変更によるNoMethodError。
- 失敗した場合: スタックトレースの先頭を記録し、adapterのソースを読んで「どのRails APIが変わったか」を特定する(記事の中心)。

### Step 5: Rails 8.x アプリから接続
```bash
gem install rails -v '~> 8.1'
rails new sf_app --skip-active-storage --skip-action-mailer --skip-action-cable --skip-test --skip-kamal --skip-solid --database=sqlite3
cd sf_app
bundle add snowflake_odbc_adapter ruby-odbc   # Step 2/4で成功した指定を使う
```
```yaml
# config/database.yml(アプリ本体はSQLite、Snowflakeは参照専用のsecondary DB)
default: &default
  adapter: sqlite3
  max_connections: 5   # 古い Rails では pool: 
  timeout: 5000

development:
  primary:
    <<: *default
    database: storage/development.sqlite3
  snowflake:
    adapter: snowflake_odbc       # ←要確認
    conn_str: <%= ENV['SF_ODBC_CONN'] %>
    migrations_paths: db/snowflake_migrate
```
```ruby
# app/models/snowflake_record.rb
class SnowflakeRecord < ApplicationRecord
  self.abstract_class = true
  connects_to database: { writing: :snowflake, reading: :snowflake }
end
# app/models/product.rb
class Product < SnowflakeRecord
  self.table_name = 'products'
end
```
```bash
bin/rails runner 'puts Product.count; puts Product.first.inspect'
bin/rails runner 'puts Product.where(is_active: true).pluck(:name).inspect'
```
- 期待: 件数と先頭行が返る。
- 追加確認: スキーマ参照(`Product.columns`)、`find`/`where`/`order`/`limit`、JOIN、日本語、タイムゾーン(`released_at` がUTCかローカルか)、`rails console` での表示、サーバー(`bin/rails s`)からコントローラ経由の参照、接続プールとコネクションの再接続(アイドル後に再実行)。
- 対象外とする(記事で明記): マイグレーション/書き込みの本格運用。SnowflakeはOLTP向けではない。

### Step 6: 動かなかった場合の代替(比較用)
- `ruby_snowflake_client` gem:同じSELECTを実行し、速度とTimestampの扱いをODBCと比較する(README上は ODBC 約15秒 vs 約3秒の例あり。再現するかを自分の環境で計測)。
- SQL API v2(`Net::HTTP` + `jwt` gem):キーペアJWTで `/api/v2/statements` に投げる最小実装。
- 計測: `Benchmark.realtime` で10万行程度の SELECT を各方式で3回測定し、中央値を表にする。

### Step 7: forkして直す(Step 2〜5で失敗した場合)
対象は失敗した層のリポジトリ(`ruby-odbc` 系 / `snowflake_odbc_adapter`)。まず原因の層を特定し、その層だけを直す。

```bash
# 例: adapterをfork(GitHub CLI)。fork先はユーザー自身のアカウント
gh repo fork GuillaumeGillet/snowflake_odbc_adapter --clone --default-branch-only
cd snowflake_odbc_adapter
git switch -c fix/ruby4-rails8

# ベースラインのテスト確認(テストがある場合)
bundle install && bundle exec rake test 2>&1 | tail -30
```
1. **原因の特定**: Step 2〜5 のエラーを、`gem` 内のどのファイル・どの行で起きているか特定する(`bundle exec gem contents` / スタックトレース)。
2. **再現手順を先に固める**: 最小の再現スクリプト(Step 3/4 のコード)を `script/` などに置き、失敗するコミットを残してから直す。
3. **最小差分で修正**: 1つの原因につき1コミット。例:
   - Ruby 4 で削除/変更されたC API・標準ライブラリ(C拡張のビルドエラー)
   - Rails 8.x の内部API変更(アダプターのメソッド名・引数・`ActiveRecord::ConnectionAdapters` の変更)
   - `database.yml` からの接続パラメータの受け渡し
4. **検証**: 修正後に Step 3〜5 を再実行し、結果表(6章)を更新する。可能なら Ruby 3.3 / 3.4 でも通ることを確認し、後方互換を壊していないことを示す。
5. **gemの参照切り替え**: 手元のRailsアプリは `gem 'snowflake_odbc_adapter', github: '<自分のアカウント>/snowflake_odbc_adapter', branch: 'fix/ruby4-rails8'` で検証する。
6. **upstreamへPRを出す判断**(出来が良ければ):
   - 事前確認: ライセンス(adapterはMIT)、`CONTRIBUTING`、既存のIssue/PR、メンテナーの最近の活動(最終コミット日)。
   - PRの内容: 変更理由、再現手順、検証環境(Ruby/Rails/ODBCドライバーの版)、変更前後の結果。テストを追加できるなら追加する(Snowflake実接続が必要なテストはCIでは動かせないため、モックまたは手動確認として説明を書く)。
   - 認証情報・アカウント名・秘密鍵を差分やログに含めない(PR前に `git diff` と `git log -p` を確認)。
   - upstreamが更新を止めている場合は、PRを出したうえで、forkをそのまま公開して使えるようにするか、別名gemで公開するかを検討する(この判断は記事の内容を見て決める)。
7. **記事への反映**: 修正差分、PRのURL(出した場合)、upstreamの反応を記録する。PRを出さなかった場合も、その理由を書く。

## 6. 結果の記録フォーマット(記事用)

| Step | 条件 | 結果(OK/NG) | エラー/メモ |
|---|---|---|---|
| 1 | isql(Snowflake ODBC 4.0.0、Docker `ruby:4.0`=Ruby 4.0.7、unixODBC) | OK | `SELECT CURRENT_USER(), CURRENT_ROLE(), CURRENT_VERSION()` で接続・クエリとも成功 |
| 2-A | ruby-odbc 0.999993 | OK | ビルド・ロードのみ確認 |
| 2-B | ruby-odbc-supported 1.0.1 | NG→修正でOK | `fetch_first_hash` のarity不整合。修正はbranch `fix/ruby4`(ローカル) |
| 2-C | vhermecz/ruby-odbc | NG→修正でOK | gemspecの `has_rdoc=`。修正はbranch `fix/ruby4`(ローカル) |
| 3 | 素のODBC SELECT(ruby-odbc 0.999993、キーペア認証) | OK | 3行取得。NUMBERはString(`"4980.50"`)、BOOLEANはInteger(0/1)、TIMESTAMPは`ODBC::TimeStamp`。日本語は**バイト列は正しいUTF-8だが`ASCII-8BIT`タグ付けされて返る**(文字化けではなく encoding 未設定。`force_encoding('UTF-8')`で解決) |
| 4 | AR単体 + adapter(activerecord 8.1.4 + snowflake_odbc_adapter 7.2.0.1) | NG→2パッチでOK | 詳細は下記「Step 4/5 で踏んだ2つのバグ」参照。パッチ後は`count`/`order`/`where`/`pluck`/`first`すべて成功。`to_sql`はbind値が`?`のまま表示される(実行結果自体は正しい) |
| 5 | Rails 8.1(`rails new`実アプリ、`connects_to`によるマルチDB、sqlite3がprimary) | OK | `bin/rails runner`から`Product.count`/`order`/`where`/`pluck`すべて成功。Step 4と同じ2パッチが必要 |
| 6 | 代替方式との速度比較 | 一部のみ実施 | ruby-odbcで10万行SELECT(ORDER BY付き)を3回計測: 6.779s / 6.863s / 6.565s(XSMALL、Docker amd64はArm Mac上でQEMUエミュレーション実行のため参考値)。`ruby_snowflake_client`・SQL API v2との比較は未実施(時間の都合で見送り) |
| 7 | fork修正後の再検証(Ruby 4.0.7、Rails 8.1.4) | OK | 2コミットで修正。upstreamへのPRはまだ出していない(要判断) |

NGの場合は「どのバージョンの組み合わせで」「どのエラーで」止まったかを必ず残す。パッチで直せたら差分も載せる(forkしてPRを出す選択肢もある)。

### Step 4/5 で踏んだ2つのバグ(snowflake_odbc_adapter 7.2.0.1 / activerecord 8.1.4)

いずれも fork(https://github.com/yuuu/snowflake_odbc_adapter, branch `fix/ruby4-rails8`)で最小差分で修正し、Step 4・5の再検証でOKになることを確認済み。

1. **`SnowflakeOdbc::Column#_default` が `nil` を処理できない**(`lib/active_record/connection_adapters/snowflake_odbc/column.rb:15`)
   - 症状: DEFAULT句のないカラムを含むテーブルに対して、カラムメタデータを読む最初のクエリ(`order`など)で `undefined method 'empty?' for nil (NoMethodError)` が発生。
   - 原因: `default.empty?` を `nil` チェックなしで呼んでいた。
   - 修正: `return nil if default.nil? || default.empty?` に1行変更。
2. **Rails 8.1 で `ActiveRecord::ConnectionAdapters::Column#initialize` に `cast_type` 引数が追加され、位置引数がずれる**(同ファイル5〜10行目)
   - 症状: 上記1を直した直後に `undefined method 'deduplicate' for true (NoMethodError)` が発生。
   - 原因: Rails 8.1で `Column#initialize(name, cast_type, default, sql_type_metadata = nil, null = true, ...)` と `name` の次に `cast_type` が挿入された(7.x/8.0は `cast_type` なし)。adapter側は旧シグネチャのまま `super(name, default, sql_type_metadata, null, ...)` を呼んでいたため、`null`(true/false)が`sql_type_metadata`の位置にずれて渡っていた。
   - 修正: `ConnectionAdapters::Column.instance_method(:initialize).parameters` で `cast_type` 引数の有無を実行時検出し、ある場合だけ `nil`(`fetch_cast_type`で遅延解決される)を2番目の位置引数として挿入。gemspecが `activerecord >= 7.2` を要求しており上限がないため、バージョン分岐がある方が安全と判断。

この他に、fork元リポジトリ自体に **ビルド済み `.gem` ファイルがコミットされている**既存の問題があり、`Gemfile`で`github:`指定するとRubyGemsの"contains itself"エラーで`bundle install`が失敗した(`snowflake_odbc_adapter-7.2.0.1.gem`・`snowflake_odbc_adapter-7.2.0.gem`を削除するコミットを別途追加して回避)。

## 7. 記事に載せる出力・スクリーンショット
- `ruby -v` / `bundle list | grep -E 'rails|activerecord|odbc'`
- Step 2 のビルドエラー(失敗した場合)全文
- Step 3〜5 の SELECT 結果(日本語・タイムスタンプ含む)
- Step 6 のベンチ表
- forkで加えた修正差分(diff)と、upstreamへのPR URL(出した場合)
- 最終的な動作可否の組み合わせ表(Ruby / Rails / gem の版)

## 8. エラー時の確認ポイント
- `isql` で `Data source name not found`: `odbcinst -j` で設定ファイルの場所を確認。
- `Can't open lib ... libsfodbc.so`: `ldd` で依存ライブラリ不足を確認。arm64 / x86_64 の不一致も疑う。
- `JWT token is invalid`: 公開鍵の登録(`DESC USER`)、`UID` の大文字、`AUTHENTICATOR=SNOWFLAKE_JWT`、時刻ずれ、`Server` のアカウント識別子を確認。
- `Insufficient privileges`: ロールの付与、`USE WAREHOUSE` 権限。
- 文字化け: `DriverManagerEncoding=UTF-16`(`~/.snowflake/sf.odbc.ini`)。
- ruby-odbc のビルド失敗: `unixodbc-dev` の有無、`gem install ruby-odbc -- --with-odbc-dir=/usr` 等のオプション。
- Bundlerが解決できない: `activerecord` の制約(adapterは >= 7.2)、Rubyバージョン制約(`bundle install` の出力全文を確認)。

## 9. クリーンアップ
```bash
snow sql -q "
USE ROLE ACCOUNTADMIN;
DROP DATABASE IF EXISTS ruby_odbc_db;
DROP WAREHOUSE IF EXISTS ruby_odbc_wh;
DROP USER IF EXISTS ruby_odbc_user;
DROP ROLE IF EXISTS ruby_odbc_role;
"
rm -f rsa_key.p8 rsa_key.pub
docker rmi ruby-odbc-sf
```

## 10. コスト・セキュリティ注意
- XSMALL・自動停止60秒のウェアハウスのみ使う。ベンチは短時間で終える。
- 秘密鍵は検証後に削除する。コンテナイメージに鍵を焼き込まない(`-v` でマウント)。
- forkやPRの差分・ログ・スクリーンショットに、アカウント識別子、ユーザー名、秘密鍵、接続文字列を含めない。
- `TYPE=SERVICE` のユーザーにはパスワードを設定しない。

## 11. 未確認事項リスト(実行前・執筆前に確認する)
1. **解決**: Docker タグ `ruby:4.0` は存在する(Ruby 4.0.7、2026-09-15リリース)。
2. **解決**: Rails 8.1.4 は Ruby 4.0.7 上で動作した(`gem install rails -v '~> 8.1'`が解決・起動した)。
3. **解決**: adapter名は `"odbc"`(`"snowflake_odbc"`ではない)。`require "snowflake_odbc_adapter"`で自動的に`active_record/connection_adapters/snowflake_odbc_adapter`がrequireされる。接続パラメータは`:conn_str`必須(`:dsn`は`NotImplementedError`)で、値は`"Key=Value;Key=Value"`形式の文字列。
4. **解決**: `ruby-odbc`(rubygems版 0.999993、素の指定でOK)で動く。`vhermecz/ruby-odbc`や`ruby-odbc-supported`への切り替えは不要だった。
5. **解決(参考)**: `ruby-odbc-supported` 1.0.1はStep 2の調査時点でRuby 4ビルドにNGだったが、Step 4/5の本検証は`ruby-odbc`で通ったため未使用。
6. **解決**: Snowflake ODBC Linuxドライバーは2026-10-03時点で最新 4.0.0(他に4.0.0-rc1〜rc4のプレリリースあり)。取得URLは `https://sfc-repo.snowflakecomputing.com/odbc/linux/<version>/snowflake-odbc-<version>.x86_64.deb`(ログイン不要でcurl取得可)。**x86_64ビルドのみ配布されており、aarch64向けdeb/rpm/tar.gzは存在しない**(Arm Mac/Linuxでは`--platform=linux/amd64`のエミュレーションが必須)。dpkg実行時に`SF_ACCOUNT`未設定の警告が出るが、`odbc.ini`を後から上書きするなら無視してよい。
7. **解決**: `PRIV_KEY_FILE`/`AUTHENTICATOR=SNOWFLAKE_JWT`等のODBCキーペア認証パラメータは、adapter経由の接続文字列(`conn_str`)でもそのまま有効。
8. **解決**: `ALTER USER ... SET TYPE=SERVICE` はこの検証アカウント(ACCOUNTADMIN)で問題なく実行できた。
9. **解決**: 素のODBC層ではNUMBERはString、BOOLEANはInteger(0/1)、TIMESTAMPは`ODBC::TimeStamp`で返る。adapter層(ActiveRecord)はtype mapで適切にInteger/Float/Time/boolean(true/false)へ変換する。ただしNUMBERは**Floatにマップされ、BigDecimalにはならない**(金額等の精度が必要な用途では要注意)。文字列(日本語含む)はバイト列は正しいがASCII-8BITタグのまま返り、adapter層でも再エンコードされない。
10. **解決**: `connects_to database: { writing: :snowflake, reading: :snowflake }` で問題なく動作。sqlite3側(`primary`)は`max_connections`(Rails 8.1のデフォルトテンプレート)、snowflake側は接続プールの設定自体を省略しても動いた(adapterが独自に`@raw_connection`を1本持つだけで、AR標準のプーリングの恩恵は薄い可能性がある。本番運用するなら要追加調査)。
11. 一部解決: ruby-odbcでの10万行SELECTは6.5〜6.9秒(XSMALL、QEMUエミュレーション環境のため参考値)。`ruby_snowflake_client`・SQL API v2との比較は未実施。
12. 未解決(範囲内の結論のまま)。
13. **解決**: `snowflake_odbc_adapter`(fork元 https://github.com/singlespot/snowflake_odbc_adapter )はMIT、Issueは0件・オープンPRなし、直近コミットは2024-09-19(gemの最終リリース7.2.0.1と同時期)。ただし2026-08-05に関連PR(column comments対応等)がマージされた形跡があるのに、そのコミットが`main`ブランチの履歴に見当たらない不整合がある(要再確認)。`ruby-odbc`(larskanis)側は未確認。
14. **解決**: 修正対象は`snowflake_odbc_adapter`のactiverecordアダプター層(`lib/active_record/connection_adapters/snowflake_odbc/column.rb`)の2箇所。`ruby-odbc`本体・Rails側のdatabase.ymlには修正不要だった。
15. 未解決(upstreamへのPRを出すかどうかの判断と合わせて未着手)。
16. **解決(確認済み)**: `snow sql`はOAuthの対話セッションが切れると非対話実行時に`Unable to receive the OAuth message within a given timeout`で失敗する。`snow connection test`を一度対話的に実行してから流す。
17. **解決**: Snowflake ODBCのdebはログイン不要で`curl`取得可能(手動ダウンロードの手間はないが、自動化スクリプトに組み込む場合はURLのバージョン部分を都度更新する必要がある)。

### 新たに判明した未確認事項
18. upstream (`singlespot/snowflake_odbc_adapter`) の `main` ブランチにビルド済み `.gem` ファイル(`snowflake_odbc_adapter-7.2.0.1.gem` 等)がコミットされており、`github:` ソースでの`bundle install`を壊す。upstreamへのPRにはこのクリーンアップも含めるべきか要判断。
19. Ruby 4.0 で `benchmark` が標準添付ライブラリから削除された(`require 'benchmark'`が`LoadError`になる。`bundled_gems.rb`経由で「Gemfileに追加してください」という警告が出る)。計測には`Process.clock_gettime(Process::CLOCK_MONOTONIC)`を使った。
20. `Product.where(...).to_sql` の出力がバインド値を展開せず `?` のままになる(実際のクエリ実行・結果は正しい)。adapterが`quote`/`cast_bound_value`周りを完全には実装していない可能性があり、ログ出力等で生SQLを確認したい場合は注意。
