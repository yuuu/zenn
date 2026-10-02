# 検証手順書: Snowflakeに誰でもデータを投入できる画面を作る(Streamlit in Snowflake)

- 作成日: 2026-10-02
- 想定記事: Zenn(fusic Publication)。既存の `snowflake-semantic-view-sales-data.md` 等と同じトーン(です・ます調、ACCOUNTADMIN前提で簡略化、操作は全てCLI)
- 方針: Snowflake操作は全て Snowflake CLI(`snow`)。AWSは使わない(AWS CLI / Terraform 不要)。GUI操作が必要な箇所は「ブラウザでアプリURLを開く」だけに限定する(画面の動作確認と撮影は不可避)。

---

## 1. 目的と記事の想定構成

### 目的
非エンジニアが、ブラウザだけで「CSV/Excelのアップロード」と「画面上での手入力」によりSnowflakeのテーブルへデータを投入できる画面を、最小工数(Pythonファイル1つ + 設定ファイル2つ)で作れることを検証する。

### 調査済みの公式仕様メモ(2026-10-02時点で確認できた範囲)
- `snow init <dir> --template example_streamlit` でプロジェクト雛形(`snowflake.yml` / `environment.yml` / `streamlit_app.py` / `pages/` / `common/`)を生成できる。ドキュメント上のコマンドは `snow init`(`snow streamlit init` も存在する想定。実機で `--help` 確認)。
- `snowflake.yml` は `definition_version: 2`、`entities` 配下に `type: streamlit`。`query_warehouse` は必須、`main_file`(既定 `streamlit_app.py`)、`stage`、`artifacts` 等を指定。
- `snow streamlit deploy [--replace] [--open] [--entity-id <id>]`。ステージ未指定なら `streamlit` ステージを使い、無ければ自動作成。`snow streamlit get-url` / `list` / `drop` もある。
- ランタイムは2種類。

| 項目 | Warehouse runtime | Container runtime |
|---|---|---|
| 実行基盤 | 仮想ウェアハウス | コンピュートプールのノード + ウェアハウス |
| インスタンス | 閲覧者ごとに個別 | 全閲覧者で共有 |
| Python | 3.9 / 3.10 / 3.11 | 3.11のみ |
| 依存関係 | `environment.yml`(Condaパッケージ、`=`でバージョン固定) | `requirements.txt` / `pyproject.toml`(PyPI、`==`) |
| Streamlit | 1.22以降(選択肢に制限あり) | 1.50以降 |
| `st.file_uploader` 上限 | 200MB固定 | 既定200MB、`server.maxUploadSize`で変更可 |
| フロントとのメッセージ上限 | 32MB(超過で `MessageSizeError`) | 既定200MB(`server.maxMessageSize`) |

- 本記事は準備が少ない **Warehouse runtime** を主軸にし、Container runtimeは「発展」として軽く触れる(または比較表のみ)。

### 見出し案
1. はじめに(誰でもデータを入れられる画面が欲しい、という課題。完成イメージのスクショ)
2. 方式の比較: 投入手段の選択肢(下表。結論: 画面が欲しいならStreamlit in Snowflake)
3. 事前準備(Snowflake CLI接続、ACCOUNTADMIN前提)
4. 検証用のDB・テーブル・ロールを作る(CLI)
5. Streamlitアプリを作る(`snow init` → コード解説: アップロード / 手入力 / バリデーション)
6. デプロイして動かす(`snow streamlit deploy`)
7. 投入専用ロールで非ACCOUNTADMINユーザーとして使う(権限設計)
8. つまずきポイント
9. コストの考え方
10. 後片付け
11. おわりに

