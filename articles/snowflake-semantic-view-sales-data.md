---
title: "商品の販売データを例にSnowflake Semantic Viewの活用方法を考えてみる"
emoji: "❄️"
type: "tech" # tech: 技術記事 / idea: アイデア
topics:
  - snowflake
  - semanticview
  - cortex
published: false
publication_name: fusic
---

## はじめに

Snowflakeの Semantic View は、テーブルやカラムに対して「商品名」「売上合計」のようなビジネス用語での意味付けを行い、その意味付けに基づいて集計クエリを発行できるようにする機能である。
生のテーブル・カラム名の代わりに、業務で使う言葉でデータを問い合わせられるようになる。

本記事では商品マスタ・売上データを例に、Semantic Viewを実際に作成し、`SELECT * FROM SEMANTIC_VIEW(...)`構文や標準SQL構文で問い合わせるところまでを一通り確認する。

それだけでは単なる構文紹介で終わってしまうため、もう一歩踏み込んで「Semantic ViewをClaude Desktop（自然言語AI）から使うことを見据えて、`WITH SYNONYMS`・`COMMENT`を日本語でどう設計すると問い合わせ精度が変わるか」を検証するのが本記事の軸である。
あらかじめ断っておくと、この検証を通して見えてきたのは「SYNONYMSを追加すれば精度が上がる」という単純な話ではなく、**そもそもLLMがSemantic Viewをどんな条件で参照しに行くのか**という、もう一段手前の論点だった。
このあたりの経緯は「Claude Desktopから自然言語で問い合わせる」の章で詳しく書く。

## 事前準備

以下の記事の手順でSnowflake CLIをセットアップし、OAuth認証のコネクション`oauth`を`~/.snowflake/config.toml`に用意しておく。

https://zenn.dev/fusic/articles/snowflake-cli-oauth

https://zenn.dev/fusic/articles/snowflake-cli-install-with-mise

接続とユーザー名を確認する。

```sh
snow connection test -c oauth
snow sql -q "SELECT CURRENT_USER();" -c oauth
```

:::message
`config.toml`にウェアハウス・ロールを指定していない場合、Snowflakeのユーザーオブジェクトに設定されたデフォルトウェアハウス・デフォルトロールが使われる。
以前の記事の検証で作成したウェアハウス・ロールをデフォルトに設定したまま、それらをdestroyで削除していると、上記コマンドが「ウェアハウスが存在しない」というエラーになったり、後述するOAuth経由のClaude Desktop接続時に`User's configured default role 'XXX' does not exist or not authorized`というエラーになったりする。
`snow sql ... --warehouse <存在するウェアハウス名>`のように毎回明示指定して回避することもできるが、根本的にはユーザーのデフォルト設定自体を今回使う値に更新しておくのが確実である。

```sql
ALTER USER {ユーザー名} SET DEFAULT_ROLE = SEMANTIC_VIEW_DEMO_ROLE;
ALTER USER {ユーザー名} SET DEFAULT_WAREHOUSE = SEMANTIC_VIEW_DEMO_WH;
```

（`SEMANTIC_VIEW_DEMO_ROLE`/`SEMANTIC_VIEW_DEMO_WH`は手順1で後述するロール・ウェアハウスなので、先に手順1を実行してから上記を流す）
:::

Semantic Viewの作成には`CREATE SEMANTIC VIEW`権限がスキーマに必要になる。
今回は専用のデータベース・スキーマ・ウェアハウス・ロールを作り、そのロールに検証に必要な権限だけを与える。
`setup_schema.sql`として保存する。

```sql
CREATE DATABASE IF NOT EXISTS semantic_view_demo_db;
CREATE SCHEMA IF NOT EXISTS semantic_view_demo_db.sales_schema;

CREATE WAREHOUSE IF NOT EXISTS semantic_view_demo_wh
  WAREHOUSE_SIZE = 'XSMALL'
  AUTO_SUSPEND = 60
  AUTO_RESUME = TRUE;

-- Semantic Viewの作成・問い合わせを行うロール
CREATE ROLE IF NOT EXISTS semantic_view_demo_role;

GRANT USAGE ON DATABASE semantic_view_demo_db TO ROLE semantic_view_demo_role;
GRANT USAGE ON SCHEMA semantic_view_demo_db.sales_schema TO ROLE semantic_view_demo_role;
GRANT USAGE ON WAREHOUSE semantic_view_demo_wh TO ROLE semantic_view_demo_role;

-- Semantic Viewを作成するための権限
GRANT CREATE SEMANTIC VIEW ON SCHEMA semantic_view_demo_db.sales_schema TO ROLE semantic_view_demo_role;
GRANT CREATE TABLE ON SCHEMA semantic_view_demo_db.sales_schema TO ROLE semantic_view_demo_role;

-- 自分のユーザーにロールを付与
GRANT ROLE semantic_view_demo_role TO USER {ユーザー名};
```

