# 商品の販売データを例にSnowflake Semantic Viewの活用方法を考えてみる 検証手順

記事: `articles/snowflake-semantic-view-sales-data.md`（雛形作成済み）

Snowflake CLIのみで完結させる。以下のSQLをそのままファイルに保存して`snow sql -f`で実行すれば再現できるレベルまで具体化した。
接続はOAuth認証（[snowflake-cli-oauth.md](articles/snowflake-cli-oauth.md)の方式）を前提とし、コネクション名 `oauth` が `~/.snowflake/config.toml` に設定済みであるものとする。
`{ユーザー名}` は各自のSnowflakeユーザー名に読み替える。

サンプルデータは[snowflake-managed-mcp-claude-desktop-plan.md](snowflake-managed-mcp-claude-desktop-plan.md)の`mcp_demo_db.sales_schema`と同じ構造（商品マスタ・売上）を採用しつつ、Semantic View単体で完結する検証にするため、データベースは独立させた（`semantic_view_demo_db`）。MCP記事が先に公開されている場合は、本文中で「以前MCPサーバーの記事で使ったのと同じデータです」と触れる程度に留める。

**記事の軸**: 今回はSemantic Viewの構文紹介だけで終わらせず、「自然言語AI（Claude Desktop）から使うことを見据えて、`WITH SYNONYMS`・`COMMENT`を日本語でどう設計すると問い合わせ精度が変わるか」を検証の中心に据える。手順3で日本語での意味付けの設計方針を、手順5でClaude Desktopへの日本語自然言語問い合わせの精度がシノニム追加の前後でどう変わるかをBefore/Afterで確認する。
Cortex Analyst専用のMCPツールは使わず、既存の汎用SQL実行MCPサーバー経由でClaude Desktop自身にSemantic Viewのメタデータを読ませて問い合わせさせる。

## 0. 前提確認

コネクション `oauth` が使える状態になっていることを確認する。

```sh
snow connection test -c oauth

# 自分のユーザー名を確認
snow sql -q "SELECT CURRENT_USER();" -c oauth
```

:::message
Semantic Viewの作成には `CREATE SEMANTIC VIEW` 権限がスキーマに必要。今回はACCOUNTADMIN相当（またはSYSADMIN）の権限を持つユーザーで検証する前提とし、権限周りで詰まった場合は手順1のGRANT文を見直す。
:::

## 1. データベース・スキーマ・ウェアハウス・ロールを作る

`setup_schema.sql` として保存する。

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

-- Claude Desktopから問い合わせるためのMCPサーバーを作成するための権限
GRANT CREATE MCP SERVER ON SCHEMA semantic_view_demo_db.sales_schema TO ROLE semantic_view_demo_role;