### 投入手段の比較表(記事用・要裏取り)
| 手段 | 非エンジニア向け | 画面構築 | 備考 |
|---|---|---|---|
| Snowsightのテーブルへのデータロード(CSVアップロードUI) | ○ | 不要 | GUI。ファイル単位、検証/整形ロジックを挟めない。CLI手順化できないので本検証では「比較のみ」で実施しない |
| `snow stage copy` + `COPY INTO` | × | 不要 | エンジニア向け。CLIのみ |
| Streamlit in Snowflake | ◎ | Python約100行 | 本記事の主題 |
| 外部のフォーム/ETL(Google Sheets連携等) | ○ | 別サービス | 対象外 |

---

## 2. 前提条件・準備物

- Snowflakeアカウント(Enterprise以上でなくてもStreamlit in Snowflakeは利用可の想定。要確認: トライアルアカウントで可否)。
- ACCOUNTADMINが使えるユーザー(記事では簡略化のためACCOUNTADMINで構築と明記)。
- Snowflake CLI導入済み(手元は 3.27.0 を確認)。導入は既存記事 `snowflake-cli-install-with-mise`、認証は `snowflake-cli-oauth` を参照。
- 接続名: 以降 `default` とする。別名なら `-c <接続名>` を付与。
- 動作確認用に、ACCOUNTADMIN以外のSnowflakeユーザー1名(手順4-3で作成)。ログインにはブラウザが必要(パスワード+MFA設定の都合あり。下記リスク参照)。
- ローカルにPython 3.11(CSV生成・Excel生成用。アプリ本体はSnowflake側で動くので不要)。
- Excelテスト用ファイルの作成に `uv` または `pip install openpyxl pandas`。

接続確認:

```sh
snow --version
snow connection test -c default
snow sql -c default -q "select current_user(), current_role(), current_account()"
```

期待結果: 接続成功、ユーザー名・ロール・アカウントが表示される。

---

## 3. 作業ディレクトリ

```sh
mkdir -p ~/work/sis-data-entry && cd ~/work/sis-data-entry
```

---

## 4. 検証環境のセットアップ(CLI)

### 4-1. DB/スキーマ/ウェアハウス/テーブル/ロール(`setup.sql`)

設計:
- `DATA_ENTRY_DB.APP` に投入先 `SALES_ENTRIES`(メインテーブル)を作る。
- 投入専用ロール `DATA_ENTRY_ROLE`: テーブルへの `INSERT`/`SELECT` のみ。`UPDATE`/`DELETE`/`TRUNCATE` は付与しない(誤投入しても他人のデータを消せない)。
- アプリはこのロールを **オーナー** にしてデプロイする(アプリはオーナー権限で動く想定。要検証: 5-3)。
- ウェアハウスは `XSMALL`、`AUTO_SUSPEND = 60`。

```sql
-- setup.sql
USE ROLE ACCOUNTADMIN;

CREATE DATABASE IF NOT EXISTS data_entry_db;
CREATE SCHEMA   IF NOT EXISTS data_entry_db.app;

CREATE WAREHOUSE IF NOT EXISTS data_entry_wh
  WAREHOUSE_SIZE = XSMALL
  AUTO_SUSPEND = 60
  AUTO_RESUME = TRUE
  INITIALLY_SUSPENDED = TRUE;

CREATE ROLE IF NOT EXISTS data_entry_role;

-- 投入先テーブル
CREATE TABLE IF NOT EXISTS data_entry_db.app.sales_entries (
  entry_date  DATE          NOT NULL,
  product     VARCHAR(100)  NOT NULL,
  quantity    NUMBER(10,0)  NOT NULL,
  amount      NUMBER(12,2)  NOT NULL,
  note        VARCHAR(500),
  input_user  VARCHAR(256),
  input_at    TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
);

-- 権限(最小権限)
GRANT USAGE ON WAREHOUSE data_entry_wh TO ROLE data_entry_role;
GRANT USAGE ON DATABASE  data_entry_db TO ROLE data_entry_role;
GRANT USAGE ON SCHEMA    data_entry_db.app TO ROLE data_entry_role;
GRANT SELECT, INSERT ON TABLE data_entry_db.app.sales_entries TO ROLE data_entry_role;

-- Streamlitアプリをこのロールで作成できるようにする
GRANT CREATE STREAMLIT ON SCHEMA data_entry_db.app TO ROLE data_entry_role;
GRANT CREATE STAGE     ON SCHEMA data_entry_db.app TO ROLE data_entry_role;

-- 自分(ACCOUNTADMIN運用者)がdata_entry_roleを使えるようにする
SET me = CURRENT_USER();
GRANT ROLE data_entry_role TO USER IDENTIFIER($me);
```

