---
title: "Snowflake Dynamic tables を使ってIoTデバイスから収集したデータをELTする"
emoji: "❄️"
type: "tech" # tech: 技術記事 / idea: アイデア
topics:
  - aws
  - terraform
  - snowflake
  - iot
published: true
published_at: "2026-08-10 07:30"
publication_name: "fusic"
---

Snowflake Dynamic tables(動的テーブル)は定義されたクエリとターゲットの鮮度に基づいて自動更新されるテーブルを提供する機能です。

![](/images/snowflake-dynamic-tables-for-iot/snowflake_dynamic_tables.png)
<!--MEMO: ここにイメージ図を載せたい-->

AWSでETL(Extract->Load->Transform)を実現しようとするとAWS GlueやAWS Lambdaといったサービスを間に挟む必要があり、構成や設定が複雑化しがちですし、それらのメンテナンスにも一定のコストがかかります。

一方で、動的テーブルはSnowflakeに蓄積したデータをSQLで変換し定期的に別テーブルとして自動更新するため、Snowflake内に完結しますし、楽です。

本記事ではSnowflake Dynamic tables(動的テーブル)を使って、IoTデバイスから収集したデータをELT(Extract->Load->Transform)した結果をまとめます。

## 前提

先日公開したこちらの記事にて、IoTデバイスからクラウドに送信したデータをSnowpipe Streaming経由でSnowflakeに蓄積しています。

https://zenn.dev/fusic/articles/stream-iot-data-to-snowflake

IoTデバイスからは毎分周期で温度・湿度・気圧を送信しています。
かれこれ2週間ほど運用し続けているためおおよそ60分x24時間x14日=20,160レコード程度溜まっていることになります。

![](/images/snowflake-dynamic-tables-for-iot/count.png)

細かい変動を見るという点ではこのデータは有用なのですが、その日のおおよその気温を把握したい場合には細かすぎます。

![](/images/snowflake-dynamic-tables-for-iot/graph.png)

そこで、このデータを1時間単位で集約し、その時間の平均値を保持するテーブルに随時変換していくこととします。

## 動的テーブルを作成する

前回の記事と同様、Terraformを使ってリソースを作成します。

動的テーブルのリフレッシュにはウェアハウスが必要です。Snowpipe Streamingでのストリーミング取り込みとは用途が異なるため、専用のウェアハウスを新たに作成しました。

```hcl:dynamic_table.tf
resource "snowflake_warehouse" "dynamic_table" {
  name                = "IOT_STREAM_DYNAMIC_TABLE_WH"
  comment             = "ENV_SENSOR_HOURLY_AVG Dynamic Tableのリフレッシュに使うWarehouse"
  warehouse_size      = "XSMALL"
  auto_suspend        = 60
  auto_resume         = true
  initially_suspended = true
}
```

