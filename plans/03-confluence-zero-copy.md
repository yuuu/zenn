# 検証手順書: Confluence → Snowflake のゼロコピークローンを試してみる

作成日: 2026-10-02 / 実行は未実施(手順書のみ)

## 0. ネタの前提の整理(最重要)

### 0.1 調査結果(2026年10月2日時点、WebSearch/WebFetchで確認)

| 項目 | 結論 | 区分 | 出典 |
|---|---|---|---|
| ConfluenceとSnowflake間の公式ゼロコピー連携(Zero-copy integration)/Zero-ETL | 見つからなかった。Snowflakeのゼロコピー連携の提携先ページにAtlassianは載っていない(SAP、Salesforce、Workday等が中心) | 事実(ただし「存在しない」の証明ではない) | https://www.snowflake.com/en/product/features/zero-copy-integrations |
| Openflow コネクタ一覧にConfluenceがあるか | GA一覧(Box, Google Drive, SharePoint, Jira Cloud, Slack等)にConfluenceは無い | 事実 | https://docs.snowflake.com/en/user-guide/data-integration/openflow/connectors/about-openflow-connectors |
| Openflow Connector for Confluence Data Center | 存在するが「Preview Feature - Private(選択されたアカウントのみ)」。**Confluence Cloudは非対応**、認証はPersonal Access Tokenのみ。Simpleフロー(ステージ+DOC_METADATAテーブル)とCortexフロー(Cortex Search)がある | 事実 | https://docs.snowflake.com/en/LIMITEDACCESS/openflow/connectors/confluence-data-center/about |
| Confluence側の補助アプリ | Snowflake Openflow Companion for Confluence Data Center(Preview、v1.0.4、Confluence DC 8.5.0-9.5.4対応) | 事実 | https://marketplace.atlassian.com/apps/2973166516/snowflake-openflow-companion-for-confluence-data-center |
| ゼロコピークローン(CREATE ... CLONE) | Snowflake内のオブジェクト(DB/スキーマ/テーブル等)の複製機能。ストレージを共有し、変更分のみ差分が発生する。Time Travelの AT/BEFORE と併用可 | 事実 | https://docs.snowflake.com/en/user-guide/object-clone |
| サードパーティのConfluence→Snowflake連携 | Estuary、CData、Tray.ai等が存在(ETL/ELT型でゼロコピーではない) | 事実 | https://estuary.dev/confluence-to-snowflake |

### 0.2 結論: ネタの前提は「そのままでは成立しない」

- 「Confluenceから直接ゼロコピークローンする」ことはできない。ゼロコピークローンはSnowflake内オブジェクトの複製機能であり、外部SaaSは対象外。
- ConfluenceはゼロコピーのSaaS連携(Salesforce等で提供されているようなもの)の対象として確認できなかった(推測: 今後追加される可能性はあるが、現時点で公式情報なし)。
- 公式コネクタ(Openflow)はConfluence **Data Center** 専用かつPrivate Previewで、無料のAtlassian Cloudでは使えず、誰でも試せるとは限らない。

### 0.3 検証方針(記事の切り口を変更)

記事タイトル案: 「ConfluenceのデータをSnowflakeに取り込んでゼロコピークローンしてみた(ゼロコピー連携は無いので自分で作る)」

1. **方針A(本命・誰でも再現可能)**: Atlassian Cloud無料プランのConfluence + REST API(curl) → JSONLファイル → Snowflake CLIでステージにPUT → COPY INTO でテーブル化 → ゼロコピークローン検証。Openflowを使わないため`snow`のみで完結する。
2. **方針B(任意・環境が使えれば)**: Openflow Confluence Data Centerコネクタ(Private Preview)。利用にはSnowflake側の許可が必要で、Confluence Data Centerのトライアルライセンス+サーバー(AWS EC2等)の用意が必要。今回は「未確認事項」として扱い、アクセスが得られた場合のみ追補する。
3. 発展: 取り込んだテーブルをクローンして開発環境を作り、Cortex Searchで検索する(§9)。

今回は方針Aで進める。

## 1. 目的と記事の想定構成