実行:

```sh
snow sql -c default -f setup.sql
```

確認:

```sh
snow sql -c default -q "show grants to role data_entry_role"
snow sql -c default -q "select count(*) from data_entry_db.app.sales_entries"
```

期待結果: 上記GRANTが一覧に出る。件数は0。

### 4-2. テーブルを仕込みなしでも使えることを確認
ここでは初期データは入れない(画面から入れるため)。

### 4-3. 非ACCOUNTADMINの確認用ユーザー(パスワード認証 + 後述のMFA注意)

```sql
-- create_user.sql
USE ROLE ACCOUNTADMIN;

CREATE USER IF NOT EXISTS entry_user_01
  PASSWORD = '<強いパスワードに置換>'
  DEFAULT_ROLE = data_entry_role
  DEFAULT_WAREHOUSE = data_entry_wh
  MUST_CHANGE_PASSWORD = FALSE;

GRANT ROLE data_entry_role TO USER entry_user_01;
```

```sh
snow sql -c default -f create_user.sql
snow sql -c default -q "show grants to user entry_user_01"
```

期待結果: `DATA_ENTRY_ROLE` のみが付与されている。

注意(要検証): 2026年時点でパスワードのみのシングルファクタ認証が制限される方針(MFA必須化 / `AUTHENTICATION POLICY`)がある。ユーザー作成やログインが拒否された場合は、ユーザー種別(`TYPE = PERSON` / `LEGACY_SERVICE`)や認証ポリシー、MFA登録の公式手順を確認し、記事には実際に通った方法だけ書く。

---

## 5. アプリ実装

### 5-1. 雛形生成

```sh
snow init data-entry-app --template example_streamlit \
  -D query_warehouse=data_entry_wh -D stage=data_entry_stage
cd data-entry-app
ls -la
```

(`snow streamlit init` が使える場合はそちらでも可。差異は実機で確認し、記事ではより素直なほうを採用)

期待結果: `snowflake.yml`, `environment.yml`, `streamlit_app.py`, `pages/`, `common/` が生成される。雛形の中身が記事の想定と異なる場合は、以下の内容で上書きする。最小構成のため `pages/` と `common/` は削除してよい。

```sh
rm -rf pages common
```

### 5-2. `snowflake.yml`

```yaml
definition_version: 2
entities:
  data_entry_app:
    type: streamlit
    identifier:
      name: data_entry_app
      database: data_entry_db
      schema: app
    title: "データ投入アプリ"
    query_warehouse: data_entry_wh
    stage: data_entry_stage
    main_file: streamlit_app.py
    artifacts:
      - streamlit_app.py
      - environment.yml
```

(要検証: `identifier` の書式、`title` キー、`stage` の自動作成可否。`snow streamlit deploy` 実行時のエラーメッセージに合わせて修正)

### 5-3. `environment.yml`(Warehouse runtime)

```yaml
name: sf_env
channels:
  - snowflake
dependencies:
  - streamlit
  - pandas
  - openpyxl
```

(要検証: Snowflake Anacondaチャンネルの利用規約同意が必要か、`openpyxl` が使えるか、Streamlitのバージョン指定。`st.data_editor` と `st.file_uploader` が使えるStreamlitバージョンがデフォルトで入るか。必要なら `streamlit=1.x` と固定)

### 5-4. `streamlit_app.py`