```sh
snow sql -f setup_schema.sql -c oauth
```

`SHOW GRANTS TO ROLE semantic_view_demo_role;`で`CREATE SEMANTIC VIEW`がGRANTS一覧に含まれていれば準備完了である。

## サンプルデータを投入する

商品マスタ10件・売上明細500件（乱数生成）を投入する。
`seed_data.sql`として保存する。

```sql
USE ROLE semantic_view_demo_role;
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
```

```sh
snow sql -f seed_data.sql -c oauth
```

`SELECT COUNT(*) FROM sales;`で500件、`product_master`に10件登録されていることを確認した。

## Semantic Viewを作成する

TABLES（論理テーブル）、RELATIONSHIPS（結合キー）、FACTS（行レベルの数値）、DIMENSIONS（属性・分類軸）、METRICS（集計されたKPI）の順で定義する。
`create_semantic_view.sql`として保存する。

```sql
USE ROLE semantic_view_demo_role;
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

```sh
snow sql -f create_semantic_view.sql -c oauth
```

- TABLES: 物理テーブル（`product_master`/`sales`）に`products`/`sales`という論理名を与える。
- RELATIONSHIPS: `sales.product_id`が`products.product_id`を参照する結合キーを定義する。以降のFACTS/DIMENSIONS/METRICSでJOINを書かずに両テーブルの列を扱えるようになる。
- FACTS: 集計前の行レベルの数値（1明細あたりの金額・数量）を定義する。
- DIMENSIONS: 集計の軸になる属性（商品名・カテゴリ・販売日）を定義する。`DATE_TRUNC('MONTH', sales.sold_at)`のように式で定義することもできる。
- METRICS: `SUM`/`AVG`/`COUNT`などで集計済みのKPIを定義する。

`DESC SEMANTIC VIEW`で確認したところ、TABLES/RELATIONSHIPS/FACTS/DIMENSIONS/METRICSがすべて意図通り登録されていた。

:::message
ドキュメント上は`WITH SYNONYMS ('...')`（TABLES句）と`WITH SYNONYMS = ('...')`（DIMENSIONS句）で代入演算子の表記が揺れているように見えるが、実際に上記DDLを両方の書き方が混在した状態で実行してもエラーにはならなかった。
どちらの書き方でも通ると考えてよい。
:::

## 日本語での意味付け（COMMENT・SYNONYMS）を設計する

今回のDDLでは`WITH SYNONYMS`と`COMMENT`を、後段でCortex Analystに日本語の自然文で問い合わせることを見据えて書いている。
この2つは役割が異なる。

- `WITH SYNONYMS`: そのメトリクス/ディメンション/テーブルを指す**別名の完全な候補**を列挙する。「客単価」のように業務でよく使う言い回しを、実際のカラム名（`average_amount`）とは別に登録しておくことで、Cortex Analystがその言い回しを見た瞬間に対応するメトリクスへ結びつけやすくなる。
- `COMMENT`: そのオブジェクトの意味を**説明する自然文**である。SYNONYMSに載っていない言い回しで質問された場合でも、Cortex Analyst（LLM）がCOMMENTの説明文からセマンティックに意味を推測して正しいメトリクス/ディメンションに辿り着けるかどうかに影響する。

そのため上記のDDLでは、あえて一部の業務用語（「客単価」「商品ジャンル」）をSYNONYMSに**含めない**状態で最初のSemantic Viewを作った。
この状態とシノニムを追加した後とで、Claude Desktopの回答精度がどう変わるかを次章以降で比較する。

## Semantic Viewに問い合わせる

`SELECT * FROM SEMANTIC_VIEW(...)`構文でDIMENSIONS/METRICS/FACTSを指定して問い合わせる。

### カテゴリ別の売上合計・数量

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

`GROUP BY`を明示的に書かなくても`category`単位で正しく集計される。
同じ集計を素のSQL（JOIN + GROUP BY）で書いた場合と結果を突き合わせたところ、完全に一致した。

```sql
SELECT p.category, SUM(s.amount) AS total_amount, SUM(s.quantity) AS total_quantity
FROM semantic_view_demo_db.sales_schema.sales s
JOIN semantic_view_demo_db.sales_schema.product_master p ON s.product_id = p.product_id
GROUP BY p.category
ORDER BY total_amount DESC;
```

### 月別の売上推移

```sql
SELECT * FROM SEMANTIC_VIEW(
  semantic_view_demo_db.sales_schema.sales_semantic_view
  DIMENSIONS sales.sold_month
  METRICS sales.total_amount
)
ORDER BY sold_month;
```

`sales.sold_month`は`DATE_TRUNC('MONTH', sales.sold_at)`という式で定義したディメンションだが、日付でなく月初日単位で正しくグルーピングされて返ってきた。

### 商品別の平均売上とWHERE句によるフィルタ

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

`SEMANTIC_VIEW(...)`の中に書いた`WHERE`は「集計前の行フィルタ」として効く。
`周辺機器`カテゴリの商品だけに絞られた状態で平均売上金額が算出されている。

### FACTSを使った行レベル問い合わせ

METRICSではなくFACTSを指定すると、集計されずに明細単位の行がそのまま返ってくる。

```sql
SELECT * FROM SEMANTIC_VIEW(
  semantic_view_demo_db.sales_schema.sales_semantic_view
  DIMENSIONS sales.sold_date
  FACTS sales.sale_amount
)
ORDER BY sold_date DESC
LIMIT 10;
```

:::message
FACTSとDIMENSIONSを同時に指定する場合、**すべての式が同一エンティティ由来でなければならない**という制約がある。
たとえば`DIMENSIONS products.product_name, sales.sold_date`のように`products`エンティティと`sales`エンティティのディメンションを混在させてFACTSと一緒に指定すると、以下のエラーになる。

```
SQL compilation error: Invalid semantic view query: All expressions
referenced in the query must come from the same entity when both
FACTS and DIMENSIONS are specified.
```

商品名（products側）と販売日・売上金額（sales側）を1つのFACTSクエリで一緒に取得することはできず、DIMENSIONSを`sales`エンティティのものだけに絞る必要がある。
明細に商品名も含めたい場合は、FACTSではなくMETRICS（例えば`COUNT`のような集計を経由しないダミーの集計）を使うか、素のSQLでJOINする方が素直である。
:::

### 標準SQLでSemantic Viewを問い合わせる

`SELECT * FROM SEMANTIC_VIEW(...)`という専用構文を使わず、通常の`SELECT`文でSemantic Viewを問い合わせることもできる。
ただし、METRICSをそのまま`SELECT`すると通常の集計関数と同様に「集約関数でもGROUP BY句にもない」というエラーになる。

```sql
-- エラーになる
SELECT category, total_amount
FROM semantic_view_demo_db.sales_schema.sales_semantic_view
GROUP BY category
ORDER BY total_amount DESC;
```

METRICSを`AGG(...)`でラップすると動作し、`SEMANTIC_VIEW(...)`構文と同じ結果が得られた。

```sql
SELECT category, AGG(total_amount) AS total_amount
FROM semantic_view_demo_db.sales_schema.sales_semantic_view
GROUP BY category
ORDER BY total_amount DESC;
```

どちらの構文でも同じ結果になるが、`SEMANTIC_VIEW(...)`構文の方がDIMENSIONS/METRICS/FACTS/WHEREの役割が読みやすく、記事内のサンプルとしても意図が伝わりやすいため、本記事ではこちらを主軸にする。

## Claude Desktopから自然言語で問い合わせる（発展）

Semantic ViewはSQLの一部として問い合わせられるため、SQLを実行できるMCPサーバー（`SYSTEM_EXECUTE_SQL`タイプ）があれば、Cortex Analyst専用のツールを別途用意しなくてもClaude Desktopから自然言語で問い合わせられる。
Claude Desktop側のOAuth接続設定など、MCPサーバーへの接続手順そのものは本記事では扱わない（[MCPサーバーの記事](https://zenn.dev/fusic/articles/snowflake-managed-mcp-claude-desktop)を参照）。

Snowflake側では`setup_mcp.sql`として、汎用のSQL実行ツールを持つMCPサーバーを作成し、Semantic ViewへのSELECT権限を付与する。

```sql
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
GRANT SELECT ON SEMANTIC VIEW semantic_view_demo_db.sales_schema.sales_semantic_view TO ROLE semantic_view_demo_role;
```

```sh
snow sql -f setup_mcp.sql -c oauth --warehouse semantic_view_demo_wh
```

:::message
`CREATE MCP SERVER`にはスキーマに対する`CREATE MCP SERVER`権限が必要である。
手順1で作成したロールにはこの権限を付与していなかったため、以下のGRANTを追加で実行した。

```sql
GRANT CREATE MCP SERVER ON SCHEMA semantic_view_demo_db.sales_schema TO ROLE semantic_view_demo_role;
```
:::

MCPツールの`description`はSQL実行ツールとしての説明であり、Semantic View自体の`WITH SYNONYMS`・`COMMENT`とは役割が異なる。
Claude Desktopはこの`description`から「どんなデータに問い合わせられるツールか」を把握し、実際にどのメトリクス・ディメンションを使うかはSemantic View側の`DESC SEMANTIC VIEW`で取得できるメタデータ（COMMENT・SYNONYMS）を手がかりに判断する。

MCPサーバーのURLを取得する。

```sh
snow sql -c oauth --silent --format json \
  -q "SELECT 'https://' || REPLACE(CURRENT_ORGANIZATION_NAME() || '-' || CURRENT_ACCOUNT_NAME(), '_', '-') || '.snowflakecomputing.com/api/v2/databases/semantic_view_demo_db/schemas/sales_schema/mcp-servers/sales_analysis_mcp' AS mcp_server_url;" \
  | jq -r '.[0].MCP_SERVER_URL'