目的:
- 「ConfluenceとSnowflakeのゼロコピー連携」の現状を整理し、誤解を解く
- 取り込んだConfluenceデータに対し、ゼロコピークローンのストレージ共有・差分発生・Time Travel併用を実測する

見出し案(トーンは既存の snowflake-*.md に合わせ「です・ます」、冒頭「はじめに」、結論先出し):
1. はじめに(ゼロコピー連携があるのか調べた結果を先に書く)
2. Confluence × Snowflake の連携手段を整理する(表: Openflow DC / Marketplace / サードパーティ / 自作)
3. ゼロコピークローンとは(Snowflake内の機能であること)
4. 検証環境の準備(Confluence Cloud / Snowflake CLI)
5. Confluenceのページを取得してSnowflakeに取り込む
6. テーブルをゼロコピークローンする(ストレージ共有の確認)
7. クローン側を更新して差分だけ増えることを確認する
8. Time Travelと組み合わせる(誤削除から復元、過去時点のクローン)
9. おまけ: Cortex Searchで検索
10. まとめ / クリーンアップ

## 2. 前提条件・アカウント要件・コスト

- Snowflakeアカウント(Trial可)。既存記事に合わせ **ACCOUNTADMIN前提で簡略化**する(記事内に「検証用なのでACCOUNTADMINで実施」と明記)。
- Snowflake CLI(`snow`)導入済み、接続設定済み(参考: articles/snowflake-cli-install-with-mise.md, articles/snowflake-cli-oauth.md)。
- Atlassian Cloud 無料プラン(Confluence Free。10ユーザーまで)。
- `curl`, `jq`。AWSは使わない(方針Aの場合)。方針BのみEC2等が必要になる。
- コスト: XSウェアハウス数分(数クレジット未満)。Cortex Search(§9)を実施する場合は追加でサービス費用が発生するため、短時間で削除する。ストレージは数MB〜数十MB。
- 注意: Time Travelの保持期間は標準で1日(Enterprise以上は最大90日)。Trialは通常Enterprise。

## 3. Confluence準備(CLI/APIで実施)