仕様:
- タブ1「ファイルから投入」: CSV/Excelをアップロード → プレビュー → 列名・型検証 → 「投入する」ボタンでINSERT。
- タブ2「画面で入力」: `st.data_editor` で行追加 → 「投入する」。
- 投入履歴(直近20件)を表示。
- 投入時に `input_user` を付与。

```python
import io
from datetime import date

import pandas as pd
import streamlit as st
from snowflake.snowpark.context import get_active_session

TABLE = "DATA_ENTRY_DB.APP.SALES_ENTRIES"
REQUIRED_COLUMNS = ["ENTRY_DATE", "PRODUCT", "QUANTITY", "AMOUNT", "NOTE"]
MAX_ROWS = 10000

session = get_active_session()


def current_user_name() -> str:
    return session.sql("SELECT CURRENT_USER()").collect()[0][0]


def validate(df: pd.DataFrame) -> tuple[pd.DataFrame, list[str]]:
    errors: list[str] = []
    df = df.copy()
    df.columns = [str(c).strip().upper() for c in df.columns]

    if "NOTE" not in df.columns:
        df["NOTE"] = None

    missing = [c for c in REQUIRED_COLUMNS if c not in df.columns]
    if missing:
        return df, [f"必須列が不足しています: {', '.join(missing)}"]

    df = df[REQUIRED_COLUMNS]
    df = df.dropna(how="all")
    if len(df) == 0:
        return df, ["投入できる行がありません"]
    if len(df) > MAX_ROWS:
        return df, [f"一度に投入できるのは{MAX_ROWS}行までです({len(df)}行)"]

    df["ENTRY_DATE"] = pd.to_datetime(df["ENTRY_DATE"], errors="coerce").dt.date
    df["QUANTITY"] = pd.to_numeric(df["QUANTITY"], errors="coerce")
    df["AMOUNT"] = pd.to_numeric(df["AMOUNT"], errors="coerce")

    if df["ENTRY_DATE"].isna().any():
        errors.append("ENTRY_DATE に日付として解釈できない値があります")
    if df["PRODUCT"].isna().any() or (df["PRODUCT"].astype(str).str.strip() == "").any():
        errors.append("PRODUCT に空の値があります")
    if df["QUANTITY"].isna().any():
        errors.append("QUANTITY に数値でない値があります")
    elif (df["QUANTITY"] % 1 != 0).any():
        errors.append("QUANTITY は整数で入力してください")
    if df["AMOUNT"].isna().any():
        errors.append("AMOUNT に数値でない値があります")
    return df, errors


def insert(df: pd.DataFrame) -> int:
    out = df.copy()
    out["QUANTITY"] = out["QUANTITY"].astype("int64")
    out["INPUT_USER"] = current_user_name()
    session.write_pandas(
        out,
        table_name="SALES_ENTRIES",
        database="DATA_ENTRY_DB",
        schema="APP",
        auto_create_table=False,
        overwrite=False,
        quote_identifiers=False,
    )
    return len(out)


st.title("売上データ投入")
st.caption("CSV/Excelのアップロード、または画面上で直接入力してテーブルに追加します。")

tab_file, tab_edit = st.tabs(["ファイルから投入", "画面で入力"])

with tab_file:
    st.write("列: ENTRY_DATE(日付), PRODUCT, QUANTITY(整数), AMOUNT(数値), NOTE(任意)")
    template = pd.DataFrame(
        [{"ENTRY_DATE": "2026-10-01", "PRODUCT": "りんご", "QUANTITY": 3, "AMOUNT": 540, "NOTE": ""}]
    )
    st.download_button(
        "CSVテンプレートをダウンロード",
        template.to_csv(index=False).encode("utf-8-sig"),
        file_name="template.csv",
        mime="text/csv",
    )
    up = st.file_uploader("CSV または Excel(.xlsx)", type=["csv", "xlsx"])
    if up is not None:
        try:
            if up.name.lower().endswith(".csv"):
                raw = pd.read_csv(up)
            else:
                raw = pd.read_excel(up, engine="openpyxl")
        except Exception as e:  # noqa: BLE001
            st.error(f"ファイルを読み込めませんでした: {e}")
            st.stop()
        df, errors = validate(raw)
        st.subheader("プレビュー")
        st.dataframe(df.head(50), use_container_width=True)
        if errors:
            for msg in errors:
                st.error(msg)
        else:
            st.success(f"{len(df)}行を投入できます")
            if st.button("この内容で投入する", key="btn_file", type="primary"):
                n = insert(df)
                st.success(f"{n}行を投入しました")

with tab_edit:
    init = pd.DataFrame(
        {"ENTRY_DATE": [date.today()], "PRODUCT": [""], "QUANTITY": [1], "AMOUNT": [0.0], "NOTE": [""]}
    )
    edited = st.data_editor(
        init,
        num_rows="dynamic",
        use_container_width=True,
        column_config={
            "ENTRY_DATE": st.column_config.DateColumn("日付", required=True),
            "PRODUCT": st.column_config.TextColumn("商品", required=True),
            "QUANTITY": st.column_config.NumberColumn("数量", min_value=0, step=1, required=True),
            "AMOUNT": st.column_config.NumberColumn("金額", min_value=0.0, required=True),
            "NOTE": st.column_config.TextColumn("備考"),
        },
        key="editor",
    )
    if st.button("この内容で投入する", key="btn_edit", type="primary"):
        df, errors = validate(edited)
        if errors:
            for msg in errors:
                st.error(msg)
        else:
            n = insert(df)
            st.success(f"{n}行を投入しました")

st.divider()
st.subheader("直近の投入履歴")
hist = session.sql(
    f"SELECT * FROM {TABLE} ORDER BY input_at DESC LIMIT 20"
).to_pandas()
st.dataframe(hist, use_container_width=True)
```