```

Claude DesktopからこのMCPサーバーに接続するためのOAuthセキュリティ統合を作成する。
`setup_mcp_oauth.sql`として保存する。

```sql
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

```sh
snow sql -f setup_mcp_oauth.sql -c oauth

# クライアントID・クライアントシークレットを取得
snow sql -c oauth --silent --format json \
  -q "SELECT SYSTEM\$SHOW_OAUTH_CLIENT_SECRETS('MCP_CLAUDE_OAUTH') AS secrets;" \
  | jq -r '.[0].SECRETS | fromjson | "OAUTH_CLIENT_ID=\(.OAUTH_CLIENT_ID)\nOAUTH_CLIENT_SECRET=\(.OAUTH_CLIENT_SECRET)"'
```

取得したクライアントID・シークレットとMCPサーバーのURLをClaude Desktopのカスタムコネクタ設定に登録すれば接続できる。
具体的なClaude Desktop側の操作手順は[MCPサーバーの記事](https://zenn.dev/fusic/articles/snowflake-managed-mcp-claude-desktop)を参照。

:::message
Claude DesktopからOAuth接続を試みたところ、`User's configured default role 'MCP_READONLY_ROLE' does not exist or not authorized`というエラーになった。
これは事前準備で触れた「以前の記事の検証環境をdestroyした後もユーザーのデフォルトロールが古い値のまま残っていた」ことが原因である。
事前準備の`ALTER USER ... SET DEFAULT_ROLE = SEMANTIC_VIEW_DEMO_ROLE;`を実行してデフォルトロールを更新したところ、接続できるようになった。
:::

### そのまま日本語で聞いてみる

シノニムをまだ追加していない状態（手順3で最初に作ったSemantic View）のまま、素直に日本語で質問してみる。

**「客単価を教えて」**

回答は以下のようになった。

> SALESテーブル（SEMANTIC_VIEW_DEMO_DB.SALES_SCHEMA.SALES、全500件）を集計した結果です。
>
> 取引件数: 500件
> 売上合計: 42,877,900円
> 客単価（1取引あたり平均金額）: 約85,755.8円

数値自体は正しい（後述するSemantic View経由の値と一致する）が、実際に実行されたSQLを確認すると次のようになっていた。

```sql
SELECT * FROM SEMANTIC_VIEW_DEMO_DB.SALES_SCHEMA.SALES LIMIT 10;

SELECT COUNT(*) AS sale_count, SUM(AMOUNT) AS total_amount, AVG(AMOUNT) AS avg_amount
FROM SEMANTIC_VIEW_DEMO_DB.SALES_SCHEMA.SALES;
```

`SHOW SEMANTIC VIEWS`や`DESC SEMANTIC VIEW`、`SELECT * FROM SEMANTIC_VIEW(...)`は一度も呼ばれていない。
Claude Desktopは`sales_semantic_view`というSemantic Viewの存在に気づかないまま、生の`SALES`テーブルを直接調べて自力で集計している。

**「商品ジャンルごとの売上を見せて」**

こちらも正しい数値（PC 26,810,000円、什器 7,194,400円、オーディオ 3,920,000円、周辺機器 2,943,500円、ストレージ 2,010,000円）が返ってきたが、`sales`と`product_master`のJOINキーが素直に推測できるため、こちらもおそらくSemantic Viewを経由せず素のJOIN + GROUP BYで答えている。

:::message
今回使ったのは`SYSTEM_EXECUTE_SQL`タイプの汎用SQL実行ツールであり、Cortex Analyst専用の`CORTEX_ANALYST_MESSAGE`タイプではない。
そのためClaude Desktopは「まずSemantic Viewを探す」という行動を自発的には取らず、素朴なSQLで答えが出せるならそちらを優先する、という挙動になったと考えられる。
:::

### シノニムを追加する前後で回答精度を比較する

当初の想定では、SYNONYMSに「客単価」「商品ジャンル」を追加する前後で、Claude Desktopの回答精度に差が出るかを比較するつもりだった。
しかし上記の通り、そもそもClaude DesktopがSemantic Viewを経由せず生テーブルに直接クエリしてしまうため、SYNONYMSを追加してもしなくても回答は変わらなかった（実際に`add_synonyms.sql`でシノニムを追加した後、同じ「客単価を教えて」を新しい会話で聞いても、生テーブルへの同じSQLが実行され、同じ回答になった）。

そこで質問の仕方を変え、**「Semantic Viewを使って客単価を教えて」のようにSemantic Viewの利用を明示的に指示した場合**にどうなるかを試した。

**SYNONYMSに「客単価」を追加した状態（After）で指示した場合**

```
Snowflakeのカスタムコネクタで Semantic View を使って客単価を集計します。まずツールをロードして、
利用可能な Semantic View を確認します。

SALES_SEMANTIC_VIEW が見つかりました。次に定義（メトリクス・ディメンション）を確認します。

AVERAGE_AMOUNT（客単価/AVG(sales.sale_amount)）というメトリクスが定義されているので、これを使って集計します。

客単価: 85,755.80円
```

Semantic Viewを発見 → `DESC SEMANTIC VIEW`相当でメタデータを確認 → `AVERAGE_AMOUNT`のCOMMENT・SYNONYMSから「客単価」に対応すると判断、という流れで正しいメトリクスに辿り着いた。

**COMMENT・SYNONYMSから「客単価」を外したBefore状態に戻し、同じ指示をした場合**

`create_semantic_view.sql`を再実行してSemantic Viewを最初のBefore状態（`average_amount`のCOMMENTは「1明細あたりの平均売上金額」のみで、「客単価」という単語も`WITH SYNONYMS`もない）に戻し、新しい会話で同じく「Semantic Viewを使って客単価を教えて」と聞いたところ、次の回答になった。

```
このSemantic Viewには「顧客」を示すディメンションがなく、SALESテーブルは1行=1販売レコード（取引単位）です。
そのため「客単価」に最も対応する指標は SALES.AVERAGE_AMOUNT（1明細あたりの平均売上金額）になります。

客単価: 85,755.8円
この値は Semantic View の指標 SALES.AVERAGE_AMOUNT（定義: AVG(sales.sale_amount) = 1明細あたりの平均売上金額）
から取得しました。
```

SYNONYMSにもCOMMENTにも「客単価」という単語が一切含まれていないにもかかわらず、Claude Desktopは`AVERAGE_AMOUNT`のCOMMENT（自然文）だけを手がかりに、正しいメトリクスに辿り着いた。

**わかったこと**

当初「SYNONYMSの有無で回答精度が変わる」という仮説を立てていたが、実際のボトルネックはそこではなかった。

- 汎用SQL実行ツール経由の場合、Claude Desktopは指示がない限りSemantic Viewを自発的に見に行かず、生テーブルへの素朴なSQLで済ませてしまう。SYNONYMS/COMMENTをどれだけ丁寧に設計しても、そもそもSemantic Viewが参照されなければ効果は発揮されない。
- 一方、「Semantic Viewを使って」と一言指示するだけでSemantic Viewを参照するようになり、その状態になれば、SYNONYMSの完全一致がなくてもCOMMENTの自然文だけでClaude（LLM自身の言語理解力）は十分正しいメトリクスに辿り着けた。

つまり、日本語での意味付け（COMMENT・SYNONYMS）の設計がそのまま活きるかどうかは、**LLMが実際にSemantic Viewのメタデータを読みに行くかどうか**という、もう一段手前の条件に左右される。
Cortex Analyst専用のツール（`CORTEX_ANALYST_MESSAGE`）であれば、内部的にSemantic Viewの参照が前提になっている可能性が高く、SYNONYMSの完全一致がより重要な役割を持つと考えられるが、これは本記事の検証範囲外である。
汎用SQL実行ツールでSemantic Viewを活用したい場合は、ツールの`description`やシステムプロンプト側で「Semantic Viewがあれば優先的に参照すること」を明示しておく必要がありそうだ。

## クリーンアップ

検証で作成したオブジェクトを削除する。
`teardown.sql`として保存する。

```sql
USE ROLE semantic_view_demo_role;
DROP MCP SERVER IF EXISTS semantic_view_demo_db.sales_schema.sales_analysis_mcp;
DROP SEMANTIC VIEW IF EXISTS semantic_view_demo_db.sales_schema.sales_semantic_view;

USE ROLE SYSADMIN;
DROP WAREHOUSE IF EXISTS semantic_view_demo_wh;
DROP DATABASE IF EXISTS semantic_view_demo_db;
DROP ROLE IF EXISTS semantic_view_demo_role;
```

```sh
snow sql -f teardown.sql -c oauth
```

Claude Desktop連携のためにOAuthセキュリティ統合を作った場合は、こちらも削除しておく。

```sql
DROP SECURITY INTEGRATION IF EXISTS mcp_claude_oauth;
```

Claude Desktop側に追加したカスタムコネクタも、不要であれば合わせて削除しておく。

## おわりに

Semantic Viewは、通常のVIEWとは違って「テーブル間の結合定義」「集計済みのメトリクス」「意味付けのための日本語COMMENT・SYNONYMS」をまとめて宣言的に管理できる点が大きな違いだと感じた。
`SELECT * FROM SEMANTIC_VIEW(...)`構文でJOINやGROUP BYを書かずに集計できる手軽さは、ビジネスユーザー向けの定型的な分析クエリを整備する場面で特に活きそうである。

一方で、当初想定していた「`WITH SYNONYMS`・`COMMENT`を日本語でどう設計すれば自然言語AIからの問い合わせ精度が上がるか」という検証は、実際にやってみると想定と違う角度の学びになった。
汎用のSQL実行MCPツール経由でClaude Desktopに問い合わせる場合、そもそもLLMがSemantic Viewの存在に気づいて参照しに行くかどうかが最初の関門であり、そこさえクリアすれば、COMMENTの自然な日本語の説明文だけでもLLM自身の言語理解力でかなり正確にメトリクスへ辿り着けることがわかった。
SYNONYMSによる完全一致の登録は「保険」としては有効そうだが、少なくとも今回のClaude Desktop + 汎用SQLツールという組み合わせでは、COMMENTの説明文の質の方が効いていた印象である。

Cortex Analyst専用のMCPツール（`CORTEX_ANALYST_MESSAGE`タイプ）を使った場合にどう違うかは今回検証できていない。
Cortex Analystは内部的にSemantic Viewの参照を前提とした設計になっている可能性が高く、SYNONYMSの完全一致がより効いてくる、あるいは逆にLLMほど柔軟な言い換えの解釈はできない、といった違いが出るかもしれない。
この比較は今後の検証課題としたい。
