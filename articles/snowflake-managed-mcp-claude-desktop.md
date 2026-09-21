---
title: "Snowflake管理のMCP serverでエンジニア以外の社員がClaude Desktopから簡単にデータを集計・分析できる環境を作る"
emoji: "❄️"
type: "tech" # tech: 技術記事 / idea: アイデア
topics:
  - snowflake
  - mcp
  - claude
published: true
published_at: "2026-09-24 07:30"
publication_name: fusic
---

## はじめに

2026年9月10日(木)〜11日(金)に開催された [Snowflake World Tour Tokyo 2026](https://www.snowflake.com/ja/world-tour/tokyo/) に参加してきました。
Keynoteを始め、多くのセッションで **「AI-readyなデータ基盤を構築するためにSnowflakeを活用しよう」** といった話がなされていました。

Snowflakeからは [Snowflake CoCo](https://www.snowflake.com/ja/product/snowflake-coco/) や [Snowflake CoWork](https://www.snowflake.com/ja/product/snowflake-cowork/) といったSnowflakeと連携可能なAIツールが公開されています。
しかし、すでに業務でClaudeをメインで使っている会社だと、Claude環境からSnowflakeに接続できると便利です。

![Claude Desktopと接続されたSnowflake](/images/snowflake-managed-mcp-claude-desktop/005.png)

そこで本記事では、Snowflake-managed MCP Serverを準備し、Claude DesktopからSnowflakeのデータを集計・分析できる環境を構築する方法をまとめます。

## 事前準備

本記事ではSnowflake CLIを使って、Snowflake-managed MCP Serverを準備します。
Snowflake CLIのインストール方法や接続設定の方法は次の記事を参照ください。

https://zenn.dev/fusic/articles/snowflake-cli-oauth
https://zenn.dev/fusic/articles/snowflake-cli-install-with-mise

以降の手順は `oauth` という名前のコネクションが作成されている前提で記載します。

## サンプルデータを投入する

今回はサンプルデータとして、「商品マスタ」および「売上」のレコードをSnowflake上のDBに投入します。

### データベース、ウェアハウス、ロールの作成

次のようなSQLが記述されたファイルを準備します。

`{ユーザー名}` の部分は各自のSnowflakeユーザー名に読み替えてください。

```sql:setup_schema.sql
CREATE DATABASE IF NOT EXISTS mcp_demo_db;
CREATE SCHEMA IF NOT EXISTS mcp_demo_db.sales_schema;

CREATE WAREHOUSE IF NOT EXISTS mcp_demo_wh
  WAREHOUSE_SIZE = 'XSMALL'
  AUTO_SUSPEND = 60
  AUTO_RESUME = TRUE;

-- MCPサーバーに紐付ける読み取り専用ロール
CREATE ROLE IF NOT EXISTS mcp_readonly_role;

GRANT USAGE ON DATABASE mcp_demo_db TO ROLE mcp_readonly_role;
GRANT USAGE ON SCHEMA mcp_demo_db.sales_schema TO ROLE mcp_readonly_role;
GRANT USAGE ON WAREHOUSE mcp_demo_wh TO ROLE mcp_readonly_role;

-- 自分のユーザーにロールを付与し、OAuth接続時のデフォルトロール・デフォルトウェアハウスにしておく
-- （Claude DesktopからのOAuthセッションはユーザーのDEFAULT_ROLE / DEFAULT_WAREHOUSEで動作するため）
GRANT ROLE mcp_readonly_role TO USER {ユーザー名};
ALTER USER {ユーザー名} SET DEFAULT_ROLE = mcp_readonly_role;
ALTER USER {ユーザー名} SET DEFAULT_WAREHOUSE = mcp_demo_wh;
```

ファイルの準備ができたら、Snowflake CLIで実行します。

```sh
# 実行
snow sql -f setup_schema.sql -c oauth

# 確認
snow sql -q "SHOW WAREHOUSES LIKE 'mcp_demo_wh';" -c oauth
```

### サンプルデータの投入

次のようなSQLが記述されたファイルを準備します。
このSQLでは商品マスタを10件INSERTし、その後売上データを500件乱数生成・INSERTしています。

```sql:seed_data.sql
USE DATABASE mcp_demo_db;
USE SCHEMA sales_schema;
USE WAREHOUSE mcp_demo_wh;

CREATE OR REPLACE TABLE product_master (
  product_id   INT,
  product_name VARCHAR,
  category     VARCHAR,
  unit_price   NUMBER(10,2)
);

CREATE OR REPLACE TABLE sales (
  sale_id    INT,
  product_id INT,
  sold_at    DATE,
  quantity   INT,
  amount     NUMBER(10,2)
);

INSERT INTO product_master (product_id, product_name, category, unit_price) VALUES
  (1, 'ノートパソコン',              'PC',        120000),
  (2, 'ワイヤレスマウス',            '周辺機器',   2500),
  (3, 'メカニカルキーボード',        '周辺機器',   8000),
  (4, '4Kモニター',                  'PC',        35000),
  (5, 'ノイズキャンセリングヘッドホン', 'オーディオ', 28000),
  (6, 'USB-Cハブ',                   '周辺機器',   4500),
  (7, 'Webカメラ',                   '周辺機器',   6000),
  (8, 'デスクライト',                '什器',      3200),
  (9, 'オフィスチェア',              '什器',      45000),
  (10, 'ポータブルSSD',              'ストレージ', 15000);

-- 直近180日分をランダムに散らした売上を500件生成
INSERT INTO sales (sale_id, product_id, sold_at, quantity, amount)
SELECT
  SEQ4() AS sale_id,
  UNIFORM(1, 10, RANDOM()) AS product_id,
  DATEADD(DAY, -UNIFORM(0, 180, RANDOM()), CURRENT_DATE()) AS sold_at,
  UNIFORM(1, 5, RANDOM()) AS quantity,
  0 AS amount
FROM TABLE(GENERATOR(ROWCOUNT => 500));

-- unit_price × quantity で金額を後から埋める
UPDATE sales s
SET amount = p.unit_price * s.quantity
FROM product_master p
WHERE s.product_id = p.product_id;

GRANT SELECT ON TABLE mcp_demo_db.sales_schema.product_master TO ROLE mcp_readonly_role;
GRANT SELECT ON TABLE mcp_demo_db.sales_schema.sales TO ROLE mcp_readonly_role;
```

ファイルの準備ができたら、Snowflake CLIで実行します。

```sh
# 実行
snow sql -f seed_data.sql -c oauth

# 確認
snow sql -q "SELECT COUNT(*) FROM mcp_demo_db.sales_schema.sales;" -c oauth
snow sql -q "SELECT * FROM mcp_demo_db.sales_schema.product_master LIMIT 5;" -c oauth
```

## MCPサーバーを作成する

次のようなSQLが記述されたファイルを準備します。

```sql:setup_mcp.sql
CREATE OR REPLACE MCP SERVER mcp_demo_db.sales_schema.sales_analysis_mcp
  FROM SPECIFICATION $$
tools:
  - name: "execute_sql"
    type: "SYSTEM_EXECUTE_SQL"
    title: "Sales Data SQL Execution"
    description: "product_masterテーブルとsalesテーブルに対してSELECT文を実行し、売上の集計・分析を行うためのツール"
$$;

GRANT USAGE ON MCP SERVER mcp_demo_db.sales_schema.sales_analysis_mcp TO ROLE mcp_readonly_role;
```

ファイルの準備ができたら、Snowflake CLIで実行します。

```sh
# 実行
snow sql -f setup_mcp.sql -c oauth

# 確認
snow sql -q "SHOW MCP SERVERS LIKE 'sales_analysis_mcp' IN SCHEMA mcp_demo_db.sales_schema;" -c oauth
snow sql -q "DESC MCP SERVER mcp_demo_db.sales_schema.sales_analysis_mcp;" -c oauth
```

MCPサーバーを作成できたら、次のコマンドを実行してMCPサーバーのURLを取得します。
これは後ほどClaude Desktopに設定するのでメモしておいてください。

```sh
snow sql -c oauth --silent --format json \
  -q "SELECT 'https://' || REPLACE(CURRENT_ORGANIZATION_NAME() || '-' || CURRENT_ACCOUNT_NAME(), '_', '-') || '.snowflakecomputing.com/api/v2/databases/mcp_demo_db/schemas/sales_schema/mcp-servers/sales_analysis_mcp' AS mcp_server_url;" \
  | jq -r '.[0].MCP_SERVER_URL'
```

## OAuthセキュリティ統合を作成する

次のようなSQLが記述されたファイルを準備します。

```sql:setup_mcp_oauth.sql
CREATE OR REPLACE SECURITY INTEGRATION mcp_claude_oauth
  TYPE = OAUTH
  ENABLED = TRUE
  OAUTH_CLIENT = CUSTOM
  OAUTH_CLIENT_TYPE = 'CONFIDENTIAL'
  OAUTH_REDIRECT_URI = 'https://claude.ai/api/mcp/auth_callback'
  OAUTH_ENFORCE_PKCE = TRUE
  OAUTH_USE_SECONDARY_ROLES = NONE
  PRE_AUTHORIZED_ROLES_LIST = ('MCP_READONLY_ROLE')
  BLOCKED_ROLES_LIST = ('ACCOUNTADMIN', 'SECURITYADMIN', 'SYSADMIN');
```

:::message
`OAUTH_REDIRECT_URI`にはSnowflakeの公式ドキュメントに具体的な値の記載がありません。

今回`https://claude.ai/api/mcp/auth_callback`という値は、実際にClaude Desktopから接続を試みた際にブラウザが遷移したSnowflakeの認可エンドポイントのURLに含まれる`redirect_uri`パラメータをデコードして確認したものです。

Claude側の仕様変更によって変わる可能性はあるため、うまく接続できない場合は同様の手順で実際の値を確認し直してください。
:::

ファイルの準備ができたら、Snowflake CLIで実行します。

```sh
# 実行
snow sql -f setup_mcp_oauth.sql -c oauth

# クライアントID・クライアントシークレットを取得
snow sql -c oauth --silent --format json \
  -q "SELECT SYSTEM\$SHOW_OAUTH_CLIENT_SECRETS('MCP_CLAUDE_OAUTH') AS secrets;" \
  | jq -r '.[0].SECRETS | fromjson | "OAUTH_CLIENT_ID=\(.OAUTH_CLIENT_ID)\nOAUTH_CLIENT_SECRET=\(.OAUTH_CLIENT_SECRET)"'
```

`OAUTH_CLIENT_ID` および `OAUTH_CLIENT_SECRET` は後ほどClaude Desktopに設定するのでメモしておいてください。

## Claude Desktopから接続する

ここからはClaude Desktopを開いて、カスタムコネクタの追加をしていきます。
サイドバーの「カスタマイズ」をクリックし、「コネクタ」→「追加」→「カスタムコネクタを追加」の順でクリックします。

![カスタムコネクタを追加](/images/snowflake-managed-mcp-claude-desktop/001.png)

「名前」と先ほど取得した「MCPサーバーURL」を入力します。
名前は任意の名前で問題ありません。

![カスタムコネクタの情報を入力](/images/snowflake-managed-mcp-claude-desktop/002.png)

続いて、OAuthの認証情報を入力します。
こちらも先程コマンドで取得したものです。

![カスタムコネクタの情報を入力](/images/snowflake-managed-mcp-claude-desktop/003.png)

「追加」をクリックすると認証が実行されます。
ここでブラウザが開きログインを求められますので、ログインしてClaudeとの接続を完了させます。

## 動作確認

カスタムコネクタの登録が完了したら次のようにプロンプトを実行します。

カスタムコネクタの「名前」を含めたプロンプトとすると、自動的にそのコネクタを利用して答えてくれます。

![Claude Desktopと接続されたSnowflake](/images/snowflake-managed-mcp-claude-desktop/004.png)

もちろん、Claude Desktopでの登録を完了しておくと、Claudeのスマートフォンアプリからでも利用できます。
社外に営業に出ている社員が、最新の売上データをいちいちPCを開かなくてもチェックできるということです。

## クリーンアップ

クリーンアップ用のSQLを作成します。

```sql:teardown.sql
DROP MCP SERVER IF EXISTS mcp_demo_db.sales_schema.sales_analysis_mcp;
DROP SECURITY INTEGRATION IF EXISTS mcp_claude_oauth;
DROP WAREHOUSE IF EXISTS mcp_demo_wh;
DROP ROLE IF EXISTS mcp_readonly_role;
DROP DATABASE IF EXISTS mcp_demo_db;
```

これを次のコマンドで実行することでSnowflake上のリソースは削除されます。

```sh
snow sql -f teardown.sql -c oauth
```

最後にClaude Desktopのカスタムコネクタも削除しておきましょう。

## おわりに

これまでこうしたデータの分析や集計はフロントエンドを整備するか、BIツールを使うかといった選択肢しかありませんでした。
今ではClaudeのようなAIツールと連携させることでリッチなフロントエンドを作らずとも欲しいデータを必要なときに取得できるようになりました。

MCPでClaudeとSnowflakeを連携させれば週次・月次レポートの自動生成といったことも容易に実現できますし、他のコネクタと連携させてこうした定型業務をどんどん自動化できるはずです。
AIをうまく活用して、人間が必要な作業に集中できる環境を整えていきましょう。