-- 自分のユーザーにロールを付与
GRANT ROLE semantic_view_demo_role TO USER {ユーザー名};
```

実行:

```sh
snow sql -f setup_schema.sql -c oauth
```

確認:

```sh
snow sql -q "SHOW WAREHOUSES LIKE 'semantic_view_demo_wh';" -c oauth
snow sql -q "SHOW GRANTS TO ROLE semantic_view_demo_role;" -c oauth
# CREATE SEMANTIC VIEW がGRANTS一覧に含まれていればOK
```

## 2. サンプルデータを投入する

`seed_data.sql` として保存する。商品マスタ10件、売上500件（乱数生成）を投入する。MCPサーバーの記事と同じデータ構造を使う。

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

実行:

```sh
snow sql -f seed_data.sql -c oauth
```

確認:

```sh
snow sql -q "SELECT COUNT(*) FROM semantic_view_demo_db.sales_schema.sales;" -c oauth
snow sql -q "SELECT * FROM semantic_view_demo_db.sales_schema.product_master LIMIT 5;" -c oauth
```

## 3. Semantic Viewを作成する

`create_semantic_view.sql` として保存する。

TABLES（論理テーブル）、RELATIONSHIPS（結合キー）、FACTS（行レベルの数値）、DIMENSIONS（属性・分類軸）、METRICS（集計されたKPI）の順で定義する。

**日本語での意味付けの設計方針**: `WITH SYNONYMS` と `COMMENT` は、後段（手順5）でCortex Analystに日本語の自然文で問い合わせることを見据えて書く。この2つは役割が異なる。

- `WITH SYNONYMS`: そのメトリクス/ディメンション/テーブルを指す**別名の完全な候補**を列挙する。「客単価」のように業務でよく使う言い回しを、実際のカラム名（`average_amount`）とは別に登録しておくことで、Cortex Analystがその言い回しを見た瞬間に対応するメトリクスへ結びつけやすくなる。
- `COMMENT`: そのオブジェクトの意味を**説明する自然文**。SYNONYMSに載っていない言い回しで質問された場合でも、Cortex Analyst（LLM）がCOMMENTの説明文からセマンティックに意味を推測して正しいメトリクス/ディメンションに辿り着けるかどうかに影響する。

そのため今回のDDLでは、あえて一部の業務用語（例: 「客単価」「商品ジャンル」）をSYNONYMSに**含めない**状態で最初のSemantic Viewを作る。手順5-2でこれらの用語を使って質問し、SYNONYMSを追加する前後で回答精度がどう変わるかを比較する。

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

実行:

```sh
snow sql -f create_semantic_view.sql -c oauth
```

確認:

```sh
snow sql -q "SHOW SEMANTIC VIEWS LIKE 'sales_semantic_view' IN SCHEMA semantic_view_demo_db.sales_schema;" -c oauth
snow sql -q "DESC SEMANTIC VIEW semantic_view_demo_db.sales_schema.sales_semantic_view;" -c oauth
# TABLES/FACTS/DIMENSIONS/METRICS/RELATIONSHIPSがそれぞれ意図通り登録されているか確認する
```

:::message
`WITH SYNONYMS` の代入演算子が `WITH SYNONYMS ('...')`（TABLES句）と `WITH SYNONYMS = ('...')`（DIMENSIONS句）でドキュメント上表記が揺れているように見える。**実機検証で確定させる項目。** 両方試して構文エラーにならない方を採用する。
:::

## 4. Semantic Viewに問い合わせる

`SELECT * FROM SEMANTIC_VIEW(...)` 構文でDIMENSIONS/METRICS/FACTSを指定して問い合わせる。それぞれ「何を確認したいか」を明記する。

### 4-1. カテゴリ別の売上合計・数量（集計が効いているかの確認）

```sh
snow sql -q "
SELECT * FROM SEMANTIC_VIEW(
  semantic_view_demo_db.sales_schema.sales_semantic_view
  DIMENSIONS products.category
  METRICS sales.total_amount, sales.total_quantity
)
ORDER BY total_amount DESC;
" -c oauth
```

確認観点: `GROUP BY`を明示的に書かなくても`category`単位で正しく集計されるか。以下の素のSQLと結果が一致することを突き合わせる。

```sh
snow sql -q "
SELECT p.category, SUM(s.amount) AS total_amount, SUM(s.quantity) AS total_quantity
FROM semantic_view_demo_db.sales_schema.sales s
JOIN semantic_view_demo_db.sales_schema.product_master p ON s.product_id = p.product_id
GROUP BY p.category
ORDER BY total_amount DESC;
" -c oauth
```

### 4-2. 月別の売上推移（DIMENSIONSで定義した式が使えるかの確認）

```sh
snow sql -q "
SELECT * FROM SEMANTIC_VIEW(
  semantic_view_demo_db.sales_schema.sales_semantic_view
  DIMENSIONS sales.sold_month
  METRICS sales.total_amount
)
ORDER BY sold_month;
" -c oauth
```

確認観点: `DATE_TRUNC('MONTH', sold_at)`という式で定義したディメンションが、日付でなく月単位でグルーピングされて返ってくるか。

### 4-3. 商品別の平均売上とWHERE句によるフィルタ（フィルタが集計前後どちらに効くかの確認）

```sh
snow sql -q "
SELECT * FROM SEMANTIC_VIEW(
  semantic_view_demo_db.sales_schema.sales_semantic_view
  DIMENSIONS products.product_name
  METRICS sales.average_amount, sales.total_quantity
  WHERE products.category = '周辺機器'
)
ORDER BY average_amount DESC;
" -c oauth
```

確認観点: `SEMANTIC_VIEW(...)`の中に書いた`WHERE`が「集計前の行フィルタ」として効くか（`周辺機器`カテゴリの商品だけに絞られるか）。

### 4-4. FACTSを使った行レベル問い合わせ（集計しない生データ取得の確認）

```sh
snow sql -q "
SELECT * FROM SEMANTIC_VIEW(
  semantic_view_demo_db.sales_schema.sales_semantic_view
  DIMENSIONS products.product_name, sales.sold_date
  FACTS sales.sale_amount
)
ORDER BY sold_date DESC
LIMIT 10;
" -c oauth
```

確認観点: METRICSではなくFACTSを指定した場合、集計されずに明細単位の行がそのまま返ってくるか。

:::message
2026年3月2日に「標準SQLでSemantic Viewを問い合わせる」機能がGAになっており、`SELECT * FROM SEMANTIC_VIEW(...)`という専用構文を使わずに`SELECT category, AGG(total_amount) FROM sales_semantic_view GROUP BY category`のような書き方もできるらしい。**実機検証で確定させる項目。** どちらの構文の方が記事として説明しやすいか、また実際に動くかを確認し、記事では両方または片方を採用する。
:::

## 5. Claude DesktopからSemantic Viewを使う（発展）

Cortex Analyst専用のMCPツール（`CORTEX_ANALYST_MESSAGE`タイプ）は今回は作らない。
汎用のSQL実行MCPサーバー（`SYSTEM_EXECUTE_SQL`タイプ）を今回の検証環境専用に新規作成し、Claude Desktopに自然言語で問い合わせて、Claude Desktop自身（＝ClaudeというLLM自体の読解力）が`SEMANTIC_VIEW(...)`構文や標準SQL構文のクエリを正しく組み立てられるかを確認する。
Claude Desktop側のOAuth接続設定など、MCPサーバーへの接続手順自体は本記事では扱わない（[MCPサーバーの記事](articles/snowflake-managed-mcp-claude-desktop.md)を参照）。

`setup_mcp.sql` として保存する。

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

実行:

```sh
snow sql -f setup_mcp.sql -c oauth
```

:::message
`CREATE MCP SERVER`にはスキーマに対する`CREATE MCP SERVER`権限が必要。手順1のGRANT文に追加済み。
:::

確認:

```sh
snow sql -q "SHOW MCP SERVERS LIKE 'sales_analysis_mcp' IN SCHEMA semantic_view_demo_db.sales_schema;" -c oauth
```

あとはClaude Desktop側のプロンプトのみで検証する。

### 5-1. 質問例（そのまま自然言語で聞いてみる）

Claude Desktop（Cortex Analystは介さず、Claude自身がSemantic Viewのメタデータを読んでSQLを組み立てる）が自然言語からSemantic Viewを正しく引けているか確認する。

- 「カテゴリ別の売上合計を教えて」
- 「直近3ヶ月の売上推移を月ごとに見せて」
- 「周辺機器の中で平均単価が一番高い商品は？」

それぞれの質問に対してClaude Desktopが実行したツール呼び出し（生成されたSQL、`SEMANTIC_VIEW(...)`構文か標準SQL構文か）を確認し、意図通りのDIMENSIONS/METRICSが選ばれているかチェックする。

### 5-2. 日本語シノニムの追加前後で回答精度を比較する（Before/After）

手順3のDDLでは意図的に「客単価」（`sales.average_amount`のシノニム）と「商品ジャンル」（`products.category`のシノニム）を`WITH SYNONYMS`に含めていない。この状態とSYNONYMSを追加した後とで、Claude Desktopの回答精度がどう変わるかを比較する。

**Before（シノニム追加前）**: Claude Desktopで次の質問をし、回答・生成されたツール呼び出しを記録する。

- 「客単価を教えて」（`average_amount`というメトリクス名ともCOMMENT文言とも表記が異なる業務用語）
- 「商品ジャンルごとの売上を見せて」（`category`というディメンション名とは異なる言い回し）

確認観点: COMMENTの説明文（自然文）だけを手がかりに、SYNONYMSに登録されていない言い回しでも正しいメトリクス/ディメンションに辿り着けるか。辿り着けない場合、Claude Desktopはどのような回答をするか（「該当する項目が見つかりません」等になるか、あるいは誤ったメトリクスを選んでしまうか）を記録する。

**シノニムを追加する**: `add_synonyms.sql` として保存する。

```sql
USE ROLE semantic_view_demo_role;
USE DATABASE semantic_view_demo_db;
USE SCHEMA sales_schema;

