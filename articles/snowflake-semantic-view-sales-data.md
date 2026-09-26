---
title: "Snowflake Semantic Viewの効果を商品の販売データを例に検証する"
emoji: "❄️"
type: "tech" # tech: 技術記事 / idea: アイデア
topics:
  - snowflake
  - semanticview
  - claude
published: true
published_at: "2026-09-28 07:30"
publication_name: fusic
---

## はじめに

SnowflakeのSemantic Viewは、テーブルやカラムに業務的な名前・説明を与えたり、「売上合計」「客単価」のような集計をあらかじめメトリクスとして定義したりできる機能です。
2025年6月にGAし、その後も機能拡充が続いています。

https://docs.snowflake.com/ja/user-guide/views-semantic/overview

生のテーブル・カラム名の代わりに、業務で使う言葉でデータを問い合わせられるようになります。

本記事では商品マスタ・売上データを例に、Semantic Viewを実際に作成します。
そして、`SELECT * FROM SEMANTIC_VIEW(...)`構文や標準SQL構文で問い合わせたときの挙動を検証します。

加えて、「Claude Desktopとの連携を見据え、`WITH SYNONYMS`・`COMMENT`を使って日本語の意味づけをした際の効果」も検証します。

![](/images/snowflake-semantic-view-sales-data/004.png)

## 事前準備

Snowflake CLIが接続されていることを前提とします。
また、`CREATE SEMANTIC VIEW`権限を持つロール（ACCOUNTADMINなど）が使える前提とします。

https://zenn.dev/fusic/articles/snowflake-cli-install-with-mise
https://zenn.dev/fusic/articles/snowflake-cli-oauth

検証用のデータベース・スキーマ・ウェアハウスを作るクエリを`setup_schema.sql`として保存し、`snow` コマンドで実行します。
Connection名が `oauth` である前提で記載しているので、適宜置き換えてください。

```sql:setup_schema.sql
USE ROLE ACCOUNTADMIN;

CREATE DATABASE IF NOT EXISTS semantic_view_demo_db;
CREATE SCHEMA IF NOT EXISTS semantic_view_demo_db.sales_schema;

CREATE WAREHOUSE IF NOT EXISTS semantic_view_demo_wh
  WAREHOUSE_SIZE = 'XSMALL'
  AUTO_SUSPEND = 60
  AUTO_RESUME = TRUE;
```

```sh
snow sql -f setup_schema.sql -c oauth
```

## サンプルデータを投入する

商品マスタ10件・売上明細500件（乱数生成）を投入するためのクエリを`seed_data.sql`として保存し、`snow` コマンドで実行します。

```sql:seed_data.sql
USE ROLE ACCOUNTADMIN;
USE DATABASE semantic_view_demo_db;
USE SCHEMA sales_schema;
USE WAREHOUSE semantic_view_demo_wh;

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
  (1, 'ノートパソコン', 'PC', 120000),
  (2, 'ワイヤレスマウス', '周辺機器', 2500),
  (3, 'メカニカルキーボード', '周辺機器', 8000),
  (4, '4Kモニター', 'PC', 35000),
  (5, 'ノイズキャンセリングヘッドホン', 'オーディオ', 28000),
  (6, 'USB-Cハブ', '周辺機器', 4500),
  (7, 'Webカメラ', '周辺機器', 6000),
  (8, 'デスクライト', '什器', 3200),
  (9, 'オフィスチェア', '什器', 45000),
  (10, 'ポータブルSSD', 'ストレージ', 15000);

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
```

```sh
snow sql -f seed_data.sql -c oauth
```

実行後、念のため2つのテーブルのレコード件数を確認します。

```sh
snow sql -q "SELECT COUNT(*) FROM semantic_view_demo_db.sales_schema.sales;" -c oauth
snow sql -q "SELECT COUNT(*) FROM semantic_view_demo_db.sales_schema.product_master;" -c oauth
```

```
+----------+
| COUNT(*) |
|----------|
| 500      |
+----------+

+----------+
| COUNT(*) |
|----------|
| 10       |
+----------+
```

