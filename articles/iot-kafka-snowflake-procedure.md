---
title: "Snowflake × IoT: Amazon MSK(Apache Kafka)を経由してセンサーデータをSnowflakeへ流し込む"
emoji: "❄️"
type: "tech" # tech: 技術記事 / idea: アイデア
topics:
  - aws
  - terraform
  - snowflake
  - kafka
  - iot
published: false
publication_name: "fusic"
---

## はじめに

以前の記事で、M5Stack + ENV3ユニットで計測した温度・湿度・気圧データを、AWS IoT Core → Kinesis Data Firehose → Snowpipe Streaming経由でSnowflakeへ蓄積する仕組みを構築しました。

https://zenn.dev/fusic/articles/stream-iot-data-to-snowflake

Amazon MSK(Managed Streaming for Apache Kafka)でもSnowflakeへデータを配信できます。
AWS IoT Coreが受け取ったメッセージをKafkaトピックへ転送し、そこからSnowflakeへ配信する構成です。

というわけで本記事では、AWS IoT Core → Amazon MSK → Snowflake を構築し、前回のFirehose版との違いを手を動かして確認します。
構築したTerraformコードはリポジトリの `terraform/kafka/` で公開しています。

https://github.com/yuuu/stream-iot-data-to-snowflake

## 全体構成

![構成図](/images/iot-kafka-snowflake-procedure/architecture.png)

| コンポーネント | 役割 |
| --- | --- |
| ATOMS3 Lite + ENV Ⅲ ユニット | 温度・湿度・気圧を計測してMQTTで送信します(前回記事と同じ) |
| AWS IoT Core | デバイスからのMQTT(TLS)を受信します |
| IoT Rule(Kafka Action) | 受信メッセージをVPC内のMSKトピックへ直接produceします |
| Amazon MSK(Provisioned) | Kafkaブローカー。トピック `env-sensor-telemetry` を保持します |
| MSK Connect + Snowflake Kafka Connector | KafkaトピックをコンシュームしてSnowpipe StreamingでSnowflakeへ書き込みます |
| Snowflake | データの格納先(`IOT_STREAM_KAFKA_DB.ENV_SENSOR_KAFKA.ENV_SENSOR_RAW`) |

前回との差分は「Firehose 1リソース」が「VPC + MSK + IoT VPC destination + NAT Gateway + MSK Connect + カスタムプラグイン + Snowflake用ロール/ユーザー」に置き換わる点です。
テーブルのスキーマ(`temperature` / `humidity` / `pressure` / `event_timestamp` / `device_id`)は前回と揃えています。

## 前提条件