実装上の注意(要検証):
- `data_editor` の `column_config` が列名キー(大文字)で効くか。ヘッダー表示名(日本語)と `validate` の列名照合が整合するか。
- `st.dataframe(..., use_container_width=...)` は新しいStreamlitで非推奨(`width="stretch"`)の可能性。デプロイされるバージョンで警告が出たら書き換える。
- `write_pandas` の `quote_identifiers=False` と、`DATE` / `NUMBER` への型変換が通るか(日付は `datetime.date`、数値は `int64` / `float64`)。通らなければ `session.create_dataframe(...).write.save_as_table(..., mode="append")` に切り替える。
- `input_at` はテーブルのDEFAULT任せ(`write_pandas` が列を指定する形で `INSERT` されるか確認)。

---

## 6. デプロイ

```sh
cd ~/work/sis-data-entry/data-entry-app

# アプリをdata_entry_roleのオーナーシップで作る
snow streamlit deploy --replace -c default --role data_entry_role
snow streamlit list -c default --role data_entry_role
snow streamlit get-url data_entry_app -c default --role data_entry_role
```

(`--role` オプションが `snow streamlit deploy` で使えない場合は、接続定義にロールを設定するか `snow connection add --role data_entry_role` で別接続 `entry-dev` を作って `-c entry-dev` を使う。要検証)

期待結果: デプロイ成功、URL(`https://app.snowflake.com/...`)が表示される。

確認:

```sh
snow sql -c default --role data_entry_role -q "show streamlits in schema data_entry_db.app"
snow sql -c default --role data_entry_role -q "list @data_entry_db.app.data_entry_stage"
```

---

## 7. 検証ステップ(順番付き)

### 7-0. テストデータ作成(ローカル)