想定通り、`sales`に500件、`product_master`に10件登録されていることがわかります。

## Semantic Viewを作成する

Semantic ViewはTABLES（論理テーブル）、RELATIONSHIPS（結合キー）、FACTS（行レベルの数値）、DIMENSIONS（属性・分類軸）、METRICS（集計されたKPI）の順で定義します。
作成クエリを`create_semantic_view.sql`として保存します。

```sql:create_semantic_view.sql
USE ROLE ACCOUNTADMIN;
USE DATABASE semantic_view_demo_db;
USE SCHEMA sales_schema;

CREATE OR REPLACE SEMANTIC VIEW sales_semantic_view
  TABLES (
    products AS product_master
      PRIMARY KEY (product_id)
      WITH SYNONYMS ('商品マスタ', 'product master')
      COMMENT = '商品マスタ',
    sales AS sales
      PRIMARY KEY (sale_id)
      WITH SYNONYMS ('売上明細', 'sales data')
      COMMENT = '売上明細（1行 = 1販売レコード）'
  )

  RELATIONSHIPS (
    sales_to_products AS
      sales (product_id) REFERENCES products (product_id)
  )

  FACTS (
    sales.sale_amount AS sales.amount
      COMMENT = '1明細あたりの売上金額',
    sales.sale_quantity AS sales.quantity
      COMMENT = '1明細あたりの販売数量'
  )

  DIMENSIONS (
    products.product_name AS products.product_name
      WITH SYNONYMS = ('商品名', 'product name')
      COMMENT = '商品名',
    products.category AS products.category
      WITH SYNONYMS = ('カテゴリ', 'category')
      COMMENT = '商品カテゴリ',
    sales.sold_date AS sales.sold_at
      COMMENT = '販売日',
    sales.sold_month AS DATE_TRUNC('MONTH', sales.sold_at)
      COMMENT = '販売月（月初日）'
  )

  METRICS (
    sales.total_amount AS SUM(sales.sale_amount)
      COMMENT = '売上金額の合計',
    sales.total_quantity AS SUM(sales.sale_quantity)
      COMMENT = '販売数量の合計',
    sales.average_amount AS AVG(sales.sale_amount)
      COMMENT = '1明細あたりの平均売上金額',
    products.product_count AS COUNT(products.product_id)
      COMMENT = '商品数'
  )

  COMMENT = '商品マスタと売上明細を組み合わせた販売分析用Semantic View';
```

準備ができたら `snow` コマンドで実行しましょう。

```sh
snow sql -f create_semantic_view.sql -c oauth
```

作成したSemantic Viewは次のような内容となっています。

| 句 | 役割 |
| --- | --- |
| TABLES | 物理テーブル（`product_master`/`sales`）に`products`/`sales`という論理名を与える |
| RELATIONSHIPS | `sales.product_id`が`products.product_id`を参照する結合キーを定義する。以降のFACTS/DIMENSIONS/METRICSでJOINを書かずに両テーブルの列を扱えるようになる |
| FACTS | 集計前の行レベルの数値（1明細あたりの金額・数量）を定義する |
| DIMENSIONS | 集計の軸になる属性（商品名・カテゴリ・販売日）を定義する。`DATE_TRUNC('MONTH', sales.sold_at)`のように式で定義することもできる |
| METRICS | `SUM`/`AVG`/`COUNT`などで集計済みのKPIを定義する |

念のため、次のクエリで定義内容を確認します。

```sh
snow sql -q "DESC SEMANTIC VIEW semantic_view_demo_db.sales_schema.sales_semantic_view;" -c oauth
```

TABLES/RELATIONSHIPS/FACTS/DIMENSIONS/METRICSがすべて意図通り登録されていることが確認できるはずです。

## Semantic Viewに問い合わせる

Semantic Viewを作成できたら、 `SELECT * FROM SEMANTIC_VIEW(...)`構文でDIMENSIONS/METRICS/FACTSを指定して問い合わせてみます。

### カテゴリ別の売上合計・数量

次のようなクエリで問い合わせます。

