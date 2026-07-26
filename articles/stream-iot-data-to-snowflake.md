---
title: "Snowflake × IoT: Snowpipe Streamingを使ってデバイスから送信したセンサーデータを数秒以内に蓄積する"
emoji: "❄️"
type: "tech" # tech: 技術記事 / idea: アイデア
topics:
  - aws
  - terraform
  - snowflake
  - iot
  - m5stack
published: true
published_at: "2026-07-27 07:30"
publication_name: "fusic"
---

## はじめに

ATOMS3 Liteに接続した環境センサーで計測した温度・湿度・気圧のデータを、AWS IoT Core経由でSnowflakeへリアルタイムに届け続ける仕組みを、実際に手を動かしながら構築します。

![](/images/stream-iot-data-to-snowflake/snowsight.png)

ポイントは、Amazon Data Firehoseに用意されているSnowflakeへの連携機能([Snowpipe Streaming](https://docs.snowflake.com/ja/user-guide/snowpipe-streaming/data-load-snowpipe-streaming-overview)への配信)を使う点です。
Lambdaや変換用のアプリケーションコードを一切書かずに、IoTデバイスのデータをSnowflakeのテーブルへ直接ストリーミングできます。

## 全体構成

構築するシステムの全体像は以下の通りです。

![](/images/stream-iot-data-to-snowflake/aws-snowflake.png)

| コンポーネント | 役割 |
| --- | --- |
| ATOMS3 Lite + ENV Ⅲ ユニット | 温湿度センサー(SHT30)と気圧センサー(QMP6988)を搭載したユニットで、温度・湿度・気圧を計測します |
| AWS IoT Core | デバイスからMQTT(TLS)で送信されたデータを受信します |
| Amazon Data Firehose | AWS IoT Coreからのデータをバッファリングし、Snowflakeへ配信します |
| Snowpipe Streaming | Amazon Data Firehoseから配信されたデータをテーブルへ配信します |
| Snowflake Databases | データの格納先データベースです |

※ATOMS3 LiteはM5Stack社が販売している小型の開発モジュールです。

## 前提条件

以下が準備できている前提で進めます。

- AWS CLIで認証できるプロファイルがあること
- Terraform([最新バージョン](https://developer.hashicorp.com/terraform/install))、[AWS provider](https://registry.terraform.io/providers/hashicorp/aws/latest)、[Snowflake provider](https://registry.terraform.io/providers/snowflakedb/snowflake/latest)がインストールできる環境
- Snowflakeアカウントと、キーペア認証で接続できる管理用ユーザー(Terraformでデータベース・スキーマ・ロール・ユーザーを作成できる権限を持つもの)
  - キーペア認証の設定方法は[Snowflake公式ドキュメント](https://docs.snowflake.com/ja/user-guide/key-pair-auth)を参照してください
- [ATOMS3 Lite](https://www.switch-science.com/products/8778)と[ENV Ⅲ ユニット](https://docs.m5stack.com/ja/unit/envIII)

:::message
Snowflakeアカウントが共用環境の場合、Role・User・Databaseの名前はアカウント全体でユニークである必要があるため、プレフィックスを付けるなど他利用者との名前衝突に注意してください。
:::

## 構築

### Terraformプロジェクトを作成する

Terraform・AWS provider・Snowflake providerはすべて執筆時点の最新バージョンを使います。

```hcl:versions.tf
terraform {
  required_version = ">= 1.15.8"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.56"
    }
    snowflake = {
      source  = "snowflakedb/snowflake"
      version = "~> 2.18"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.3"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.6"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}
```

Snowflakeプロバイダは2系がGA(Generally Available)になっており、キーペア認証(`SNOWFLAKE_JWT`)で接続します。
AWSプロファイル名など環境固有の値は`terraform.tfvars`(gitignore対象)に切り出し、リポジトリには含めません。

```hcl:providers.tf
provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile
}

provider "snowflake" {
  organization_name = var.snowflake_organization_name
  account_name      = var.snowflake_account_name
  user              = var.snowflake_admin_user
  authenticator     = "SNOWFLAKE_JWT"
  private_key       = file(var.snowflake_admin_private_key_path)
}
```

### AWS IoT Core関連リソースを構築する

デバイス用のThing・証明書・Policy・Topic Ruleを作成します。
証明書はCSRを指定せずに`aws_iot_certificate`を作成すると、AWS側で鍵ペアごと生成してくれます。

利用するデバイス側のプログラム(後述)はMQTTのクライアントIDが`env-sensor-device`に固定されているため、IoT PolicyのConnectアクションもこのクライアントIDに限定しています。

```hcl:iot.tf
resource "aws_iot_policy" "env_sensor" {
  name = "${var.project_name}-policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "iot:Connect"
        Resource = "arn:aws:iot:${var.aws_region}:${data.aws_caller_identity.current.account_id}:client/${var.project_name}-device"
      },
      {
        Effect   = "Allow"
        Action   = "iot:Publish"
        Resource = "arn:aws:iot:${var.aws_region}:${data.aws_caller_identity.current.account_id}:topic/${var.project_name}/*"
      },
    ]
  })
}
```

IoT Ruleでは、受信したメッセージをそのままFirehoseへ転送するだけでなく、`timestamp()`関数でUnix時間(ミリ秒)を、`topic()`関数でMQTTトピック名からデバイスIDを抽出・付加しています。
デバイス側はトピック名`env-sensor/<チップID>`宛にpublishしているため、`topic(2)`でチップID部分を取得できます。

:::message
AWS IoT SQLの`topic(n)`は1始まりです。トピック`env-sensor/ABCD1234`に対して`topic(1)`は`"env-sensor"`、`topic(2)`が`"ABCD1234"`になります。
0始まりだと勘違いして`topic(1)`を使ってしまうと、意図しない固定文字列がdevice_idに入ってしまうので注意しましょう。
https://docs.aws.amazon.com/ja_jp/iot/latest/developerguide/iot-sql-functions.html#iot-function-topic
:::

```hcl:iot.tf
resource "aws_iot_topic_rule" "env_sensor_to_firehose" {
  name        = "${replace(var.project_name, "-", "_")}_to_firehose"
  description = "Forward env-sensor telemetry to Amazon Data Firehose"
  enabled     = true
  sql         = "SELECT *, timestamp() AS event_timestamp, topic(2) AS device_id FROM '${var.project_name}/#'"
  sql_version = "2016-03-23"

  firehose {
    delivery_stream_name = aws_kinesis_firehose_delivery_stream.env_sensor.name
    role_arn             = aws_iam_role.iot_rule_firehose.arn
  }
}
```

### Amazon Data FirehoseでSnowflake配信を構築する

Amazon Data Firehoseには`destination = "snowflake"`を指定するだけで使えるSnowflakeとの連携機能があります。
これが実質的にSnowpipe Streamingの窓口になっており、Lambdaなどでの変換処理は不要です。

```hcl:firehose.tf
resource "aws_kinesis_firehose_delivery_stream" "env_sensor" {
  name        = "${var.project_name}-to-snowflake"
  destination = "snowflake"

  snowflake_configuration {
    account_url = "https://${var.snowflake_organization_name}-${var.snowflake_account_name}.snowflakecomputing.com"

    user        = snowflake_service_user.firehose_ingest.name
    private_key = local.firehose_private_key_oneline

    database = snowflake_database.iot.name
    schema   = snowflake_schema.env_sensor.name
    table    = "ENV_SENSOR_RAW"

    data_loading_option = "JSON_MAPPING"

    role_arn = aws_iam_role.firehose.arn

    s3_configuration {
      role_arn   = aws_iam_role.firehose.arn
      bucket_arn = aws_s3_bucket.firehose_backup.arn
    }
  }
}
```

`s3_configuration`はAWS公式ドキュメントで**必須**とされているブロックで、省略できません。
Snowflakeへの配信に失敗したレコードはこのS3バケットにバックアップされます。

実際、動作確認時に問題が発生した際、このS3バケットに格納されたオブジェクトがトラブルシュートに役立つことがあります。
バックアップバケットが存在することを覚えておきましょう。

### Snowflake側のDatabase/Table/Roleを構築する

Database・Schema・Role・Service Userを作成し、FirehoseがINSERTできるように権限を付与します。

```hcl:snowflake.tf
resource "snowflake_database" "iot" {
  name    = "IOT_STREAM_IOT_DB"
  comment = "IoTデバイスから収集したテレメトリを格納するデータベース"
}

resource "snowflake_schema" "env_sensor" {
  database = snowflake_database.iot.name
  name     = "ENV_SENSOR"
}

resource "snowflake_service_user" "firehose_ingest" {
  name           = "IOT_STREAM_FIREHOSE_INGEST_USER"
  comment        = "Amazon Data Firehoseがキーペア認証で使用するサービスユーザー"
  rsa_public_key = local.firehose_public_key_oneline
  default_role   = snowflake_account_role.firehose_ingest.name
}
```

:::message
執筆時点(2026-07)ではテーブルを管理する`snowflake_table`リソースはPreview機能でした。
代わりにStableな`snowflake_execute`でCREATE TABLE文を直接実行しています。
:::

```hcl:snowflake.tf
resource "snowflake_execute" "env_sensor_raw_table" {
  execute = "CREATE TABLE ${local.env_sensor_table_fqn} (temperature FLOAT, humidity FLOAT, pressure FLOAT, event_timestamp NUMBER, device_id VARCHAR)"
  revert  = "DROP TABLE ${local.env_sensor_table_fqn}"
}
```

以上の手順で構築したTerraformコード全体を、以下のリポジトリで公開しています。

https://github.com/yuuu/stream-iot-data-to-snowflake

## 動作確認

### テストデータで疎通確認する

`terraform apply`でAWS・Snowflake側のリソースを作成したら、実機の前にまずテストデータで疎通確認します。AWS CLIの`aws iot-data publish`でIoT Coreへ直接メッセージをpublishできます。

```bash
aws iot-data publish \
  --endpoint-url https://<IoTエンドポイント> \
  --topic "env-sensor/TESTDEVICE123" \
  --payload '{"temperature": 22.2, "humidity": 55.5, "pressure": 1005.5}' \
  --cli-binary-format raw-in-base64-out
```

Firehoseの配信状況はCloudWatchメトリクスで確認できます。`DeliveryToSnowflake.Success`が1であれば配信成功、`DeliveryToSnowflake.DataFreshness`は受信からSnowflakeへの到達までの時間(秒)を表します。

```bash
aws cloudwatch get-metric-statistics \
  --namespace AWS/Firehose \
  --metric-name DeliveryToSnowflake.Success \
  --dimensions Name=DeliveryStreamName,Value=env-sensor-to-snowflake \
  --start-time <開始時刻> --end-time <終了時刻> \
  --period 60 --statistics Sum
```

実際に試したところ、`DataFreshness`は8秒でした。バッチ処理を挟まずに、送信から数秒でSnowflakeのテーブルに反映されます。

```sql
SELECT * FROM IOT_STREAM_IOT_DB.ENV_SENSOR.ENV_SENSOR_RAW LIMIT 1;
```

```
TEMPERATURE	HUMIDITY	PRESSURE	EVENT_TIMESTAMP	DEVICE_ID
22.2	55.5	1005.5	1784969578218	TESTDEVICE123
```

### ATOMS3 Lite側をセットアップする

![](/images/stream-iot-data-to-snowflake/atoms3-lite-unit-env-iii.jpeg)

デバイス側のソースコードは以下のリポジトリの`device/env-sensor`を利用しています。

https://github.com/yuuu/aws-m5stack-iot-handson-book-site/tree/main/device

このリポジトリには証明書一式を読み込んで`arduino_secrets.h`を対話的に生成するスクリプトを格納しています。
Terraformが生成した証明書(`AmazonRootCA1.pem`・デバイス証明書・秘密鍵)を`device/env-sensor/certs/`にコピーしてから実行します。

```bash
./create-arduino-secrets.sh
```

Wi-Fi SSID/パスワードとAWS IoTエンドポイントを入力します。
証明書ファイルは自動検出されて`arduino_secrets.h`が生成されます。あとはビルドして実機に書き込みます。

```bash
make build
make upload
make monitor
```

### 実機からのデータ到達を確認する

実機がAWS IoT Coreへpublishを開始したら、再度Snowflakeでテーブルを確認します。

```sql
SELECT * FROM IOT_STREAM_IOT_DB.ENV_SENSOR.ENV_SENSOR_RAW ORDER BY EVENT_TIMESTAMP DESC LIMIT 5;
```

```
TEMPERATURE	HUMIDITY	PRESSURE	EVENT_TIMESTAMP	DEVICE_ID
30.95216	72.64099	1009.547	1785044144693	607856DB5110
30.93881	72.6593		1009.564	1785044084674	607856DB5110
30.92279	72.66693	1009.557	1785044024672	607856DB5110
30.93881	72.65015	1009.531	1785043964703	607856DB5110
30.95216	72.70508	1009.539	1785043904970	607856DB5110
```

`event_timestamp`(Unix時間ミリ秒)と`device_id`(実機のチップID)も正しく記録されていることが確認できました。
ATOMS3 Liteの実測データがSnowflakeへ蓄積されていることがわかります。

このように気温推移の時系列グラフも簡単に表示できます。

![](/images/stream-iot-data-to-snowflake/snowsight.png)

## まとめ

ATOMS3 Liteで計測した温度・湿度・気圧データを、AWS IoT Core → Amazon Data Firehose → Snowpipe Streaming経由でSnowflakeへリアルタイムに届ける仕組みを、Terraformだけで構築しました。

Amazon Data FirehoseのSnowflakeネイティブ連携を使うことで、Lambdaや変換用のアプリケーションコードを書かずに、IoTデバイスのデータを数秒でSnowflakeのテーブルまで届けられることが確認できました。