ALTER SEMANTIC VIEW sales_semantic_view
  SET METRICS (
    sales.average_amount AS AVG(sales.sale_amount)
      WITH SYNONYMS = ('客単価', 'average order value')
      COMMENT = '1明細あたりの平均売上金額（客単価）'
  );

ALTER SEMANTIC VIEW sales_semantic_view
  SET DIMENSIONS (
    products.category AS products.category
      WITH SYNONYMS = ('カテゴリ', 'category', '商品ジャンル')
      COMMENT = '商品カテゴリ（商品ジャンル）'
  );
```

実行:

```sh
snow sql -f add_synonyms.sql -c oauth
```

確認:

```sh
snow sql -q "DESC SEMANTIC VIEW semantic_view_demo_db.sales_schema.sales_semantic_view;" -c oauth
# average_amountとcategoryのSYNONYMSに追加した用語が反映されているか確認する
```

:::message
`ALTER SEMANTIC VIEW ... SET METRICS/DIMENSIONS (...)` という構文で個別のメトリクス/ディメンションだけを更新できるか、それとも`CREATE OR REPLACE SEMANTIC VIEW`で手順3のDDL全体を書き直す必要があるかは未確認。**実機検証で確定させる項目。** `ALTER`が使えない場合は手順3のDDLに直接シノニムを書き加えて`CREATE OR REPLACE`し直す。
:::

**After（シノニム追加後）**: 5-2冒頭と全く同じ質問をもう一度Claude Desktopに投げ、Before時点の回答・ツール呼び出しと比較する。

- 「客単価を教えて」→ `sales.average_amount`のメトリクスが選ばれるようになったか
- 「商品ジャンルごとの売上を見せて」→ `products.category`のディメンションが選ばれるようになったか

確認観点: SYNONYMS追加によって、Before時点で曖昧だった／失敗していた問い合わせが安定して正しいメトリクス・ディメンションに解決されるようになるか。LLMの応答は毎回決定的とは限らないため、余裕があれば同じ質問を複数回（3回程度）試して再現性も見ておく。

:::message
- LLMの回答は非決定的なため、Before/Afterの差が「シノニムを追加したから」なのか「たまたま」なのかの切り分けが難しい可能性がある。複数回試行して傾向として差が見えるかで判断する。
- この節はSemantic View単体の記事としては発展的内容のため、実機検証がうまくいかない・時間が取れない場合は記事から削って手順4までの内容に絞ることも検討する。ただし5-2の日本語シノニムの効果検証は本記事の目玉でもあるため、Claude Desktopとの連携自体がうまくいかない場合は、せめて`DESC SEMANTIC VIEW`の出力比較やSemantic View自体の設計論として書く形に切り替える。
:::

## 6. クリーンアップ

`teardown.sql` として保存する。

```sql
USE ROLE semantic_view_demo_role;
DROP MCP SERVER IF EXISTS semantic_view_demo_db.sales_schema.sales_analysis_mcp;
DROP SEMANTIC VIEW IF EXISTS semantic_view_demo_db.sales_schema.sales_semantic_view;