```sql
SELECT * FROM SEMANTIC_VIEW(
  semantic_view_demo_db.sales_schema.sales_semantic_view
  DIMENSIONS products.category
  METRICS sales.total_amount, sales.total_quantity
)
ORDER BY total_amount DESC;
```

| CATEGORY | TOTAL_AMOUNT | TOTAL_QUANTITY |
| --- | --- | --- |
| PC | 26810000.00 | 341 |
| 什器 | 7194400.00 | 315 |
| オーディオ | 3920000.00 | 140 |
| 周辺機器 | 2943500.00 | 543 |
| ストレージ | 2010000.00 | 134 |

`GROUP BY`を明示的に書かなくても`category`単位で正しく集計されていますね。
念のため、同じ集計を素のSQL（JOIN + GROUP BY）で書いた場合と結果を突き合わせたところ、完全に一致していました。

```sql
SELECT p.category, SUM(s.amount) AS total_amount, SUM(s.quantity) AS total_quantity
FROM semantic_view_demo_db.sales_schema.sales s
JOIN semantic_view_demo_db.sales_schema.product_master p ON s.product_id = p.product_id
GROUP BY p.category
ORDER BY total_amount DESC;
```

### 商品別の平均売上とWHERE句によるフィルタ

次のようなクエリで問い合わせます。

```sql
SELECT * FROM SEMANTIC_VIEW(
  semantic_view_demo_db.sales_schema.sales_semantic_view
  DIMENSIONS products.product_name
  METRICS sales.average_amount, sales.total_quantity
  WHERE products.category = '周辺機器'
)
ORDER BY average_amount DESC;
```

| PRODUCT_NAME | AVERAGE_AMOUNT | TOTAL_QUANTITY |
| --- | --- | --- |
| メカニカルキーボード | 24510.64 | 144 |
| Webカメラ | 17500.00 | 140 |
| USB-Cハブ | 12905.66 | 152 |
| ワイヤレスマウス | 6858.97 | 107 |

`SEMANTIC_VIEW(...)`の中に書いた`WHERE`は「集計前の行フィルタ」として適用されることが確認できました。
指定のとおり、`周辺機器`カテゴリの商品だけに絞られた状態で平均売上金額が算出されています。

### 標準SQLでSemantic Viewを問い合わせる

`SELECT * FROM SEMANTIC_VIEW(...)`という専用構文を使わず、通常の`SELECT`文でSemantic Viewを問い合わせることもできます。
ただし、METRICSをそのまま`SELECT`すると通常の集計関数と同様に「集約関数でもGROUP BY句にもない」というエラーが表示されました。

```sql
-- エラーになる
SELECT category, total_amount
FROM semantic_view_demo_db.sales_schema.sales_semantic_view
GROUP BY category
ORDER BY total_amount DESC;
```

METRICSを`AGG(...)`でラップすると動作し、`SEMANTIC_VIEW(...)`構文と同じ結果が得られました。

```sql
SELECT category, AGG(total_amount) AS total_amount
FROM semantic_view_demo_db.sales_schema.sales_semantic_view
GROUP BY category
ORDER BY total_amount DESC;
```

## Claude Desktopから自然言語で問い合わせる

### MCPサーバーの準備

Claude Desktopから問い合わせられるようにするため、MCPサーバーを準備します。

MCPサーバーを構築するクエリを`setup_mcp.sql`として保存します。
加えてここでは、Claude Desktopからの接続専用ロールを作成し、必要な権限だけを与えています。
そのロールを使用して汎用のSQL実行ツールを持つMCPサーバーを作成します。

