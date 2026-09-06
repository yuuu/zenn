---
title: "Snowflakeのデータが可視化しにくい？MetabaseでIoTデータのダッシュボードを構築する"
emoji: "❄️"
type: "tech" # tech: 技術記事 / idea: アイデア
topics:
  - snowflake
  - metabase
  - iot
  - bi
published: true
published_at: "2026-09-07 07:30"
publication_name: "fusic"
---

## はじめに

Snowflakeに自室の環境センサーの測定値を計測しはじめて1ヶ月が経過しました。

これまで溜まったデータはSnowsightでSQLを実行することで確認していたのですが、SQLを実行するのは毎回手間ですし、データの量が増えたことでなかなかグラフが描画されないといった課題が顕在化してきました。

Snowflakeにデータを蓄積すれば可視化まで一気通貫で実現できると思っていましたが、本格的な可視化をしようとすると [Snowflake App Runtime](https://docs.snowflake.com/en/developer-guide/snowflake-app-runtime/about-snowflake-app-runtime) でフロントエンドを構築するか、 [Streamlit in Snowflake](https://docs.snowflake.com/ja/developer-guide/streamlit/about-streamlit) を使うといった方法が考えられるようです。
どちらもプログラムを書いてWebアプリケーションを構築することが前提です。

より簡単に可視化をするとなると、BIツールを活用する方法が候補にあがります。
今回はOSSのBIツールである「Metabase」をSnowflakeに接続してみました。

https://www.metabase.com/

![](/images/snowflake-metabase-iot-dashboard/013.png)

## 事前準備

MetabaseからSnowflakeに接続するための準備をします。

### 認証用のRSA private key

次のコマンドを実行し、RSA private keyを生成し、Snowflakeに公開鍵を設定しておきます。

```sh
# 秘密鍵の生成（パスフレーズなし）
openssl genrsa 2048 | openssl pkcs8 -topk8 -inform PEM -nocrypt -out rsa_key.p8

# 公開鍵の生成
openssl rsa -in rsa_key.p8 -pubout -out rsa_key.pub
PUBLIC_KEY=$(grep -v "PUBLIC KEY" rsa_key.pub | tr -d '\n')

# Snowflakeに公開鍵を登録
snow sql -q "ALTER USER your_username SET RSA_PUBLIC_KEY='${PUBLIC_KEY}';" -c your_existing_connection
snow sql -q "DESC USER your_username;" -c your_existing_connection
```

:::message
MetabaseのSnowflakeコネクタは、パスフレーズ付きの秘密鍵に対応していません（パスフレーズを入力する欄がありません）。
パスフレーズ付きの鍵をアップロードすると `Cannot invoke "String.toCharArray()" because "privateKeyPwd" is null` というエラーになります。
上記のように `-nocrypt` を付けて、パスフレーズなしで秘密鍵を生成してください。
:::

## ウェアハウスの起動

Snowflakeにおける計算リソースであるウェアハウスを事前に起動しておきます。

```sh
# 起動
snow sql -q "CREATE WAREHOUSE IF NOT EXISTS demo_wh
  WAREHOUSE_SIZE = 'XSMALL'
  AUTO_SUSPEND = 60
  AUTO_RESUME = TRUE;" -c your_existing_connection

# ステータスチェック
# state=STARTEDであることを確認
snow sql -q "SHOW WAREHOUSES LIKE 'demo_wh';" -c your_existing_connection

# アカウント識別子を取得
snow sql -q "
SELECT CURRENT_ORGANIZATION_NAME() || '-' || CURRENT_ACCOUNT_NAME() AS account_identifier;
" -c your_existing_connection

# データベース一覧を表示
snow sql -q "SHOW DATABASES;" -c your_existing_connection
```

## Metabaseを立ち上げる

Metabaseを手元のPCで立ち上げます。
構築にはDockerイメージを活用すると便利です。


[公式ドキュメント](https://www.metabase.com/docs/latest/installation-and-operation/running-metabase-on-docker) を参考にコマンドを実行します。

```sh
docker pull metabase/metabase:latest
docker run -d -p 3000:3000 --name metabase metabase/metabase
```

コンテナが立ち上がったら http://localhost:3000 にアクセスしてみましょう。
次のような画面が表示されます。

![](/images/snowflake-metabase-iot-dashboard/001.png)

次の画面に進むとユーザー情報の入力を求められます。

![](/images/snowflake-metabase-iot-dashboard/002.png)

用途を尋ねられます。
今回は「自社向けのセルフサービス分析」としました。

![](/images/snowflake-metabase-iot-dashboard/003.png)

## Snowflakeに接続する

次に進むと早速データベースへの接続ができるようです。
「Snowflake」を選択します。

![](/images/snowflake-metabase-iot-dashboard/004.png)

次の情報を入力して接続します。

![](/images/snowflake-metabase-iot-dashboard/005.png)

| 項目 | 入力内容 |
| --- | --- |
| 表示名 | 任意の名前 |
| Account name | 先のコマンドで取得したアカウント識別子 |
| ユーザー名 | Snowflakeのユーザー名 |
| RSA private key | 作成した `rsa_key.p8` をアップロードする |
| Warehouse | `demo_wh` |
| Database name | `IOT_STREAM_IOT_DB` ( [以前の記事](https://zenn.dev/fusic/articles/stream-iot-data-to-snowflake) で作成したDB) |

接続に成功すると「データベース」に登録したSnowflakeの接続が表示されます。

![](/images/snowflake-metabase-iot-dashboard/007.png)

## データを閲覧する

データベースの詳細画面に移動すると、画面の右上に「データを閲覧」というボタンが表示されています。
これをクリックします。

![](/images/snowflake-metabase-iot-dashboard/008.png)

データベース中のテーブルが表示されます。
今回は「Env Sensor Row」をクリックします。

![](/images/snowflake-metabase-iot-dashboard/009.png)

テーブルの中身が表示されます。

![](/images/snowflake-metabase-iot-dashboard/010.png)

画面左下の「可視化」をクリックするとさまざまな種類のグラフを選択できます。

![](/images/snowflake-metabase-iot-dashboard/011.png)

あとはX軸やY軸の値を差し替えたり、フィルタリングしたり、場合によってはSQLを直接書いたりすることでグラフを出すことができます。

![](/images/snowflake-metabase-iot-dashboard/012.png)

いろいろなグラフや値を準備しそれを集めると冒頭のようなダッシュボードも作成できます。

![](/images/snowflake-metabase-iot-dashboard/013.png)

## おわりに

本記事ではOSSのBIツールであるMetabaseをSnowflakeに接続し、データを集計・可視化しました。
手元のPCでデータを集計・可視化するだけであれば十分有用であると感じました。

ダッシュボードを他のユーザーと共有したくなった場合にはMetabaseをクラウドでホスティングすることを考える必要がありそうです。
この点についてもいずれ調べてみたいと思いました。