```sh
cd ~/work/sis-data-entry
cat > ok.csv <<'CSV'
ENTRY_DATE,PRODUCT,QUANTITY,AMOUNT,NOTE
2026-10-01,りんご,3,540,
2026-10-01,みかん,10,1200,セール
2026-10-02,ぶどう,2,1600,
CSV

cat > bad.csv <<'CSV'
ENTRY_DATE,PRODUCT,QUANTITY,AMOUNT,NOTE
2026-13-45,りんご,3,540,
2026-10-01,,abc,1200,
CSV

cat > gen_xlsx.py <<'PY'
import pandas as pd
pd.DataFrame({
  "entry_date": ["2026-10-03", "2026-10-03"],
  "product": ["もも", "なし"],
  "quantity": [4, 6],
  "amount": [2000, 1800],
}).to_excel("ok.xlsx", index=False)
PY
uv run --with pandas --with openpyxl python gen_xlsx.py
```

(Excelは小文字ヘッダーかつNOTE列なしにして、正規化処理が効くことを見る)

### 7-1. 画面表示
- 操作: `snow streamlit get-url`/`snow streamlit deploy --open` で表示したURLをブラウザで開く。
- 期待: 2つのタブ、履歴(0行)が表示される。

### 7-2. CSVアップロード(正常)
- 操作: `ok.csv` をアップロード → プレビュー確認 → 「この内容で投入する」。
- 期待: 「3行を投入しました」。
- 確認:
```sh
snow sql -c default -q "select * from data_entry_db.app.sales_entries order by input_at"
```
  3行、`input_user` に操作ユーザーが入っている。

### 7-3. CSVアップロード(異常)
- 操作: `bad.csv` をアップロード。
- 期待: エラーメッセージ(日付・商品・数量)が出て、投入ボタンが出ない。テーブル件数は変わらない。
```sh
snow sql -c default -q "select count(*) from data_entry_db.app.sales_entries"
```

### 7-4. Excelアップロード
- 操作: `ok.xlsx` をアップロード → 投入。
- 期待: 2行追加(合計5行)。小文字ヘッダー・NOTE列なしでも通る。

### 7-5. 手入力
- 操作: 「画面で入力」タブで2行入力(1行は商品を空のままにして試す) → 投入。
- 期待: 空商品行でエラー、修正後に成功。件数が増える。

### 7-6. 重複投入の挙動確認
- 操作: `ok.csv` をもう一度投入。
- 期待(想定): 重複して追加される(冪等性なし)。記事では「重複排除したい場合はMERGE方式に変える」と注意書きにする。

### 7-7. 大きめファイル
- 操作: 10,000行CSVを生成してアップロード。
```sh
uv run --with pandas python -c "
import pandas as pd, numpy as np
n=10000
pd.DataFrame({'ENTRY_DATE':'2026-10-04','PRODUCT':[f'p{i}' for i in range(n)],'QUANTITY':np.random.randint(1,10,n),'AMOUNT':np.random.rand(n)*1000}).to_csv('big.csv',index=False)"
```
- 期待: 数秒〜数十秒で完了。`MAX_ROWS`超過(10,001行)でエラー表示。処理時間をメモ(記事用)。

### 7-8. 権限(非ACCOUNTADMINユーザー) - 次節

---

## 8. 権限設計と非ACCOUNTADMINでの確認

### 設計
| ロール | 権限 | 用途 |
|---|---|---|
| ACCOUNTADMIN | 全て | 初期構築のみ(記事では簡略化) |
| DATA_ENTRY_ROLE | テーブルINSERT/SELECT、ウェアハウスUSAGE、Streamlit作成 | アプリのオーナー兼投入専用 |
| (発展) DATA_ENTRY_VIEWER_ROLE | アプリのUSAGEのみ | アプリを使うだけの人に配る専用ロール |

### 8-1. アプリ利用者ロールの追加(発展。要検証)
ここで確認したい点: 「アプリの閲覧者(USAGE付与)は、テーブル権限を持たなくてもオーナー権限で投入できるか」。

```sql
-- viewer.sql
USE ROLE ACCOUNTADMIN;
CREATE ROLE IF NOT EXISTS data_entry_viewer_role;
GRANT USAGE ON DATABASE data_entry_db TO ROLE data_entry_viewer_role;
GRANT USAGE ON SCHEMA   data_entry_db.app TO ROLE data_entry_viewer_role;
GRANT USAGE ON STREAMLIT data_entry_db.app.data_entry_app TO ROLE data_entry_viewer_role;
GRANT ROLE data_entry_viewer_role TO USER entry_user_01;
```

