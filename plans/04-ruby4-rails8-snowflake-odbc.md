# 検証手順書: Ruby 4 + Rails 8 から Snowflake に ODBC で接続できるか試す

作成日: 2026-10-03 / 実行は未実施(手順書のみ)

## 0. 事前調査で分かっていること(2026-10-03時点)

| 項目 | 内容 | 区分 | 出典 |
|---|---|---|---|
| Snowflake公式のRubyドライバー | 無い。ODBC / コミュニティgem / SQL APIの3択 | 事実 | https://eng.localytics.com/connecting-to-snowflake-with-ruby-on-rails/ |
| `snowflake_odbc_adapter` | 最新 7.2.0.1(2024-09-19)、required_ruby_version >= 3.1.0、activerecord >= 7.2、ruby-odbc に依存。READMEは「very early development」「接続は connection string のみ」 | 事実 | https://rubygems.org/gems/snowflake_odbc_adapter / https://github.com/GuillaumeGillet/snowflake_odbc_adapter |
| README上のruby-odbc | `vhermecz/ruby-odbc` のGitHubフォークをGemfileで指定する案内(元gemがRuby 3+非対応のため) | 事実 | 同上 |
| `ruby-odbc` 本体 | 最新 0.999992(2024-04-08) | 事実 | https://bundler.rubygems.org/gems/ruby-odbc |
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
5. 動かすために必要だったパッチ or 代替案(SQL API / ruby_snowflake_client)
6. まとめ

## 2. 前提条件・準備物
- Docker が使えるホスト(Linux)。ホストOSを汚さないよう、検証は全てコンテナ内で行う。
- Snowflakeアカウント(ACCOUNTADMIN前提で簡略化。既存記事と同様)。
- Snowflake CLI(`snow`)が接続済み。接続名は `default` と仮定。
- OpenSSL(キーペア生成用)。
- AWSは使わない。

## 3. Snowflake側の準備(CLI)

```bash
# 作業ディレクトリ
mkdir -p ~/work/ruby-odbc-sf && cd ~/work/ruby-odbc-sf

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
3パターンを順に試し、結果を表にする。

| 試行 | Gemfile | 確認コマンド |
|---|---|---|
| A | `gem 'ruby-odbc'`(rubygems版 0.999992) | `bundle install && ruby -rodbc -e 'puts ODBC::VERSION'` |
| B | `gem 'ruby-odbc-supported'` (1.0.1) | 同上 |
| C | `gem 'ruby-odbc', github: 'vhermecz/ruby-odbc'`(adapter READMEの指定) | 同上 |

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

## 6. 結果の記録フォーマット(記事用)

| Step | 条件 | 結果(OK/NG) | エラー/メモ |
|---|---|---|---|
| 1 | isql | | |
| 2-A | ruby-odbc 0.999992 | | |
| 2-B | ruby-odbc-supported 1.0.1 | | |
| 2-C | vhermecz/ruby-odbc | | |
| 3 | 素のODBC SELECT | | |
| 4 | AR単体 + adapter | | |
| 5 | Rails 8.1 | | |
| 6 | 代替方式との速度比較 | | |

NGの場合は「どのバージョンの組み合わせで」「どのエラーで」止まったかを必ず残す。パッチで直せたら差分も載せる(forkしてPRを出す選択肢もある)。

## 7. 記事に載せる出力・スクリーンショット
- `ruby -v` / `bundle list | grep -E 'rails|activerecord|odbc'`
- Step 2 のビルドエラー(失敗した場合)全文
- Step 3〜5 の SELECT 結果(日本語・タイムスタンプ含む)
- Step 6 のベンチ表
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
- `TYPE=SERVICE` のユーザーにはパスワードを設定しない。

## 11. 未確認事項リスト(実行前・執筆前に確認する)
1. Ruby 4.0 の正式リリース状況と Docker タグ `ruby:4.0` の有無(本書は存在する前提)。
2. Rails 8.1 の Ruby 4 対応(Rails 8.1.2 の `required_ruby_version` が `< 4.1.0` という検索要約のみで確認)。
3. `snowflake_odbc_adapter` のアダプター名(`database.yml` の `adapter:` の値)、`require` 名、接続パラメータ名(`conn_str` か `connection_string` か)。READMEに例が無いため、ソース(`lib/`)を読んで確認する。
4. `snowflake_odbc_adapter` が要求する `ruby-odbc` の指定(`vhermecz/ruby-odbc` 以外で良いか)。
5. `ruby-odbc-supported` の Ruby 4 でのビルド可否と、元の ruby-odbc との差分。
6. Snowflake ODBC 4.x の最新バージョンと、deb 取得URL、debインストール時の `SF_ACCOUNT` 要否。
7. キーペア認証のパラメータ名(`PRIV_KEY_FILE` 等)がアダプター経由の接続文字列でも有効か。
8. `CREATE USER ... TYPE=SERVICE` が検証アカウントで使えるか。
9. VARIANT/BOOLEAN/TIMESTAMP の型変換(adapter側の対応状況)。
10. Rails 8.1 の multi-database 機構(`connects_to`)とadapterの相性、`max_connections`(旧 `pool`)の指定名。
11. ODBC各方式の速度比較(READMEの数値は他者の環境のもの)。
12. 日本語情報の有無は検索範囲内の結論で、存在しないとは断定できない。