APIトークン作成のみGUI必須(https://id.atlassian.com/manage-profile/security/api-tokens)。代替: 無し(2026/10時点、トークンの発行APIは確認できず。未確認事項)。サイト作成(無料プラン登録)もGUI必須。

```bash
export CF_SITE="your-site"                 # your-site.atlassian.net
export CF_USER="web-services@y-uuu.net"
export CF_TOKEN="<APIトークン>"
export CF_AUTH="$CF_USER:$CF_TOKEN"
export CF_BASE="https://${CF_SITE}.atlassian.net/wiki"

# 疎通確認 + スペース一覧
curl -s -u "$CF_AUTH" "$CF_BASE/api/v2/spaces" | jq '.results[] | {id,key,name}'
export CF_SPACE_ID="<上で得たid>"
```

サンプルページを作成(5ページ。本文はstorage形式)。

```bash
for i in 1 2 3 4 5; do
  jq -n --arg sid "$CF_SPACE_ID" --arg t "検証ページ $i" \
        --arg b "<p>これはゼロコピークローン検証用のページ $i です。Snowflakeに取り込みます。</p>" \
   '{spaceId:$sid,status:"current",title:$t,body:{representation:"storage",value:$b}}' |
  curl -s -u "$CF_AUTH" -H "Content-Type: application/json" \
       -X POST "$CF_BASE/api/v2/pages" -d @- | jq '{id,title}'
done
```

期待結果: 5件の `id,title` が返る。

## 4. Snowflake側セットアップ

```bash
snow sql -q "
CREATE WAREHOUSE IF NOT EXISTS CF_WH WAREHOUSE_SIZE='XSMALL' AUTO_SUSPEND=60 AUTO_RESUME=TRUE;
CREATE DATABASE IF NOT EXISTS CF_DB;
CREATE SCHEMA IF NOT EXISTS CF_DB.RAW;
CREATE STAGE IF NOT EXISTS CF_DB.RAW.CF_STAGE FILE_FORMAT=(TYPE=JSON);
USE WAREHOUSE CF_WH;
"
```

## 5. 取り込み(方針A)

```bash
mkdir -p work && cd work
# ページ本文付きで取得(最大250件。件数が多い場合は _links.next をたどる)
curl -s -u "$CF_AUTH" "$CF_BASE/api/v2/pages?body-format=storage&limit=250" \
  | jq -c '.results[] | {id,title,spaceId,version:.version.number,created_at:.version.createdAt,body:.body.storage.value}' \
  > pages.jsonl
wc -l pages.jsonl

snow stage copy pages.jsonl @CF_DB.RAW.CF_STAGE --overwrite
snow sql -q "LIST @CF_DB.RAW.CF_STAGE;"

snow sql -q "
CREATE OR REPLACE TABLE CF_DB.RAW.CONFLUENCE_PAGES (
  ID STRING, TITLE STRING, SPACE_ID STRING, VERSION NUMBER, CREATED_AT TIMESTAMP_TZ, BODY STRING);
COPY INTO CF_DB.RAW.CONFLUENCE_PAGES
FROM (SELECT \$1:id, \$1:title, \$1:spaceId, \$1:version, \$1:created_at::TIMESTAMP_TZ, \$1:body FROM @CF_DB.RAW.CF_STAGE/pages.jsonl.gz);
SELECT COUNT(*) FROM CF_DB.RAW.CONFLUENCE_PAGES;
"
```

期待結果: COUNTが5(Confluenceの既存ページがあればその分増える)。`snow stage copy`は自動で`.gz`圧縮される(未確認、ファイル名は`LIST`で確認して調整)。

## 6. ゼロコピークローンの検証

### 6.1 検証用にデータ量を増やす
数MBでは差が見えにくいため、水増しして約数百MBにする(**元データがConfluenceである点を保ったまま、検証用のかさ増しだと記事に明記**)。

```bash
snow sql -q "
CREATE OR REPLACE TABLE CF_DB.RAW.CONFLUENCE_PAGES_BIG AS
SELECT p.*, UNIFORM(1,1000000,RANDOM()) AS SEQ, RANDSTR(2000,RANDOM()) AS NOISE
FROM CF_DB.RAW.CONFLUENCE_PAGES p, TABLE(GENERATOR(ROWCOUNT=>200000));
"
```

### 6.2 クローン前のストレージ

```bash
snow sql -q "
SELECT TABLE_NAME, ID, CLONE_GROUP_ID, ACTIVE_BYTES, TIME_TRAVEL_BYTES, FAILSAFE_BYTES, RETAINED_FOR_CLONE_BYTES
FROM CF_DB.INFORMATION_SCHEMA.TABLE_STORAGE_METRICS
WHERE TABLE_SCHEMA='RAW' AND TABLE_NAME LIKE 'CONFLUENCE_PAGES_BIG%';"
```

### 6.3 クローン作成と直後の確認

```bash
snow sql -q "CREATE OR REPLACE SCHEMA CF_DB.DEV CLONE CF_DB.RAW;"   # 開発環境をスキーマごとクローン
snow sql -q "
SELECT TABLE_SCHEMA, TABLE_NAME, CLONE_GROUP_ID, ACTIVE_BYTES, RETAINED_FOR_CLONE_BYTES
FROM CF_DB.INFORMATION_SCHEMA.TABLE_STORAGE_METRICS
WHERE TABLE_NAME='CONFLUENCE_PAGES_BIG' ORDER BY TABLE_SCHEMA;"
```

期待結果(仮説、要実測):
- RAWとDEVの `CLONE_GROUP_ID` が同一
- クローン直後、DEV側に追加の実データは発生せず(ACTIVE_BYTESの扱いは表示上どう見えるか実測して記録)
- 補助確認: `SELECT SYSTEM$CLUSTERING_INFORMATION` ではなく、`snow sql -q "SELECT COUNT(*) FROM CF_DB.DEV.CONFLUENCE_PAGES_BIG"` が元と一致し、クローン所要時間が数秒である(`snow sql`の実行時間を`time`で計測)
- 注意: ACCOUNT_USAGE.TABLE_STORAGE_METRICS は最大90分程度の遅延があるため、記事ではINFORMATION_SCHEMA版を使う(遅延は公式で確認、数値は未確認)。

### 6.4 クローン側のみ更新 → 差分のみ増えることの確認

```bash
snow sql -q "UPDATE CF_DB.DEV.CONFLUENCE_PAGES_BIG SET NOISE='x' WHERE SEQ < 100000;"   # 約10%更新
snow sql -q "
SELECT TABLE_SCHEMA, ACTIVE_BYTES, RETAINED_FOR_CLONE_BYTES, TIME_TRAVEL_BYTES
FROM CF_DB.INFORMATION_SCHEMA.TABLE_STORAGE_METRICS
WHERE TABLE_NAME='CONFLUENCE_PAGES_BIG';"
```

期待結果: DEV側の増加量が更新範囲(マイクロパーティション単位)に概ね比例。RAW側は不変。UPDATEは行が各パーティションに散らばると全パーティションが書き換わるため、増分が10%にならない可能性がある(`SEQ`でクラスタリングしていないため)。その場合は `ORDER BY SEQ` で作り直す、または更新対象を変えて再測定し、記事にその理由も書く。

### 6.5 Time Travel併用

```bash
# 誤削除 → 復元
snow sql -q "SELECT CURRENT_TIMESTAMP();"       # 値をメモ -> TS
snow sql -q "DELETE FROM CF_DB.DEV.CONFLUENCE_PAGES;"
snow sql -q "CREATE TABLE CF_DB.DEV.CONFLUENCE_PAGES_RESTORED CLONE CF_DB.DEV.CONFLUENCE_PAGES AT(TIMESTAMP=>'<TS>'::TIMESTAMP_TZ);"
snow sql -q "SELECT COUNT(*) FROM CF_DB.DEV.CONFLUENCE_PAGES_RESTORED;"   # 5件
# 経過時間指定
snow sql -q "CREATE TABLE CF_DB.DEV.PAGES_5MIN_AGO CLONE CF_DB.RAW.CONFLUENCE_PAGES AT(OFFSET=>-60*5);"
```

期待結果: 削除前の件数でクローンできる。保持期間外やテーブル作成前を指定するとエラー(公式記載どおり)になることも確認して記事に載せる。

### 6.6 Confluence側の更新が反映されないことの確認(ネタの前提の補強)

```bash
PAGE_ID=$(curl -s -u "$CF_AUTH" "$CF_BASE/api/v2/pages?limit=1" | jq -r '.results[0].id')
# タイトルを変更(version.numberを+1して送る必要あり)
VER=$(curl -s -u "$CF_AUTH" "$CF_BASE/api/v2/pages/$PAGE_ID" | jq '.version.number')
curl -s -u "$CF_AUTH" -H "Content-Type: application/json" -X PUT "$CF_BASE/api/v2/pages/$PAGE_ID" \
  -d "{\"id\":\"$PAGE_ID\",\"status\":\"current\",\"title\":\"更新後\",\"version\":{\"number\":$((VER+1))},\"body\":{\"representation\":\"storage\",\"value\":\"<p>updated</p>\"}}" | jq '.title'
snow sql -q "SELECT TITLE FROM CF_DB.RAW.CONFLUENCE_PAGES WHERE ID='$PAGE_ID';"
```

期待結果: Snowflake側は古いまま。「ゼロコピー連携ではなく取り込み型(再同期が必要)」であることを示す。クローンはConfluenceと同期しない。

## 7. 検証ステップまとめ(実施順)

| # | 内容 | 確認コマンド | 期待結果 |
|---|---|---|---|
| 1 | Confluence疎通 | §3 spaces API | スペース一覧が返る |
| 2 | ページ作成 | §3 POST | 5件のid |
| 3 | Snowflake準備 | `snow sql -q "SHOW SCHEMAS IN DATABASE CF_DB"` | RAWが存在 |
| 4 | 取り込み | §5 COUNT | 件数一致 |
| 5 | 水増し | §6.1 | 約20万行 |
| 6 | クローン前メトリクス | §6.2 | 単独のCLONE_GROUP_ID |
| 7 | クローン | §6.3 | 同一CLONE_GROUP_ID、数秒 |
| 8 | クローン側更新 | §6.4 | DEV側のみ差分増加 |
| 9 | Time Travel | §6.5 | 削除前の件数で復元 |
| 10 | 同期されないこと | §6.6 | Snowflake側は古い |
| 11 | (任意)Cortex Search | §9 | 検索結果が返る |

## 8. エラー時の確認ポイント

- Confluence 401/403: メールアドレスとAPIトークンの組、サイトURL(`/wiki`の有無)を確認。
- v2 APIで `body` が空: `body-format=storage` の指定漏れ。
- `COPY INTO` で0行: `LIST @CF_STAGE` でファイル名(`.gz`有無)を確認。`ON_ERROR`や`FILE_FORMAT`を確認。
- クローンでエラー: 保持期間外の`AT`指定、またはクローン中のDDL競合(公式の制限事項)。
- TABLE_STORAGE_METRICSが空: 権限(ACCOUNTADMIN)と、INFORMATION_SCHEMAのDB指定を確認。
- Openflow(方針B): Private Previewで、アカウントが対象でないとコネクタが表示されない。Snowflake担当/サポートへ問い合わせが必要(未確認)。

## 9. おまけ: Cortex Searchで検索(任意)

```bash
snow sql -q "
CREATE OR REPLACE CORTEX SEARCH SERVICE CF_DB.RAW.CF_SEARCH
  ON BODY ATTRIBUTES TITLE WAREHOUSE=CF_WH TARGET_LAG='1 day'
  AS SELECT ID, TITLE, BODY FROM CF_DB.RAW.CONFLUENCE_PAGES;"
snow sql -q "SELECT PARSE_JSON(SNOWFLAKE.CORTEX.SEARCH_PREVIEW('CF_DB.RAW.CF_SEARCH', '{\"query\":\"ゼロコピー\",\"columns\":[\"TITLE\"],\"limit\":3}'));"
```

BODYはHTML(storage形式)のままなので、必要なら`REGEXP_REPLACE(BODY,'<[^>]+>','')`でタグ除去してから索引化する。

## 10. 記事に載せる出力/スクショ

- 調査結果の表(§0.1)。出典URL付き
- TABLE_STORAGE_METRICSの結果3点(クローン前/直後/更新後)の表またはスクショ
- クローン所要時間
- Time Travelで復元した件数
- Confluence更新後もSnowflake側が古いままのSELECT結果
- GUI必須: Atlassianのトークン発行画面(トークン値は必ず隠す)

## 11. クリーンアップ

```bash
snow sql -q "
DROP CORTEX SEARCH SERVICE IF EXISTS CF_DB.RAW.CF_SEARCH;
DROP DATABASE IF EXISTS CF_DB;
DROP WAREHOUSE IF EXISTS CF_WH;"
# Confluence: 作成したページを削除
curl -s -u "$CF_AUTH" "$CF_BASE/api/v2/pages?limit=250" | jq -r '.results[] | select(.title|test("検証ページ|更新後")) | .id' \
 | xargs -I{} curl -s -u "$CF_AUTH" -X DELETE "$CF_BASE/api/v2/pages/{}"
```
APIトークンはGUIで失効させる。

## 12. 未確認事項リスト

- 2026年10月時点で、Atlassian CloudをSnowflakeとゼロコピー連携する公式発表が本当に無いか(検索で見つからなかっただけの可能性。Snowflake Marketplaceのリスティングは未確認)
- Openflow Confluence Data Centerコネクタの一般提供時期、Cloud対応の予定
- `snow stage copy` の圧縮挙動・ファイル名
- INFORMATION_SCHEMA.TABLE_STORAGE_METRICS でのクローンの`ACTIVE_BYTES`/`RETAINED_FOR_CLONE_BYTES`の実際の見え方
- UPDATE時の増分バイト数がパーティション単位でどうなるか
- Confluence v2 APIのページネーション(`_links.next`)・レート制限の詳細
- Atlassian APIトークンの作成をCLI/APIで行う手段
- Free planの制限(ユーザー数・ストレージ)が検証に影響しないか