```sh
snow sql -c default -f viewer.sql
```

(`entry_user_01` のデフォルトロールを `data_entry_viewer_role` に変えて試すパターンと、`data_entry_role` のままのパターンの両方を確認)

### 8-2. 確認項目
1. `entry_user_01` でSnowsightにログイン → Projects > Streamlit からアプリが見える(GUI。URL直開きでも可)。
2. 手順7-2〜7-5を同ユーザーで実施 → 成功すること。
3. 直接SQLでの権限確認(CLIから `entry_user_01` として。接続を追加):
```sh
snow connection add --connection-name entry01 --account <アカウント> --user entry_user_01 \
  --authenticator snowflake --password '<パスワード>' --role data_entry_role --warehouse data_entry_wh
snow sql -c entry01 -q "select count(*) from data_entry_db.app.sales_entries"
snow sql -c entry01 -q "delete from data_entry_db.app.sales_entries"
snow sql -c entry01 -q "drop table data_entry_db.app.sales_entries"
```
  期待: `select` は成功、`delete` / `drop` は権限エラー(`Insufficient privileges`)。
4. `input_user` に `ENTRY_USER_01` が記録される(オーナー権限実行でも閲覧者名が取れるか。取れない場合は `st.user` / `st.experimental_user` 等を代替として検証)。

---

## 9. エラー時の確認ポイント

| 症状 | 確認 |
|---|---|
| `snow streamlit deploy` が失敗 | `snow streamlit deploy --debug`。`snowflake.yml` の `definition_version`、ステージ/スキーマ権限(`CREATE STREAMLIT` / `CREATE STAGE`)、`--role` 指定 |
| アプリが開かない / 権限エラー | `show grants on streamlit ...`、利用者ロールのUSAGE、ウェアハウスUSAGE |
| `ModuleNotFoundError: openpyxl` | `environment.yml` に `openpyxl` があるか、`snowflake` チャンネルに存在するか。再デプロイ(`--replace`) |
| `write_pandas` の失敗(型/列名) | 列名が大文字か、`quote_identifiers=False` か、日付型・整数型変換 |
| 日本語CSVが文字化け | UTF-8(BOM付き可)で保存。Excel保存のShift_JISのCSVは `encoding="cp932"` 対応が必要か確認 |
| `MessageSizeError` | 表示行数を制限(`head(50)`)。32MB上限(Warehouse runtime) |
| アプリ起動が遅い | Warehouse runtimeは閲覧者ごとに起動。ウェアハウスのresume待ちも含む |
| ログイン不可 | ユーザー認証方式、MFA、ネットワークポリシーを確認 |

デバッグ用SQL:

```sh
snow sql -c default -q "show streamlits in account"
snow sql -c default -q "describe streamlit data_entry_db.app.data_entry_app"
snow sql -c default -q "select * from table(data_entry_db.information_schema.query_history(result_limit=>20)) order by start_time desc"
```

---

## 10. 記事用スクリーンショット一覧

| # | 場面 | ファイル名案 |
|---|---|---|
| 1 | 完成したアプリ全体(タブ+履歴) | `app-overview.png` |
| 2 | CSVアップロード後のプレビュー+成功メッセージ | `upload-csv-success.png` |
| 3 | 不正CSVでのエラー表示 | `upload-csv-error.png` |
| 4 | Excelアップロード | `upload-xlsx.png` |
| 5 | `st.data_editor` で手入力中 | `data-editor.png` |
| 6 | `snow sql` でテーブル確認(ターミナル出力、テキストでも可) | `table-result.png` |
| 7 | `snow streamlit deploy` の出力 | `deploy-output.png` |
| 8 | 非ACCOUNTADMINユーザーで開いたアプリ | `app-as-entry-user.png` |
| 9 | `delete` が権限エラーになる出力 | `permission-denied.png` |
| 10 | (任意)Snowsightのデータロード画面との比較 | `snowsight-load.png` |