```sql:setup_mcp.sql
USE ROLE ACCOUNTADMIN;

-- Claude Desktopからの接続専用ロール（最小権限）
CREATE ROLE IF NOT EXISTS semantic_view_demo_role;

GRANT USAGE ON DATABASE semantic_view_demo_db TO ROLE semantic_view_demo_role;
GRANT USAGE ON SCHEMA semantic_view_demo_db.sales_schema TO ROLE semantic_view_demo_role;
GRANT USAGE ON WAREHOUSE semantic_view_demo_wh TO ROLE semantic_view_demo_role;
GRANT SELECT ON ALL TABLES IN SCHEMA semantic_view_demo_db.sales_schema TO ROLE semantic_view_demo_role;
GRANT SELECT ON SEMANTIC VIEW semantic_view_demo_db.sales_schema.sales_semantic_view TO ROLE semantic_view_demo_role;
GRANT CREATE MCP SERVER ON SCHEMA semantic_view_demo_db.sales_schema TO ROLE semantic_view_demo_role;

-- 自分のユーザーにロールを付与
GRANT ROLE semantic_view_demo_role TO USER {ユーザー名};

USE ROLE semantic_view_demo_role;

CREATE OR REPLACE MCP SERVER semantic_view_demo_db.sales_schema.sales_analysis_mcp
  FROM SPECIFICATION $$
tools:
  - name: "execute_sql"
    type: "SYSTEM_EXECUTE_SQL"
    title: "Sales Data SQL Execution"
    description: "product_master/salesテーブル、およびsales_semantic_view（Semantic View）に対してSELECT文を実行し、売上の集計・分析を行うためのツール"
    config:
      read_only: true
      query_timeout: 120
      warehouse: "semantic_view_demo_wh"
$$;

GRANT USAGE ON MCP SERVER semantic_view_demo_db.sales_schema.sales_analysis_mcp TO ROLE semantic_view_demo_role;
```

クエリを実行し、MCPサーバーのURLを取得します。

```sh
snow sql -f setup_mcp.sql -c oauth --warehouse semantic_view_demo_wh

snow sql -c oauth --silent --format json \
  -q "SELECT 'https://' || REPLACE(CURRENT_ORGANIZATION_NAME() || '-' || CURRENT_ACCOUNT_NAME(), '_', '-') || '.snowflakecomputing.com/api/v2/databases/semantic_view_demo_db/schemas/sales_schema/mcp-servers/sales_analysis_mcp' AS mcp_server_url;" \
  | jq -r '.[0].MCP_SERVER_URL'
```

Claude DesktopからこのMCPサーバーに接続するためのOAuthセキュリティ統合を作成します。
`setup_mcp_oauth.sql`として保存します。

```sql:setup_mcp_oauth.sql
CREATE OR REPLACE SECURITY INTEGRATION mcp_claude_oauth
  TYPE = OAUTH
  ENABLED = TRUE
  OAUTH_CLIENT = CUSTOM
  OAUTH_CLIENT_TYPE = 'CONFIDENTIAL'
  OAUTH_REDIRECT_URI = 'https://claude.ai/api/mcp/auth_callback'
  OAUTH_ENFORCE_PKCE = TRUE
  OAUTH_USE_SECONDARY_ROLES = NONE
  PRE_AUTHORIZED_ROLES_LIST = ('SEMANTIC_VIEW_DEMO_ROLE')
  BLOCKED_ROLES_LIST = ('ACCOUNTADMIN', 'SECURITYADMIN', 'SYSADMIN');
```

こちらもクエリを実行し、クライアントID・シークレットを取得します。

```sh
snow sql -f setup_mcp_oauth.sql -c oauth

snow sql -c oauth --silent --format json \
  -q "SELECT SYSTEM\$SHOW_OAUTH_CLIENT_SECRETS('MCP_CLAUDE_OAUTH') AS secrets;" \
  | jq -r '.[0].SECRETS | fromjson | "OAUTH_CLIENT_ID=\(.OAUTH_CLIENT_ID)\nOAUTH_CLIENT_SECRET=\(.OAUTH_CLIENT_SECRET)"'
```