- AWS CLIで認証できるプロファイルがあること
- Terraform、[AWS provider](https://registry.terraform.io/providers/hashicorp/aws/latest)、[Snowflake provider](https://registry.terraform.io/providers/snowflakedb/snowflake/latest)がインストールできる環境
- Snowflakeアカウントと、キーペア認証で接続できる管理用ユーザー(前回記事のセットアップを流用)
- [ATOMS3 Lite](https://www.switch-science.com/products/8778)と[ENV Ⅲ ユニット](https://docs.m5stack.com/ja/unit/envIII)(前回記事でセットアップ済みのものをそのまま使います)

## MSK(Kafka)を挟むメリット・デメリット

AWSとSnowflakeの接続点をKafkaとすることで次のようなメリットがあります。

| メリット | 内容 |
| --- | --- |
| ファンアウト | 1本のトピックを複数のコンシューマグループが独立して購読できる。「Snowflakeへの蓄積」と「ダッシュボード用のリアルタイム処理」を、片方の障害や再起動が他方に波及しない形で同居させられる |
| リプレイ | メッセージはリテンション期間ブローカーに残る。オフセットを巻き戻せば過去分を読み直せるので、取り込み先の追加やバグ修正後の再処理がしやすい |
| 順序保証 | メッセージキーで同じパーティションに寄せたイベントは、その中で順序が保たれる。今回は `device_id` をキーにして同一デバイスのイベント順序を守る |
| ストリーム処理エコシステム | Kafka Connect / Kafka Streams / Flink / 各種コンシューマライブラリなど、Kafka前提の資産をそのまま乗せられる。既存のKafka基盤があれば相乗りできる |

一方で、次のようなデメリットもあります。

| デメリット | 内容 |
| --- | --- |
| 運用コスト | ブローカーが立っているあいだ課金され続ける。最小構成(`kafka.t3.small` ×3 + NAT Gateway + MSK Connect)でも概算 $5/日。Firehoseの従量課金とは性格が違う |
| VPCが必要 | MSKはVPC内リソース。IoT Rule・MSK Connectの双方にVPC経由の接続と、サブネット / セキュリティグループ /(場合により)NAT Gatewayの設計が要る |
| 認証設計 | コンポーネントによって使える認証方式が違い、1方式に統一できない(後述) |

メリット・デメリットを考慮した上で、どちらの方式を採用するか検討すると良いでしょう。

## 構築

### Terraformプロジェクトの構成

前回のFirehose構成は `terraform/` 直下で完結していました。
今回はVPC・MSK・MSK Connectと規模が大きく、`terraform destroy` も局所化したいので、独立したルートモジュール `terraform/kafka/` にstateごと分離します。
前回の `terraform/` には手を入れません。

```
terraform/kafka/
├── versions.tf / providers.tf / variables.tf
├── vpc.tf            # 専用VPC(10.20.0.0/16)/ サブネット / ルートテーブル
├── msk.tf            # KMS / Secrets Manager(SASL/SCRAM)/ MSK Provisioned クラスタ
├── iot_kafka.tf      # IoT Rule(Kafka Action)+ VPC destination
├── nat.tf            # NAT Gateway + S3 Gatewayエンドポイント
├── snowflake_kafka.tf# Snowflake側の DB / schema / role / user / table
├── msk_connect.tf    # カスタムプラグイン + MSK Connect コネクタ
└── outputs.tf
```

Snowflake providerは2系(GA)を使い、キーペア認証(`SNOWFLAKE_JWT`)で接続します。
プロバイダ設定は前回記事と同じです。

### Amazon MSKを準備

#### VPCとネットワーク

MSK専用のVPC(`10.20.0.0/16`)を作り、3AZにプライベートサブネットを1つずつ、NAT Gateway用にパブリックサブネットを1つ用意します。
後述のIoT VPC destinationがENI経由でブローカーFQDNへ接続するため、VPCのDNS解決(`enable_dns_support` / `enable_dns_hostnames`)は有効にします。

```hcl:terraform/kafka/vpc.tf(抜粋)
resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr # 10.20.0.0/16
  enable_dns_support   = true # IoTルールエンジンのENIがブローカーFQDNを解決するために必須
  enable_dns_hostnames = true
}
# aws_subnet.private ×3(/20, AZ 1a/1c/1d)/ aws_subnet.public ×1
```

#### MSKクラスタと認証方式

`kafka.t3.small` を3AZに1台ずつ、通信はTLS、クライアント認証は SASL/SCRAM と IAM の両方 を有効にします。

```hcl:terraform/kafka/msk.tf(抜粋)
resource "aws_msk_cluster" "this" {
  cluster_name           = "${var.project_name}-kafka"
  kafka_version          = "3.8.x"
  number_of_broker_nodes = 3

  broker_node_group_info {
    instance_type = "kafka.t3.small"
    # client_subnets / security_groups / storage_info(EBS 10GB)は省略
  }

  # SASL/SCRAM と IAM を併用で有効化する
  client_authentication {
    sasl {
      scram = true
      iam   = true
    }
  }

  encryption_info {
    encryption_in_transit {
      client_broker = "TLS" # SASL/SCRAM は 9096/TLS 前提
    }
  }
}
```

認証を1方式に統一できないのは、コンポーネントによって使える方式が違うためです。

| コンポーネント | MSKへの接続 |
| --- | --- |
| IoT Rule(Kafka Action) | SASL_SSL / SCRAM-SHA-512(9096) |
| MSK Connect(Snowflake Sink) | IAM(9098) |

MSK Provisionedは両方式を同時に有効化できるので、クラスタ側で有効にして使い分けます。

#### SASL/SCRAMのシークレット

SASL/SCRAMの認証情報はSecrets Managerに置きます。
MSKのSASL/SCRAMシークレットには制約があります[^msk-scram-limits]。

- シークレット名は `AmazonMSK_` プレフィックス必須
- 顧客管理KMSキーでの暗号化が必須(デフォルトの `aws/secretsmanager` キーは使えない)
- `aws_msk_scram_secret_association` でクラスタへ関連付ける

[^msk-scram-limits]: [Limitations when using SCRAM secrets - Amazon Managed Streaming for Apache Kafka](https://docs.aws.amazon.com/msk/latest/developerguide/msk-password-limitations.html) に「The name of secrets associated with an Amazon MSK cluster must have the prefix AmazonMSK_.」「You must use an AWS KMS key with your Secret. You cannot use a Secret that uses the default Secrets Manager encryption key with Amazon MSK.」と明記されています。

```hcl:terraform/kafka/msk.tf(抜粋)
# random_password.scram で admin(トピック作成・確認用)/ iot-ingest(IoT Rule 用)を生成
resource "aws_secretsmanager_secret" "scram" {
  for_each                = toset(var.scram_users)
  name                    = "AmazonMSK_${var.project_name}_${each.key}"
  kms_key_id              = aws_kms_key.scram.arn
  recovery_window_in_days = 0 # 検証用途。destroy 後すぐ同名を再作成できるように
}

resource "aws_msk_scram_secret_association" "this" {
  cluster_arn     = aws_msk_cluster.this.arn
  secret_arn_list = [for u in var.scram_users : aws_secretsmanager_secret.scram[u].arn]
}
```

`recovery_window_in_days = 0` は、デフォルトの30日だと `terraform destroy` 後に同名シークレットを再作成できず `apply` し直せなくなるためです。

:::message
ここまでのリソースを `terraform apply` します。
MSKクラスタの作成には20〜40分かかります(実測で28分でした)。
:::

#### トピック設計

クラスタができたら、トピックを自動作成に頼らず明示的に作成します。
VPC内から到達できるKafkaクライアントで、SASL/SCRAM接続しています。

```
$ kafka-topics.sh --bootstrap-server "$BS" --command-config client.properties \
    --create --topic env-sensor-telemetry \
    --partitions 3 --replication-factor 3 --config min.insync.replicas=2
Created topic env-sensor-telemetry.
```

`client.properties` は SASL_SSL / SCRAM-SHA-512 の設定です。
TLS truststoreはJVMデフォルトでOK、MSKの証明書はAmazon Trust Servicesを利用します。　

```properties:client.properties
security.protocol=SASL_SSL
sasl.mechanism=SCRAM-SHA-512
sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username="admin" password="...";
```

### AWS IoT CoreからAmazon MSKへデータを転送

IoT Ruleの Kafka Action で、受信メッセージをMSKトピックへ直接produceします。
まず Topic Rule Destination(VPC destination) を作ります。
指定サブネットにIoTルールエンジンがENIを張り、ブローカーへ接続します。

```hcl:terraform/kafka/iot_kafka.tf(抜粋)
resource "aws_iot_topic_rule_destination" "kafka" {
  vpc_configuration {
    vpc_id          = aws_vpc.this.id
    subnet_ids      = aws_subnet.private[*].id
    security_groups = [aws_security_group.iot_kafka.id]
    role_arn        = aws_iam_role.iot_kafka_rule.arn
  }
}
```

ルールエンジンがassumeするIAMロールには、ENI管理系(`ec2:CreateNetworkInterface` ほか)と、`get_secret()` で使う `secretsmanager:GetSecretValue` / `DescribeSecret`、SCRAM用CMKの `kms:Decrypt` が必要です。

ルール本体のSQLは前回のFirehoseルールと同じです。

```hcl:terraform/kafka/iot_kafka.tf(抜粋)
resource "aws_iot_topic_rule" "env_sensor_to_kafka" {
  name        = "env_sensor_to_kafka"
  enabled     = true
  sql         = "SELECT *, timestamp() AS event_timestamp, topic(2) AS device_id FROM 'env-sensor/#'"
  sql_version = "2016-03-23"

  kafka {
    destination_arn = aws_iot_topic_rule_destination.kafka.arn
    topic           = "env-sensor-telemetry"

    # device_id をメッセージキーにして同一デバイスを同一パーティションへ固定する
    key = "$${topic(2)}"

    client_properties = {
      "bootstrap.servers"   = aws_msk_cluster.this.bootstrap_brokers_sasl_scram
      "security.protocol"   = "SASL_SSL"
      "sasl.mechanism"      = "SCRAM-SHA-512"
      "sasl.scram.username" = "$${get_secret('<iot-ingest secret ARN>', 'SecretString', 'username', '<role ARN>')}"
      "sasl.scram.password" = "$${get_secret('<iot-ingest secret ARN>', 'SecretString', 'password', '<role ARN>')}"
      "key.serializer"      = "org.apache.kafka.common.serialization.StringSerializer"
      "value.serializer"    = "org.apache.kafka.common.serialization.ByteBufferSerializer"
      "acks"                = "1"
    }
  }

  # error_action で cloudwatch_logs をルール実行エラーの受け皿にする
}
```

:::message
AWS IoT SQLの `topic(n)` は1始まりです。
トピック `env-sensor/ABCD1234` なら `topic(1)` が `"env-sensor"`、`topic(2)` が `"ABCD1234"` となります。

また、`key.serializer` における `StringSerializer`、`value.serializer` は `ByteBufferSerializer` のみ対応です。
:::

:::message
ここまでの内容を `terraform apply` すると、VPC destinationが `ENABLED` になるまで数分かかります
実測で約3分。ENIを各サブネットに作成しています。
:::

### MSK Connect + Snowflake Connectorの準備

KafkaトピックからSnowflakeへの取り込みは MSK Connect + [Snowflake Kafka Connector](https://docs.snowflake.com/ja/user-guide/kafka-connector) を使います。
コネクタは内部でSnowpipe Streaming APIを叩くので、前回のSnowpipe Streaming経路にKafkaを1段足した形です。

#### NAT Gateway

MSK ConnectはSnowflake(443)へアウトバウンド接続します。
プライベートサブネットにデフォルトルートがないので、単一AZのNAT Gatewayを1台だけ足します。
S3はGatewayエンドポイント(無料)で通し、NATを経由させません。

```hcl:terraform/kafka/nat.tf(抜粋)
resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public.id
}

resource "aws_route" "private_default" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this.id
}
# aws_vpc_endpoint.s3(Gateway 型)で S3 は NAT を経由させない
```

#### Snowflake側のオブジェクト

前回の `snowflake.tf` と同じ作り方で、この構成専用の DB / schema / role / キーペア認証ユーザー / テーブルを作ります。
前回の `IOT_STREAM_IOT_DB` とは別DBです。

テーブルはPreview機能の `snowflake_table` を避け、Stableな `snowflake_execute` で作ります。
カラムは前回と同じ型付き5列に、Snowflake Kafka Connectorが付けるメタデータ列 `RECORD_METADATA` を足したものです。

```hcl:terraform/kafka/snowflake_kafka.tf(抜粋)
resource "snowflake_execute" "env_sensor_raw_table" {
  execute = "CREATE TABLE IF NOT EXISTS ${local.sf_kafka_table_fqn} (RECORD_METADATA VARIANT, TEMPERATURE FLOAT, HUMIDITY FLOAT, PRESSURE FLOAT, EVENT_TIMESTAMP NUMBER, DEVICE_ID VARCHAR)"
  revert  = "DROP TABLE IF EXISTS ${local.sf_kafka_table_fqn}"
}
```

#### カスタムプラグイン

Snowflake Kafka Connectorのfat jar(暗号化なしの秘密鍵なら追加依存は不要)をMaven Centralから取得し、S3経由でMSK Connectのカスタムプラグインとして登録します。
jarのダウンロードはTerraformの `terraform_data` + `local-exec` で行います。
初回 `apply` で約185MBを取得するので、オフライン環境では事前に `terraform/kafka/build/` へ置いてください。

```hcl:terraform/kafka/msk_connect.tf(抜粋)
resource "terraform_data" "download_connector" {
  triggers_replace = [var.snowflake_kafka_connector_version] # 3.2.2

  provisioner "local-exec" {
    command = <<-EOT
      f='${path.module}/build/snowflake-kafka-connector-${var.snowflake_kafka_connector_version}.jar'
      [ -s "$f" ] || curl -fsSL -o "$f" \
        'https://repo1.maven.org/maven2/com/snowflake/snowflake-kafka-connector/${var.snowflake_kafka_connector_version}/snowflake-kafka-connector-${var.snowflake_kafka_connector_version}.jar'
    EOT
  }
}
```

#### コネクタ

コネクタ実行ロールにはIAM認証用に `kafka-cluster:Connect` / `ReadData` / `DescribeGroup` などをクラスタ・トピック・グループARNへ付与します。
コネクタ設定のポイントは以下です。

- `snowflake.ingestion.method = SNOWPIPE_STREAMING`
- `snowflake.streaming.max.client.lag = 1`(できるだけ速くフラッシュ)
- `snowflake.enable.schematization = true`(受信JSONのキーを型付きカラムへマッピング。テーブルは作成済みなので既存カラムにINSERTするだけ)
- `value.converter = JsonConverter`(`schemas.enable = false`)/ `key.converter = StringConverter`

```hcl:terraform/kafka/msk_connect.tf(抜粋)
resource "aws_mskconnect_connector" "snowflake" {
  name                 = "snowflake-env-sensor-sink"
  kafkaconnect_version = "2.7.1"
  # capacity: provisioned(mcu_count = 1 / worker_count = 1)

  connector_configuration = {
    "connector.class" = "com.snowflake.kafka.connector.SnowflakeSinkConnector"
    "topics"          = "env-sensor-telemetry"
    # snowflake.url.name / user.name / role.name / private.key / database.name / schema.name は省略

    "snowflake.ingestion.method"         = "SNOWPIPE_STREAMING"
    "snowflake.enable.schematization"    = "true"
    "snowflake.streaming.max.client.lag" = "1"
    "snowflake.topic2table.map"          = "env-sensor-telemetry:ENV_SENSOR_RAW"

    "key.converter"                  = "org.apache.kafka.connect.storage.StringConverter"
    "value.converter"                = "org.apache.kafka.connect.json.JsonConverter"
    "value.converter.schemas.enable" = "false"
  }

  kafka_cluster {
    apache_kafka_cluster {
      bootstrap_servers = aws_msk_cluster.this.bootstrap_brokers_sasl_iam # 9098
      # vpc: security_groups / subnets(private)
    }
  }

  kafka_cluster_client_authentication {
    authentication_type = "IAM"
  }
}
```

:::message
`terraform apply` するとコネクタ作成に5〜15分かかります(実測で約4分)。
:::

作成後 `describe-connector` で `RUNNING` になり、CloudWatch Logsに `Successfully called PRECOMMIT on all 3 partitions` などが出てくれば取り込みが動いています。

`schematization = false` だとJSONを分解せず `RECORD_METADATA` + `RECORD_CONTENT`(VARIANT)で格納されます。
前回同様の型付きカラムにしたいので `true` にし、テーブルを先に作ってあるためスキーマ進化の `ALTER` も走りません。

## 動作確認

### テストデータを送信してみる

実機の前に、まずは `aws iot-data publish` でテストメッセージを流します。

```bash
aws iot-data publish \
  --endpoint-url https://<IoTエンドポイント> \
  --topic "env-sensor/TESTKAFKA001" \
  --payload '{"temperature": 24.7, "humidity": 51.2, "pressure": 1008.1}' \
  --cli-binary-format raw-in-base64-out
```

IoT Rule側のメトリクスを見ます。
`AWS/IoT` の `Success`(`ActionType=Kafka`)がpublish数と一致し、`Failure` は0、エラーログも空でした。

数秒待つとSnowflakeに届きます。
Snowflake Kafka Connectorが付ける `RECORD_METADATA`(VARIANT)にKafkaトピック・パーティション・オフセット・キーが入るので、Kafka側を覗かなくてもパーティションとオフセットまで確認できます。

```sql
SELECT device_id,
       RECORD_METADATA:partition::int AS partition,
       RECORD_METADATA:offset::int    AS offset,
       RECORD_METADATA:key::string    AS msg_key,
       temperature, event_timestamp
FROM IOT_STREAM_KAFKA_DB.ENV_SENSOR_KAFKA.ENV_SENSOR_RAW
WHERE device_id IN ('TESTKAFKA001', 'AAAKAFKA002')
ORDER BY partition, offset;
```

```
DEVICE_ID     PARTITION  OFFSET  MSG_KEY       TEMPERATURE  EVENT_TIMESTAMP
AAAKAFKA002   0          0       AAAKAFKA002   30.9         1788040551179
TESTKAFKA001  1          4       TESTKAFKA001  24.7         1788040547069
TESTKAFKA001  1          5       TESTKAFKA001  24.9         1788040555321
```

- メッセージキー(`RECORD_METADATA:key` = `${topic(2)}` = `device_id`)が効いていて、`TESTKAFKA001` の2件はどちらもパーティション1(offset 4 → 5、publish順)、`AAAKAFKA002` は別のパーティションに入っています。
- ルールSQLの `event_timestamp` / `device_id` が型付きカラムに入っています。

### センサーデータを転送してみる

実機(ATOMS3 Lite、チップID `607856DB5110`)は前回記事のセットアップのまま、`env-sensor/607856DB5110` へ約60秒間隔でpublishし続けています。
デバイス側のコードもトピックも前回と同じで、IoT Ruleを1本足しただけで実データがKafkaへ流れ始めました(既存のFirehoseルールも併存しているので、同じpublishがFirehose→Snowflakeにも配信され続けます)。

直近レコードをSnowflakeで確認すると、計測値が型付きカラムに入っています。

| EVENT_TIMESTAMP | TEMPERATURE | HUMIDITY | PRESSURE |
| --- | --- | --- | --- |
| 1788074604034 | 31.19249 | 70.04395 | 1007.363 |
| 1788074661928 | 31.17914 | 70.07294 | 1007.355 |
| 1788074721932 | 31.19249 | 70.10498 | 1007.374 |

#### レイテンシ(前回のFirehose版との比較)

MSK Connect + Snowflake Kafka Connector(`SNOWPIPE_STREAMING` / `max.client.lag=1`)で、`aws iot-data publish` してからSnowflakeでクエリできるようになるまでを実測しました(2秒間隔ポーリング、5回)。
前回のFirehose版は `DeliveryToSnowflake.DataFreshness` が 8秒です。

| 計測 | publish → クエリ可能(e2e) | event_timestamp → クエリ可能 |
| --- | --- | --- |
| 1回目(コネクタがアイドル明け) | 12.4 s | 4.6 s |
| 2回目 | 5.7 s | 3.5 s |
| 3回目 | 5.5 s | 3.4 s |
| 4回目 | 5.6 s | 3.6 s |
| 5回目 | 5.4 s | 3.3 s |
| 参考: Firehose版(`DataFreshness`) | 約8 s | — |

Kafkaを1段挟んでも、ウォーム時(event_timestamp基準で3〜4秒台)はFirehose版と同等〜やや速い結果でした。
ただしアイドル明けの初回はSDK初期化・チャネルopenで十数秒のスパイクが出るほか、クエリ側ウェアハウスの `RESUME` 待ちも混ざるので、計測前に起こしておきます。

#### 順序保証

順序保証も `RECORD_METADATA` のパーティション・オフセットで確認します。

```sql
SELECT RECORD_METADATA:partition::int AS partition,
       RECORD_METADATA:offset::int    AS offset,
       device_id, event_timestamp
FROM IOT_STREAM_KAFKA_DB.ENV_SENSOR_KAFKA.ENV_SENSOR_RAW
WHERE device_id = '607856DB5110'
ORDER BY offset;
```

```
PARTITION  OFFSET  DEVICE_ID     EVENT_TIMESTAMP
1          542     607856DB5110  1788074541908
1          543     607856DB5110  1788074604034
1          544     607856DB5110  1788074661928
1          545     607856DB5110  1788074721932
1          547     607856DB5110  1788074781939
```

- 実機 `607856DB5110` のレコードは常に同じパーティション(ここでは1)に入り、オフセット昇順 = `event_timestamp` 昇順 = produce順に並んでいます。
- 別の `device_id` はmurmur2ハッシュで別のパーティションへ分散します(先ほどのテストデータでは `AAAKAFKA002` がパーティション0でした)。

`device_id` をメッセージキーにしたことで、「同一デバイスのイベント順序」がKafka内でもSnowflake内でも保たれます。

## おわりに

ATOMS3 Liteで計測したデータを、AWS IoT Core → Amazon MSK → Snowflake の経路でTerraformだけで構築し、前回のFirehose版と比較しました。

| 観点 | 結果 |
| --- | --- |
| レイテンシ | ウォーム時でむしろやや速い〜同等(event_timestamp基準で3〜4秒台)。ただしコネクタのアイドル明け初回に十数秒のスパイクが出る |
| 順序保証 | `device_id` をメッセージキーにすることで、Kafka・Snowflakeの両方で担保できた |
| ファンアウト | 同じトピックを別のコンシューマグループから購読すれば、Snowflakeへの蓄積とは独立した処理(リアルタイム集計など)を足せる |

一方で、Kafka版はVPC・MSK・NAT・MSK Connect・認証設計と構成要素が増えます。
認証方式もIoT RuleはSASL/SCRAM、MSK ConnectはIAMと分かれ、クラスタ側で両方を有効化しました。
運用コストも常時発生します。

使い分けの目安は次のとおりです。

- シンプルにSnowflakeへ蓄積したい → Firehoseネイティブ連携(前回記事)
- 1本のIoTストリームを蓄積・リアルタイム処理・再処理など複数用途で使いたい / 既にKafka基盤がある → 今回のMSK構成

構築したTerraformコードは以下で公開しています。

https://github.com/yuuu/stream-iot-data-to-snowflake