撮影時の注意: アカウント名・ユーザー名・URLはマスクする。Zenn用画像の置き場所は既存記事(`images/<記事スラッグ>/`)に合わせる。

---

## 11. クリーンアップ

```sh
snow streamlit drop data_entry_app -c default --role data_entry_role   # 失敗したら下のSQLで
snow sql -c default -q "
USE ROLE ACCOUNTADMIN;
DROP STREAMLIT IF EXISTS data_entry_db.app.data_entry_app;
DROP DATABASE IF EXISTS data_entry_db;
DROP WAREHOUSE IF EXISTS data_entry_wh;
DROP USER IF EXISTS entry_user_01;
DROP ROLE IF EXISTS data_entry_viewer_role;
DROP ROLE IF EXISTS data_entry_role;"
snow connection list   # 追加した entry01 を config.toml から手で削除
rm -rf ~/work/sis-data-entry
```

確認:

```sh
snow sql -c default -q "show databases like 'data_entry_db'"
snow sql -c default -q "show warehouses like 'data_entry_wh'"
```

期待: 0件。

---

## 12. コスト注意点
- Warehouse runtimeは、アプリを開いている間ウェアハウスが稼働する(閲覧者ごとにセッション)。`XSMALL` + `AUTO_SUSPEND=60` で十分。開きっぱなしを放置しない。
- Container runtimeはコンピュートプールが稼働し続ける(`AUTO_SUSPEND_SECS` 設定要)。検証しない場合は使わない。使うなら終了後に必ず `ALTER COMPUTE POOL ... SUSPEND` / `DROP`。
- ストレージはごく少量(数MB)で無視できる。
- 検証後はクリーンアップを実施し、`SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` で消費クレジットを記事に記録する(反映に最大数時間の遅延)。
```sh
snow sql -c default -q "select start_time, credits_used from snowflake.account_usage.warehouse_metering_history where warehouse_name='DATA_ENTRY_WH' order by start_time desc limit 24"
```

---

## 13. 未確認事項・要検証リスト

公式ドキュメント取得は一部(権限ページ)が503で失敗したため、以下は未確認。実機検証で必ず確認し、記事には確認できた内容だけを書く。

1. `snow init` と `snow streamlit init` の差異、現行CLI(3.27.0)でのテンプレート名(`example_streamlit`)と `-D` 変数名。
2. `snowflake.yml` の `identifier`(name/database/schema) と `title` の書式。
3. Streamlitアプリの実行権限モデル(オーナー権限 / 閲覧者権限)。閲覧者にテーブル権限が不要か、`CURRENT_USER()` が閲覧者を返すか。
4. アプリUSAGEの付与構文(`GRANT USAGE ON STREAMLIT ...`)と、アプリ利用に必要な最小権限セット。
5. `environment.yml` で指定可能なStreamlitバージョンの現行範囲、`openpyxl` の提供有無、Anacondaチャンネル規約同意の要否。
6. Warehouse runtimeが2026年10月時点で新規作成の既定か、Container runtime(`runtime_name` / `compute_pool`)が既定/推奨になっていないか。なっているならContainer runtime版の手順(`requirements.txt`、`snowflake.yml` の `runtime_name`/`compute_pool`)に差し替える。
7. `write_pandas` の型変換が `DATE`/`NUMBER` 列で問題ないか。
8. MFA必須化等により、パスワード認証ユーザーで検証できるか。
9. `st.dataframe(use_container_width=)` の非推奨状況。
10. トライアルアカウントでのStreamlit in Snowflake利用可否・リージョン制約。
11. Snowsightのデータロード(GUI)機能との比較は、CLI縛りの本検証では実施せず公式ドキュメント記述ベースの比較に留める。
12. Excelの複数シート・日付セル(シリアル値)の扱い。