取得したクライアントID・シークレットとMCPサーバーのURLをClaude Desktopのカスタムコネクタ設定に登録すれば接続できます。
具体的なClaude Desktop側の操作手順は[MCPサーバーの記事](https://zenn.dev/fusic/articles/snowflake-managed-mcp-claude-desktop)を参照ください。

### 日本語で問い合わせる

今回は一例として **「客単価を教えて」** という質問をしてみました。
結果は、次のような回答でした。

![](/images/snowflake-semantic-view-sales-data/002.png)

数値自体は正しいものの、実際に実行されたSQLを確認すると次の内容で、Semantic Viewは使用されていませんでした。
`sales_semantic_view`というSemantic Viewの存在に気づかないまま、生の`SALES`テーブルを直接調べて自力で集計していたようです。

そこで次は **「Semantic Viewを使って客単価を教えて」** と問い合わせてみることにしました。
次のような結果が返ってきました。

![](/images/snowflake-semantic-view-sales-data/003.png)

こちらも正しく計算はできているのですが、「客単価」の計算方法はClaudeが勝手に解釈しているようです。
若干思考のコストがかかっていることも見て取れます。

### シノニムを追加する前後で回答精度を比較する

シノニムは`add_synonyms.sql`として保存し、追加しました。

```sql:add_synonyms.sql
USE ROLE ACCOUNTADMIN;
USE DATABASE semantic_view_demo_db;
USE SCHEMA sales_schema;

CREATE OR REPLACE SEMANTIC VIEW sales_semantic_view
  TABLES (
    products AS product_master
      PRIMARY KEY (product_id)
      WITH SYNONYMS ('商品マスタ', 'product master')
      COMMENT = '商品マスタ',
    sales AS sales
      PRIMARY KEY (sale_id)
      WITH SYNONYMS ('売上明細', 'sales data')
      COMMENT = '売上明細（1行 = 1販売レコード）'
  )

  RELATIONSHIPS (
    sales_to_products AS
      sales (product_id) REFERENCES products (product_id)
  )

  FACTS (
    sales.sale_amount AS sales.amount
      COMMENT = '1明細あたりの売上金額',
    sales.sale_quantity AS sales.quantity
      COMMENT = '1明細あたりの販売数量'
  )

  DIMENSIONS (
    products.product_name AS products.product_name
      WITH SYNONYMS = ('商品名', 'product name')
      COMMENT = '商品名',
    products.category AS products.category
      WITH SYNONYMS = ('カテゴリ', 'category', '商品ジャンル')
      COMMENT = '商品カテゴリ（商品ジャンル）',
    sales.sold_date AS sales.sold_at
      COMMENT = '販売日',
    sales.sold_month AS DATE_TRUNC('MONTH', sales.sold_at)
      COMMENT = '販売月（月初日）'
  )

  METRICS (
    sales.total_amount AS SUM(sales.sale_amount)
      COMMENT = '売上金額の合計',
    sales.total_quantity AS SUM(sales.sale_quantity)
      COMMENT = '販売数量の合計',
    sales.average_amount AS AVG(sales.sale_amount)
      WITH SYNONYMS = ('客単価', 'average order value')
      COMMENT = '1明細あたりの平均売上金額（客単価）',
    products.product_count AS COUNT(products.product_id)
      COMMENT = '商品数'
  )

  COMMENT = '商品マスタと売上明細を組み合わせた販売分析用Semantic View';
```

再度実行します。

```sh
snow sql -f add_synonyms.sql -c oauth
```

これで`AVERAGE_AMOUNT`が「客単価」を指すことがAIに伝わるようになりました。

### 再度日本語で問い合わせる

再度、 **「Semantic Viewを使って客単価を教えて」** と問い合わせてみます。

![](/images/snowflake-semantic-view-sales-data/004.png)

Semantic Viewを発見 → `DESC SEMANTIC VIEW`相当でメタデータを確認し、`AVERAGE_AMOUNT`のCOMMENT・SYNONYMSから「客単価」に対応すると判断、という流れで正しいメトリクスに辿り着いていることがわかります。

回答の内容もシンプルですし、思考が最小限で済む分、回答までにかかる時間も速かったです。

## おわりに

Semantic Viewは、通常のVIEWとは違って「テーブル間の結合定義」「集計済みのメトリクス」「意味付けのための日本語COMMENT・SYNONYMS」をまとめて宣言的に管理できる点が大きな違いであることがわかりました。

Claude等のAIからの問い合わせ時にSemantic Viewを参照することで、「客単価」のような人や部署によって解釈が変わりうるビジネス用語の解釈がずれにくくなります。
組織の暗黙知を明確化するという意味でも役立ちそうですね。
