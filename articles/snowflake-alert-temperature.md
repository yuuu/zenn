---
title: "Snowflake Alertを使ってIoTデバイスから収集したデータのしきい値超過を検知する"
emoji: "❄️"
type: "tech" # tech: 技術記事 / idea: アイデア
topics:
  - aws
  - terraform
  - snowflake
  - iot
published: false
---

## はじめに

以前の記事で、M5Stack + ENV3ユニットで計測した温度・湿度・気圧データを、AWS IoT Core → Kinesis Data Firehose → Snowpipe Streaming経由でSnowflakeへストリーミング・蓄積する仕組みを構築しました。

https://zenn.dev/fusic/articles/stream-iot-data-to-snowflake

今回はこのデータ基盤を使って、「環境センサーで計測した温度が30度を超えたらメールで通知する」というよくある監視要件を、Snowflakeの機能だけで実現します。
使うのは[Snowflake Alert](https://docs.snowflake.com/ja/user-guide/alerts)です。

構築したTerraformコードは以下のリポジトリで公開しています。

https://github.com/yuuu/stream-iot-data-to-snowflake

## Snowflake Alertとは

Snowflake Alertは、スケジュール実行したSQLの結果に応じて任意のアクション(SQL)を実行できる機能です。

```sql
CREATE ALERT <name>
  WAREHOUSE = <warehouse>
  SCHEDULE = '<間隔>'
  IF (EXISTS (
    <条件を表すSELECT文>
  ))
  THEN
    <条件成立時に実行するSQL文>
```

- `SCHEDULE`には分単位の間隔か、cron式を指定できます
- `IF (EXISTS (...))`の中身が1行でも返す条件式であれば、Alertが発報(TRIGGERED)します
- `THEN`以降のアクションでは、`SYSTEM$SEND_EMAIL`によるメール通知や`SYSTEM$SEND_SNOWFLAKE_NOTIFICATION`によるNotification Integration経由の通知(Slack・Amazon SNSなど)を呼び出せます
- 実行履歴は`INFORMATION_SCHEMA.ALERT_HISTORY()`テーブル関数で確認できます

外部の監視SaaSやLambdaを用意しなくても、「Snowflakeに溜まっているデータのしきい値超過をSnowflake自身が検知して通知する」ということを実現できる点がメリットです。

## Terraformによる構築

[`alert.tf`](https://github.com/yuuu/stream-iot-data-to-snowflake/blob/7bf9f0c965909fff29be94176a30719324081268/terraform/alert.tf)として以下の5つのリソースを追加しました。

1. Alertの条件評価専用Warehouse
2. 発報履歴を記録するログテーブル
3. メール通知用のNotification Integration
4. Alert本体
5. AlertをRESUMEする実行

:::message
執筆時点(2026-08)では、TerraformプロバイダのSnowflake providerが提供する`snowflake_alert`リソース[^1]・`snowflake_notification_integration`リソース[^2]はいずれもPreview機能です(`snowflake_notification_integration`に至ってはTYPE=EMAILそのものに対応していません)。
本記事でも、前回記事の`ENV_SENSOR_RAW`テーブル作成時と同様、これらをStableな`snowflake_execute`リソースで代替しています。
:::

### Alert専用Warehouseとログテーブル

Alertの条件評価にはWarehouseが必要です。
Firehoseのストリーミング取り込みやDynamic Tableのリフレッシュとは用途が異なるため、専用のWarehouseを用意しました。

```hcl:alert.tf
resource "snowflake_warehouse" "alert" {
  name                = "IOT_STREAM_ALERT_WH"
  comment             = "ENV_SENSOR_RAWのTEMPERATURE監視Alertの条件評価に使うWarehouse"
  warehouse_size      = "XSMALL"
  auto_suspend        = 60
  auto_resume         = true
  initially_suspended = true
}
```

発報したことをあとから追跡できるよう、専用のログテーブルも用意します。

```hcl:alert.tf
resource "snowflake_execute" "env_sensor_temperature_alert_log_table" {
  execute = "CREATE TABLE ${local.env_sensor_temperature_alert_log_table_fqn} (device_id VARCHAR, temperature FLOAT, event_timestamp NUMBER, alerted_at TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP())"
  revert  = "DROP TABLE ${local.env_sensor_temperature_alert_log_table_fqn}"
}
```

### メール通知用のNotification Integration

`SYSTEM$SEND_EMAIL`でメール通知するには、事前に`TYPE = EMAIL`のNotification Integrationが必要です。

```hcl:alert.tf
resource "snowflake_execute" "temperature_alert_notification_integration" {
  execute = <<-SQL
    CREATE NOTIFICATION INTEGRATION ${local.temperature_alert_notification_integration_name}
      TYPE = EMAIL
      ENABLED = TRUE
      DEFAULT_RECIPIENTS = ('${var.alert_notification_email}')
      DEFAULT_SUBJECT = 'ENV_SENSOR_RAW 温度アラート'
  SQL

  revert = "DROP NOTIFICATION INTEGRATION ${local.temperature_alert_notification_integration_name}"
}
```

:::message
Alertを作成・実行するロールには`EXECUTE ALERT`権限が必要です。
事前にACCOUNTADMINロールで以下を実行しておく必要があります。

```sql
GRANT EXECUTE ALERT ON ACCOUNT TO ROLE IOT_STREAM_TF_ADMIN_ROLE;
GRANT CREATE INTEGRATION ON ACCOUNT TO ROLE IOT_STREAM_TF_ADMIN_ROLE;
```
:::

:::message
任意の外部メールアドレスへは送信できません[^3]。
Snowsight左下のユーザー名 → 「Settings」→「My Profile」からメールアドレスを登録し、検証メールのリンクをクリックしておく必要があります。
:::

### Alert本体

いよいよAlert本体です。
条件・アクションの中身は次章で詳しく解説するので、まずは全体構造を見てください。

```hcl:alert.tf
resource "snowflake_execute" "temperature_alert" {
  execute = <<-SQL
    CREATE ALERT ${local.temperature_alert_fqn}
      WAREHOUSE = ${snowflake_warehouse.alert.name}
      SCHEDULE = '1 MINUTE'
      IF (EXISTS (
        ${local.temperature_alert_crossing_rows_query}
      ))
      THEN
        EXECUTE IMMEDIATE $$
          DECLARE
            triggered_device_ids VARCHAR;
          BEGIN
            INSERT INTO ${local.env_sensor_temperature_alert_log_table_fqn} (device_id, temperature, event_timestamp)
              ${local.temperature_alert_crossing_rows_query};

            SELECT LISTAGG(DISTINCT device_id, ', ') INTO :triggered_device_ids
              FROM (${local.temperature_alert_crossing_rows_query});

            CALL SYSTEM$SEND_EMAIL(
              '${local.temperature_alert_notification_integration_name}',
              '${var.alert_notification_email}',
              'ENV_SENSOR_RAW 温度アラート',
              'DEVICE_ID=' || :triggered_device_ids || 'の温度が30度を超えました。'
            );

            RETURN 'ALERTED';
          END;
        $$
  SQL

  revert = "DROP ALERT ${local.temperature_alert_fqn}"

  depends_on = [
    snowflake_execute.env_sensor_raw_table,
    snowflake_execute.env_sensor_temperature_alert_log_table,
    snowflake_execute.temperature_alert_notification_integration,
  ]
}
```

### AlertのRESUME

`CREATE ALERT`直後のAlertはSUSPENDED状態で作成されるため、明示的に`ALTER ALERT ... RESUME`を実行する必要があります。

```hcl:alert.tf
resource "snowflake_execute" "temperature_alert_resume" {
  execute = "ALTER ALERT ${local.temperature_alert_fqn} RESUME -- alert_execution_id=${snowflake_execute.temperature_alert.id}"
  revert  = "ALTER ALERT ${local.temperature_alert_fqn} SUSPEND"

  depends_on = [snowflake_execute.temperature_alert]
}
```

:::message
`execute`の中身にコメントとして`snowflake_execute.temperature_alert.id`を埋め込んでいるのには理由があります。

`snowflake_execute`リソースは`execute`の文言が変わるとリソースごと作り直されます(DROP→CREATE)。
Alert本体のSQLを変更するとAlertはDROP→CREATEされ、再びSUSPENDED状態になります。

ところが、RESUME用リソースの`execute`文言(`ALTER ALERT xxx RESUME`)自体はAlert本体のSQL変更と無関係に変わらないため、Terraformは「差分なし」と判断してRESUMEを再実行しません。
結果、Alert本体を作り直したのにRESUMEされずSUSPENDEDのまま放置される、という罠にハマりました。

対策として、Alert本体のリソースID(作り直されるたびに変わる)をSQLコメントとして埋め込み、Alert本体が置き換わるたびにRESUME側も強制的に再実行されるようにしています。
:::

## SQLクエリの解説

ここからは、Alertの条件・アクションで使っている`temperature_alert_crossing_rows_query`の中身を解説します。

```sql
SELECT device_id, temperature, event_timestamp
FROM (
  SELECT
    device_id,
    temperature,
    event_timestamp,
    LAG(temperature) OVER (PARTITION BY device_id ORDER BY event_timestamp) AS prev_temperature
  FROM ENV_SENSOR_RAW
)
WHERE TO_TIMESTAMP_LTZ(event_timestamp / 1000)
        BETWEEN GREATEST(
                  SNOWFLAKE.ALERT.LAST_SUCCESSFUL_SCHEDULED_TIME(),
                  DATEADD('minute', -5, SNOWFLAKE.ALERT.SCHEDULED_TIME())
                )
                AND SNOWFLAKE.ALERT.SCHEDULED_TIME()
  AND temperature > 30
  AND (prev_temperature IS NULL OR prev_temperature <= 30)
```

### 単純に「30度超」を条件にすると同じアラートが何度も送信される

最初に書いたのは、単純に「新規行のTEMPERATUREが30度を超えているか」という条件でした。

```sql
WHERE TO_TIMESTAMP_LTZ(event_timestamp / 1000)
        BETWEEN SNOWFLAKE.ALERT.LAST_SUCCESSFUL_SCHEDULED_TIME() AND SNOWFLAKE.ALERT.SCHEDULED_TIME()
  AND temperature > 30
```

`SNOWFLAKE.ALERT.LAST_SUCCESSFUL_SCHEDULED_TIME()`は「前回成功したスケジュール実行の時刻」、`SNOWFLAKE.ALERT.SCHEDULED_TIME()`は「今回の実行がスケジュールされた時刻」を返す関数で、この2つの間に絞り込むことで「前回チェック以降の新規行だけ」を対象にできます。

ところが検証してみると、これでは閾値超過が続く限り毎回のスケジュール実行(1分毎)で検知され続けることが分かりました。

### DEVICE_ID ごとのエッジ検知に変更する

そこで、単に「30度を超えている」ではなく、「 `DEVICE_ID` ごとに、直前の行は30度以下だったのに、今回は30度を超えた」という立ち上がりエッジだけを検知するように変更しました。

`LAG(temperature) OVER (PARTITION BY device_id ORDER BY event_timestamp)`で「同じ `DEVICE_ID` の直前の行の温度」を取得し、`temperature > 30 AND (prev_temperature IS NULL OR prev_temperature <= 30)`で絞り込みます。

ポイントは、`LAG`はテーブル全体を対象に計算し、`LAST_SUCCESSFUL_SCHEDULED_TIME()`〜`SCHEDULED_TIME()`による絞り込みは最後のWHERE句だけに適用していることです。
こうすることで、「直前の行」がスケジュール実行のウィンドウをまたいで少し前に届いていた場合でも、正しく参照できます。

### Alert再作成のたびに過去データが一括検知される

エッジ検知に変更してAlertを`terraform apply`で作り直したところ、今度は別の問題が起きました。
1回のスケジュール実行で、1通のメールに大量の `DEVICE_ID` が詰め込まれて届いたのです。

原因は`SNOWFLAKE.ALERT.LAST_SUCCESSFUL_SCHEDULED_TIME()`の挙動でした。
この関数は「前回成功した実行時刻」を返しますが、Alertを作り直した直後の初回実行では「前回」が存在しないため、非常に古い時刻を返します。
その結果、WHERE句の下限が事実上存在しないのと同じになり、テーブルの全履歴が対象になってしまいます。

Alertの`execute`文言(=SQL)を変更すると、`snowflake_execute`リソースはAlertをDROP→CREATEで作り直すため、Terraformで少しSQLを調整するたびにこの一括検知が再発することになります。

対策として、下限を「`SCHEDULED_TIME()`から遡って最大5分前」に`GREATEST`でクランプしました。

```sql
BETWEEN GREATEST(
          SNOWFLAKE.ALERT.LAST_SUCCESSFUL_SCHEDULED_TIME(),
          DATEADD('minute', -5, SNOWFLAKE.ALERT.SCHEDULED_TIME())
        )
        AND SNOWFLAKE.ALERT.SCHEDULED_TIME()
```

`SCHEDULE = '1 MINUTE'`に対して5分のバッファを持たせているのは、多少の実行遅延を許容するためです。
これで、Alertを何度作り直しても常に直近数分以内のみが対象になり、過去データの一括検知は起きなくなりました。

### THEN句を1つのSQL文にまとめる

`CREATE ALERT`のTHEN句には単一のSQL文しか書けません。
今回はログテーブルへのINSERTとメール送信という2つの処理を行いたいため、`EXECUTE IMMEDIATE $$ ... $$`でSnowflake Scriptingの匿名ブロックにまとめています。

```sql
EXECUTE IMMEDIATE $$
  DECLARE
    triggered_device_ids VARCHAR;
  BEGIN
    INSERT INTO ENV_SENSOR_TEMPERATURE_ALERT_LOG (device_id, temperature, event_timestamp)
      <crossing_rows_query>;

    SELECT LISTAGG(DISTINCT device_id, ', ') INTO :triggered_device_ids
      FROM (<crossing_rows_query>);

    CALL SYSTEM$SEND_EMAIL(...);

    RETURN 'ALERTED';
  END;
$$
```

`DECLARE`〜`BEGIN`〜`END`のブロック全体が1つのSQL文として扱われるため、THEN句の制約を回避しつつ複数の処理を実行できます。

`SELECT ... INTO :変数名`で検知した行の `DEVICE_ID` を集約し、メール本文に埋め込んでいる点もポイントです。
ここでも`LISTAGG(device_id, ...)`のまま(DISTINCT無し)にしていたところ、同一デバイスが1回の評価内で複数回エッジ検知した場合に、メール本文に同じ `DEVICE_ID` が重複して並んでしまう不具合がありました。
`LISTAGG(DISTINCT device_id, ', ')`に修正して解消しています。

## 動作確認

実機のデータは真夏の室内計測のため自然と30度を超えることもありますが、狙ったタイミングで再現性よく確認するために、テスト用の `DEVICE_ID` でデータを投入する手順を記載します。

### エッジ検知を手動で発生させる

`test-device`という架空の `DEVICE_ID` で、「30度以下→30度超」の2行を投入します。

```sql
USE WAREHOUSE IOT_STREAM_ALERT_WH;

INSERT INTO ENV_SENSOR_RAW (temperature, humidity, pressure, event_timestamp, device_id)
VALUES (25.0, 50.0, 1013.0, DATE_PART(EPOCH_MILLISECOND, CURRENT_TIMESTAMP()), 'test-device');

INSERT INTO ENV_SENSOR_RAW (temperature, humidity, pressure, event_timestamp, device_id)
VALUES (35.0, 50.0, 1013.0, DATE_PART(EPOCH_MILLISECOND, CURRENT_TIMESTAMP()) + 1000, 'test-device');
```

単に30度超のデータを1件INSERTするだけでは、直前の行がすでに30度超だとエッジ検知されないため、必ず「30度以下→30度超」の順で2行投入する必要があります。

### ALERT_HISTORYで発報を確認する

`INFORMATION_SCHEMA.ALERT_HISTORY()`で実行履歴を確認できます。

```sql
USE DATABASE IOT_STREAM_IOT_DB;
USE WAREHOUSE IOT_STREAM_ALERT_WH;

SELECT NAME, STATE, SCHEDULED_TIME, COMPLETED_TIME
FROM TABLE(INFORMATION_SCHEMA.ALERT_HISTORY(
  SCHEDULED_TIME_RANGE_START => DATEADD('hour', -1, CURRENT_TIMESTAMP()),
  ALERT_NAME => 'IOT_STREAM_IOT_DB.ENV_SENSOR.IOT_STREAM_ENV_SENSOR_TEMPERATURE_ALERT'
))
ORDER BY SCHEDULED_TIME DESC;
```

```
NAME                                      STATE            SCHEDULED_TIME  COMPLETED_TIME
IOT_STREAM_ENV_SENSOR_TEMPERATURE_ALERT   TRIGGERED        03:31:27        03:31:31
IOT_STREAM_ENV_SENSOR_TEMPERATURE_ALERT   CONDITION_FALSE  03:30:27        03:30:29
```

`TRIGGERED`になっていれば検知成功、`CONDITION_FALSE`なら条件不成立(エッジが発生していない)です。

:::message
`ALERT_NAME`パラメータには完全修飾名を渡す必要があります。
またこの関数を呼ぶ前に`USE DATABASE`しておかないと、`ALERT_NAME`を渡していても0件になることがありました。
:::

### ログテーブルとメールで結果を確認する

ログテーブルには、検知した行がそのまま記録されています。

```sql
SELECT * FROM ENV_SENSOR_TEMPERATURE_ALERT_LOG ORDER BY alerted_at DESC;
```

```
DEVICE_ID     TEMPERATURE  EVENT_TIMESTAMP  ALERTED_AT
test-device   35.0         1787481081791    2026-08-23 03:31:29
```

そして、指定したメールアドレスに以下の本文でメールが届きました。

```
DEVICE_ID=test-deviceの温度が30度を超えました。
```

同じ `DEVICE_ID` が1回の評価内で複数回エッジ検知するケース(30度以下→超過→以下→超過、を短時間で繰り返す)も試しましたが、ログテーブルには2行記録されつつ、メール本文の `DEVICE_ID` は重複せず1回だけ表示されることを確認できました。

## おわりに

Snowflakeに蓄積したIoTセンサーデータに対して、外部の監視サービスを使わずSnowflake Alertだけでしきい値超過を検知・通知する仕組みを構築しました。

単純な「しきい値超過」を検知条件にすると、超過状態が続く限り通知され続けてしまう(アラート疲れ)という点に注意が必要でしたが、`LAG()`によるエッジ検知に切り替えることで解決できました。
また、`snowflake_execute`でAlertを管理する場合は、SQLを変更するたびにAlertがDROP→CREATEされ直す点や、それに伴う「初回実行時の過去データ一括検知」「RESUMEの再実行漏れ」といった、Terraform運用ならではの落とし穴もいくつか踏みました。

構築したTerraformコードは以下のリポジトリで公開しています。

https://github.com/yuuu/stream-iot-data-to-snowflake

メール以外にも、Notification Integration経由でSlackへ通知する、といった応用もできそうです。
次はそのあたりも試してみたいと思います。

[^1]: https://registry.terraform.io/providers/Snowflake-Labs/snowflake/latest/docs/resources/alert
[^2]: https://registry.terraform.io/providers/Snowflake-Labs/snowflake/latest/docs/resources/notification_integration
[^3]: https://docs.snowflake.com/en/sql-reference/sql/create-notification-integration-email