USE ROLE SYSADMIN;
DROP WAREHOUSE IF EXISTS semantic_view_demo_wh;
DROP DATABASE IF EXISTS semantic_view_demo_db;
DROP ROLE IF EXISTS semantic_view_demo_role;
```

実行:

```sh
snow sql -f teardown.sql -c oauth
```

## 7. 記事執筆

- [x] `articles/snowflake-semantic-view-sales-data.md` の各セクションを、実際に得られた出力・実行結果で埋める
- [x] 手順3の`WITH SYNONYMS`構文の揺れ（TABLES句とDIMENSIONS句での書き方の違い）の結論を反映する
- [x] 手順4-3の`WHERE`句が集計前フィルタとして効くかどうかの結論を反映する
- [x] 手順4末尾の`:::message`で触れた「標準SQLでの問い合わせ（GA機能）」を試し、記事でどちらの構文を主軸にするか決める
- [x] 手順5（Claude Desktopからの自然言語問い合わせ）が実機で動作するか確認し、記事に反映する
- [x] 手順5-2のBefore/Afterの結果を記事に反映する。**当初の仮説（SYNONYMS追加で回答精度が変わる）とは異なる結論になった**: 汎用SQL実行ツールではClaude Desktopは指示なしにSemantic Viewを自発的に参照せず生テーブルへ直接SQLを書くため、SYNONYMS単体の有無では回答は変わらなかった。「Semantic Viewを使って」と明示指示すると参照するようになり、その状態ではCOMMENTの自然文だけ（SYNONYMSの完全一致なし）でも正しいメトリクスに辿り着けた。この「LLMがSemantic Viewを参照するかどうか」という一段手前の条件が本質的な発見として記事の目玉になった
- [ ] `published: true` にして公開日を設定する
- [ ] 本ファイル（`snowflake-semantic-view-sales-data-plan.md`）は記事完成後に削除する