:::message
執筆時点(2026-08)では、[前回の記事](https://zenn.dev/fusic/articles/stream-iot-data-to-snowflake)で触れたテーブルを管理する`snowflake_table`リソース同様、動的テーブルを管理する`snowflake_dynamic_table`リソースもPreview機能でした。
今回もStableな`snowflake_execute`でCREATE DYNAMIC TABLE文を直接実行しています。
:::

```hcl:dynamic_table.tf
resource "snowflake_execute" "env_sensor_hourly_avg_table" {
  execute = <<-SQL
    CREATE DYNAMIC TABLE ${local.env_sensor_hourly_avg_table_fqn}
      TARGET_LAG = '1 hour'
      WAREHOUSE = ${snowflake_warehouse.dynamic_table.name}
      AS
      SELECT
        device_id,
        DATE_TRUNC('HOUR', TO_TIMESTAMP_NTZ(event_timestamp / 1000)) AS hour_bucket,
        AVG(temperature) AS avg_temperature,
        AVG(humidity) AS avg_humidity,
        AVG(pressure) AS avg_pressure
      FROM ${local.env_sensor_table_fqn}
      GROUP BY device_id, hour_bucket
  SQL

  revert = "DROP DYNAMIC TABLE ${local.env_sensor_hourly_avg_table_fqn}"

  depends_on = [snowflake_execute.env_sensor_raw_table]
}
```

`event_timestamp`はUnix時間(ミリ秒)で記録されているため、`TO_TIMESTAMP_NTZ(event_timestamp / 1000)`でタイムスタンプに変換したうえで`DATE_TRUNC('HOUR', ...)`により時刻を時間単位に切り捨てています。
`device_id`と切り捨てた時刻(`hour_bucket`)の組み合わせでGROUP BYし、温度・湿度・気圧それぞれの平均値を算出しています。

`TARGET_LAG = '1 hour'`は「元テーブルの最新状態から最大どれだけ遅れることを許容するか」を指定するオプションです。この値の実際の意味については、後述の「疑問点: 動的テーブルへの反映はいつ行われているのか？」で詳しく検証します。

以上の手順で構築したTerraformコード全体を、以下のリポジトリで公開しています。

https://github.com/yuuu/stream-iot-data-to-snowflake/pull/2

## 動的テーブルの中身を見てみる

動的テーブルに対して、次のようなSQLを実行することで、集約状況を確認します。

```sql
SELECT
  device_id,
  hour_bucket,
  ROUND(avg_temperature, 1) AS avg_temperature,
  ROUND(avg_humidity, 1) AS avg_humidity,
  ROUND(avg_pressure, 1) AS avg_pressure
FROM IOT_STREAM_IOT_DB.ENV_SENSOR.ENV_SENSOR_HOURLY_AVG
ORDER BY hour_bucket DESC, device_id
LIMIT 5;
```

```
DEVICE_ID	HOUR_BUCKET	AVG_TEMPERATURE	AVG_HUMIDITY	AVG_PRESSURE
607856DB5110	2026-08-08 11:00:00	29.8	65.5	1003.7
607856DB5110	2026-08-08 10:00:00	30.0	69.9	1003.2
607856DB5110	2026-08-08 09:00:00	29.7	69.7	1002.9
607856DB5110	2026-08-08 08:00:00	29.0	67.4	1002.8
607856DB5110	2026-08-08 07:00:00	27.6	55.5	1002.8
```

これまで収集したデータが1時間周期で集約されていることが確認できました。
また、動的テーブルは2026-08-08 16:00頃に作成したのですが、その後収集したデータに対しても随時集約がされていることが確認できます。

![](/images/snowflake-dynamic-tables-for-iot/hourly_graph.png)

同じ方法で日単位・月単位といった形で集約していくこともできますし、センサーテーブルのようなマスターデータをJOINして1つのテーブルにまとめるといったことも可能です。

AWS Glueのように別途リソースを作成したりプログラムを書く必要がないということです。これはとても便利ですね。

## 疑問点: 動的テーブルへの反映はいつ行われているのか？

実際のところ、この集約処理はどの程度の周期で実行されるのでしょうか？

集約処理はウェアハウスを起動して行われ、起動時間が課金対象となり、あまりこまめに起動しすぎると、利用料金が高額になってしまう懸念があります。

動的テーブルを生成するときに指定した`TARGET_LAG = '1 hour'`は「元テーブルのレコードに対して最大1時間まではラグ(遅延)を許容する」という意味です。
つまり、1時間以内の周期でこのクエリが実行されるものと予想されますが、より短い周期で実行される可能性もあります。

そこで次のようなSQLを実行することで、動的テーブルへの集約処理がいつ実行されたか確認します。

```sql
SELECT
  refresh_trigger,
  refresh_start_time,
  refresh_end_time
FROM TABLE(
  IOT_STREAM_IOT_DB.INFORMATION_SCHEMA.DYNAMIC_TABLE_REFRESH_HISTORY(
    NAME => 'IOT_STREAM_IOT_DB.ENV_SENSOR.ENV_SENSOR_HOURLY_AVG'
  )
)
ORDER BY refresh_start_time;
```

```
REFRESH_TRIGGER	REFRESH_START_TIME	REFRESH_END_TIME	前回からの経過時間
CREATION	2026-08-08 00:31:29	2026-08-08 00:31:31	-
MANUAL	2026-08-08 00:32:34	2026-08-08 00:32:36	65秒
SCHEDULED	2026-08-08 00:36:20	2026-08-08 00:36:22	226秒(約4分)
SCHEDULED	2026-08-08 01:28:21	2026-08-08 01:28:24	3121秒(約52分)
SCHEDULED	2026-08-08 02:17:43	2026-08-08 02:17:46	2962秒(約49分)
SCHEDULED	2026-08-08 03:10:19	2026-08-08 03:10:22	3156秒(約53分)
SCHEDULED	2026-08-08 04:00:47	2026-08-08 04:00:50	3028秒(約50分)
SCHEDULED	2026-08-08 04:53:03	2026-08-08 04:53:05	3136秒(約52分)
```

(「前回からの経過時間」列はSQLの実行結果そのものではなく、`refresh_start_time`の差分から算出したものです。`MANUAL`はテーブルの中身をすぐ確認したくて自分で手動実行したものです)

`refresh_trigger`列を見ると、`CREATION`(作成時の初回実行)・`MANUAL`(手動実行)・`SCHEDULED`(Snowflakeが自動でスケジュールした実行)の3種類があることがわかります。

作成直後こそ数分間隔という高頻度な`SCHEDULED`実行が見られましたが、4回目以降は**約50分間隔**でかなり安定しています。
`TARGET_LAG = '1 hour'`を指定しているにもかかわらず、実際には1時間より短い間隔で自動的にリフレッシュが実行されていることがわかります。

これは、動的テーブルのスケジューラが元テーブル(`ENV_SENSOR_RAW`)の更新頻度や過去のリフレッシュにかかった時間を見て、`TARGET_LAG`で指定した遅延を守れるよう、実行間隔を内部的に調整しているためだと考えられます。
今回は元テーブルに数十秒間隔で継続的にデータが追記され続けているため、`TARGET_LAG`の範囲内に収まるよう、比較的高頻度にリフレッシュされているのだと思います。

つまり`TARGET_LAG`は「この時刻に実行する」というスケジュールを直接指定するものではなく、「これくらいの遅延を許容する」という目標値を伝えるものだと理解するのがよさそうです。
実際にどの程度の頻度で実行されるかは元テーブルの更新パターンによって変わるため、コストが気になる場合は今回のように`DYNAMIC_TABLE_REFRESH_HISTORY`で実際の実行頻度を確認してみるとよいでしょう。

私が実験した環境ではおおよそ50分〜1時間周期で集約処理が実行されており、意図せずコストが高騰してしまった、といったことも起こりにくそうで、より実用的だと感じました。

## まとめ

本記事ではSnowflake Dynamic tablesを使って、分単位で収集したIoTデータを時間単位で集約しました。
データをうまく変換しながら蓄積していきたいシステムにおいて非常に有用な機能であることが確認できましたので、ぜひ活用していきたいと思います💪
