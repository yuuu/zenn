---
title: "PostgreSQL → Debezium → Kafka → Snowflake でCDCパイプラインを構築する手順(構築編)"
emoji: "❄️"
type: "tech" # tech: 技術記事 / idea: アイデア
topics:
  - aws
  - postgresql
  - debezium
  - kafka
  - snowflake
published: false
publication_name: "fusic"
---

## はじめに

以前の記事で、AWS IoT Core → Amazon MSK → Snowflake の経路をTerraformで構築しました。

https://zenn.dev/fusic/articles/iot-kafka-snowflake-procedure

MSK + Snowflake Kafka Connectorという組み合わせ自体は確立できたので、今回はソース側を変えて「PostgreSQL(RDS)の変更をリアルタイムにSnowflakeへ反映する」CDC(Change Data Capture)構成を検証します。
Debezium経由でKafkaへ転送している事例をよく見かけるので、同じ構成を手を動かして構築してみます。

- ソース: RDS for PostgreSQL
- CDC抽出: Debezium PostgreSQL Connector(Kafka Connectのソースコネクタ)
- ブローカー: Amazon MSK
- シンク: Snowflake Kafka Connector(Snowpipe Streaming)

本記事は実際に手を動かす前の**構築手順の整理**です。現時点でのAWS/Snowflakeの状態は次のとおりで、ここからのセットアップになります。

- AWS: アカウントは存在するが、VPC・RDSともに未構築
- Snowflake: CLI(`snow`)は接続済みだが、今回用のDB・ウェアハウスは未作成

実際に構築した後の実行結果・詰まった点は、別記事(実践編)としてまとめる予定です。

## 全体構成

| コンポーネント | 役割 |
| --- | --- |
| RDS for PostgreSQL | データソース。論理レプリケーション(`pgoutput`)を有効化してWALを公開します |
| Debezium PostgreSQL Connector | MSK Connect上で動くソースコネクタ。レプリケーションスロット経由でWALを読み、テーブルごとのKafkaトピックへCDCイベントをproduceします |
| Amazon MSK | Kafkaブローカー。テーブルごとのトピック(`pgdb.public.orders`など)を保持します |
| Snowflake Kafka Connector | MSK Connect上で動くシンクコネクタ。Snowpipe StreamingでCDCイベントをSnowflakeの生テーブルへ書き込みます |
| Snowflake | 生イベントを`RECORD_CONTENT`(VARIANT)に蓄積し、Stream + MERGEで「現在値」テーブルへ反映します |

データの流れは次のとおりです。

```
RDS(PostgreSQL, WAL)
  → [論理レプリケーションスロット]
  → Debezium PostgreSQL Connector(MSK Connect / source)
  → Amazon MSK(トピック: pgdb.public.<table>)
  → Snowflake Kafka Connector(MSK Connect / sink, Snowpipe Streaming)
  → Snowflake 生テーブル(RECORD_METADATA / RECORD_CONTENT VARIANT)
  → Stream + MERGE
  → Snowflake 現在値テーブル
```

Kafkaを挟む構成そのものは前回記事と同じ考え方です。今回はソースがIoT CoreではなくDebezium(Kafka Connectのソースコネクタ)になる点、CDCイベント特有の`before`/`after`/`op`を含むエンベロープをどう扱うかがポイントです。

## 前提条件

- AWS CLIで認証できるプロファイルがあること(VPC/RDS/MSK/MSK Connect/Secrets Managerを作成できる権限)
- Snowflake CLI(`snow`)が接続済みであること(今回はDB/ウェアハウス作成権限を持つロールで接続)
- `psql`が使えるクライアント環境(踏み台EC2経由で接続します)
- Kafka Connect用カスタムプラグインを作るため、`curl` / `unzip` / `zip`が使える環境

以降、変数は次の想定で記載します。適宜読み替えてください。

| 変数 | 値(例) |
| --- | --- |
| リージョン | `ap-northeast-1` |
| VPC CIDR | `10.40.0.0/16` |
| プロジェクト名 | `pg-cdc` |
| RDSインスタンス識別子 | `pg-cdc-source` |
| MSKクラスタ名 | `pg-cdc-kafka` |
| Snowflakeデータベース | `PG_CDC_DB` |

## STEP1: VPCとネットワークを構築する

MSKと同様、RDSもVPC内リソースです。3AZにプライベートサブネット、NAT Gateway用にパブリックサブネットを1つ用意します。

```hcl:vpc.tf(抜粋)
resource "aws_vpc" "this" {
  cidr_block           = "10.40.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
}

# aws_subnet.private ×3 (RDS / MSK / MSK Connect 共用, /20, 1a/1c/1d)
# aws_subnet.public  ×1 (NAT Gateway 用)
```

セキュリティグループは役割ごとに分けます。

| SG | 用途 | 主なインバウンド |
| --- | --- | --- |
| `rds-sg` | RDS用 | `mskconnect-sg`と`bastion-sg`から5432 |
| `msk-sg` | MSKブローカー用 | `mskconnect-sg`から9096(SASL/SCRAM)・9098(IAM) |
| `mskconnect-sg` | MSK Connect用 | 送信のみ(RDS:5432, MSK:9096/9098, Snowflake:443) |
| `bastion-sg` | 踏み台EC2用 | 自分のグローバルIPから22 |

:::message
Snowflake Kafka ConnectorはSnowflakeエンドポイントへ443でアウトバウンド接続するため、前回記事と同様にNAT Gatewayが必要です。S3はGatewayエンドポイントで通してNATを経由させません。
:::

## STEP2: RDS for PostgreSQLを構築する

### パラメータグループで論理レプリケーションを有効化

`rds.logical_replication`はRDS独自のstaticパラメータで、変更するとインスタンスの再起動が必要です[^rds-logical-replication]。デフォルトのパラメータグループは変更できないため、カスタムパラメータグループを作成します。

```bash
aws rds create-db-parameter-group \
  --db-parameter-group-name pg-cdc-pg16 \
  --db-parameter-group-family postgres16 \
  --description "logical replication enabled for Debezium"

aws rds modify-db-parameter-group \
  --db-parameter-group-name pg-cdc-pg16 \
  --parameters "ParameterName=rds.logical_replication,ParameterValue=1,ApplyMethod=pending-reboot"
```

[^rds-logical-replication]: [Using logical replication with PostgreSQL on Amazon RDS](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/PostgreSQL.Concepts.General.FeatureSupport.LogicalReplication.html) に、`rds.logical_replication`パラメータを`1`にすると`wal_level`が自動的に`logical`になり、`max_wal_senders` / `max_replication_slots` / `max_connections`も引き上げられる旨の記載があります。

### インスタンス作成

```bash
aws rds create-db-subnet-group \
  --db-subnet-group-name pg-cdc-subnet-group \
  --subnet-ids subnet-aaa subnet-bbb subnet-ccc

aws rds create-db-instance \
  --db-instance-identifier pg-cdc-source \
  --engine postgres \
  --engine-version 16.4 \
  --db-instance-class db.t4g.micro \
  --allocated-storage 20 \
  --storage-type gp3 \
  --db-name appdb \
  --master-username postgres \
  --manage-master-user-password \
  --vpc-security-group-ids sg-rds \
  --db-subnet-group-name pg-cdc-subnet-group \
  --db-parameter-group-name pg-cdc-pg16 \
  --no-publicly-accessible \
  --no-multi-az
```

`--manage-master-user-password`でマスターパスワードをSecrets Manager管理にしています。
パラメータグループ変更を反映するため、作成後に一度再起動します。

```bash
aws rds reboot-db-instance --db-instance-identifier pg-cdc-source
```

### 論理レプリケーション用ユーザーとPublicationを作成

踏み台EC2からポートフォワード、またはVPC内から`psql`で接続します(踏み台の立て方は前回のKarafka記事と同じ要領です)。

```sql
-- Debezium専用ユーザー
CREATE USER debezium WITH REPLICATION PASSWORD '...';
GRANT rds_replication TO debezium;

-- 対象テーブルへのSELECT権限(スナップショット取得に必要)
GRANT SELECT ON public.orders TO debezium;

-- Publicationを明示的に作成(自動作成に頼らずスコープを絞る)
CREATE PUBLICATION dbz_publication FOR TABLE public.orders;
```

:::message
RDSでは`rds_superuser`が実際のsuperuserではないため、`ALTER USER debezium WITH REPLICATION`ではなく`GRANT rds_replication TO debezium`を使います。
:::

## STEP3: Amazon MSKを構築する

前回記事と同じ構成(`kafka.t3.small` ×3、SASL/SCRAM + IAM併用、TLS)を流用します。認証方式の使い分けは以下のとおりです。

| コンポーネント | MSKへの接続 |
| --- | --- |
| Debezium Connector(MSK Connect) | IAM(9098) |
| Snowflake Sink Connector(MSK Connect) | IAM(9098) |
| 動作確認用の`kafka-console-consumer`(踏み台) | SASL/SCRAM(9096) |

```hcl:msk.tf(抜粋)
resource "aws_msk_cluster" "this" {
  cluster_name           = "pg-cdc-kafka"
  kafka_version          = "3.8.x"
  number_of_broker_nodes = 3

  broker_node_group_info {
    instance_type = "kafka.t3.small"
  }

  client_authentication {
    sasl {
      scram = true
      iam   = true
    }
  }

  encryption_info {
    encryption_in_transit {
      client_broker = "TLS"
    }
  }
}
```

SASL/SCRAMシークレットの命名規則(`AmazonMSK_`プレフィックス必須、顧客管理KMSキー必須)は前回記事の注意点と同じです。

## STEP4: MSK Connect用カスタムプラグインを準備する

コネクタは2つ用意するので、プラグインも2つ用意します。

### Debezium PostgreSQL Connectorプラグイン

Maven CentralからDebezium公式のプラグインアーカイブを取得します[^debezium-plugin]。MSK Connectのカスタムプラグインは**ZIP形式**が必須ですが、Debeziumの配布物は`tar.gz`なので展開して再圧縮します。

```bash
DEBEZIUM_VERSION=3.0.8  # https://debezium.io/releases/ で最新の安定版を確認

curl -fsSL -o debezium-connector-postgres.tar.gz \
  "https://repo1.maven.org/maven2/io/debezium/debezium-connector-postgres/${DEBEZIUM_VERSION}/debezium-connector-postgres-${DEBEZIUM_VERSION}-plugin.tar.gz"

mkdir -p plugin/debezium-connector-postgres
tar xzf debezium-connector-postgres.tar.gz -C plugin/debezium-connector-postgres --strip-components=1
cd plugin && zip -r ../debezium-connector-postgres.zip debezium-connector-postgres && cd ..

aws s3 cp debezium-connector-postgres.zip s3://pg-cdc-connect-plugins/

aws kafkaconnect create-custom-plugin \
  --name debezium-postgres-connector \
  --content-type ZIP \
  --location s3Location='{bucketArn="arn:aws:s3:::pg-cdc-connect-plugins",fileKey="debezium-connector-postgres.zip"}'
```

[^debezium-plugin]: [Deploy Debezium on Kafka Connect Cluster on AWS - Debezium Documentation](https://debezium.io/documentation/reference/stable/operations/debezium-on-kubernetes.html) 系のガイドでも、AWS上のKafka Connectへは公式プラグインアーカイブをそのまま/再パッケージして配置する方式が案内されています。MSK Connectのカスタムプラグインの制約(ZIP必須)は[Amazon MSK Connect - Custom plugins](https://docs.aws.amazon.com/msk/latest/developerguide/msk-connect-plugins.html)を参照してください。

### Snowflake Kafka Connectorプラグイン

前回記事と同じ手順(Maven Centralからfat jarを取得しS3経由で登録)です。

```bash
SNOWFLAKE_CONNECTOR_VERSION=3.2.2

curl -fsSL -o snowflake-kafka-connector.jar \
  "https://repo1.maven.org/maven2/com/snowflake/snowflake-kafka-connector/${SNOWFLAKE_CONNECTOR_VERSION}/snowflake-kafka-connector-${SNOWFLAKE_CONNECTOR_VERSION}.jar"

mkdir -p plugin/snowflake-kafka-connector
cp snowflake-kafka-connector.jar plugin/snowflake-kafka-connector/
cd plugin && zip -r ../snowflake-kafka-connector.zip snowflake-kafka-connector && cd ..

aws s3 cp snowflake-kafka-connector.zip s3://pg-cdc-connect-plugins/
```

## STEP5: Debezium PostgreSQL Source Connectorを起動する

MSK Connectの実行ロールには、Kafkaクラスタへの`kafka-cluster:Connect` / `*Topic*` / `*Group*`権限、ENI管理権限、RDS接続情報を格納したSecrets Managerへの`GetSecretValue`権限が必要です。

コネクタ設定のポイントは以下です。

- `plugin.name=pgoutput`(RDSはネイティブの`pgoutput`が使え、追加の拡張インストールが不要)
- `topic.prefix`でトピック名の接頭辞(サーバー論理名)を決める
- `table.include.list`でキャプチャ対象を明示的に絞る
- `snapshot.mode=initial`で初回起動時に既存データを一括取り込みしてからWAL追跡に切り替える
- SMTは使わず、`before` / `after` / `op` を含むDebeziumのエンベロープをそのままJSONで流す(後述のSnowflake側でVARIANTとして受け止め、SQLで加工する方針のため)

```json:debezium-postgres-connector.json
{
  "connector.class": "io.debezium.connector.postgresql.PostgresConnector",
  "tasks.max": "1",
  "database.hostname": "pg-cdc-source.xxxx.ap-northeast-1.rds.amazonaws.com",
  "database.port": "5432",
  "database.user": "debezium",
  "database.password": "${secretsManager:pg-cdc/debezium-user:password}",
  "database.dbname": "appdb",
  "topic.prefix": "pgdb",
  "table.include.list": "public.orders",
  "plugin.name": "pgoutput",
  "publication.name": "dbz_publication",
  "publication.autocreate.mode": "disabled",
  "slot.name": "dbz_pgdb_slot",
  "snapshot.mode": "initial",
  "key.converter": "org.apache.kafka.connect.json.JsonConverter",
  "key.converter.schemas.enable": "false",
  "value.converter": "org.apache.kafka.connect.json.JsonConverter",
  "value.converter.schemas.enable": "true",
  "heartbeat.interval.ms": "10000"
}
```

MSK Connectの`${secretsManager:...}`構文でSecrets Manager連携ができるので、DBパスワードを平文で書かずに済みます[^msk-connect-secrets]。

[^msk-connect-secrets]: [Externalize secrets for MSK Connect connector configuration](https://docs.aws.amazon.com/msk/latest/developerguide/mkc-externalize-secrets.html)

`heartbeat.interval.ms`を設定しているのは、対象テーブルの更新頻度が低い場合でもレプリケーションスロットのLSNを定期的に前進させ、WALの滞留を防ぐためです[^debezium-heartbeat]。

[^debezium-heartbeat]: [Debezium connector for PostgreSQL - Heartbeat messages](https://debezium.io/documentation/reference/stable/connectors/postgresql.html#postgresql-heartbeat-messages) に、低頻度更新テーブルではハートビートなしだとLSNが進まずWALが溜まり続けるリスクが明記されています。

```bash
aws kafkaconnect create-connector \
  --connector-name debezium-postgres-source \
  --kafkaconnect-version 2.7.1 \
  --connector-configuration file://debezium-postgres-connector.json \
  --plugins customPlugin='{customPluginArn=<debezium plugin ARN>,revision=1}' \
  --capacity provisionedCapacity='{mcuCount=1,workerCount=1}' \
  --kafka-cluster '{apacheKafkaCluster={bootstrapServers=<IAM bootstrap>,vpc={subnets=[...],securityGroups=[sg-mskconnect]}}}' \
  --kafka-cluster-client-authentication authenticationType=IAM \
  --kafka-cluster-encryption-in-transit encryptionType=TLS \
  --service-execution-role-arn <role ARN>
```

作成後、`describe-connector`で`RUNNING`になることと、CloudWatch Logsにスナップショット完了ログ(`Snapshot ended with SnapshotResult`など)が出ることを確認します。

## STEP6: Snowflake側の受け皿を準備する

`snow` CLIは接続済みですが、今回用のDB/ウェアハウス/ロール/ユーザーはまだ存在しないため作成します。

```bash
snow sql -q "
CREATE WAREHOUSE IF NOT EXISTS PG_CDC_WH WITH WAREHOUSE_SIZE='XSMALL' AUTO_SUSPEND=60 AUTO_RESUME=TRUE;
CREATE DATABASE IF NOT EXISTS PG_CDC_DB;
CREATE SCHEMA IF NOT EXISTS PG_CDC_DB.RAW;
CREATE SCHEMA IF NOT EXISTS PG_CDC_DB.CURATED;
"
```

Snowflake Kafka ConnectorはOAuthではなく**キーペア認証**が必須なので、コネクタ専用のサービスユーザーを別途作成します(`snow` CLI接続用のユーザーとは分けます)。

```bash
openssl genrsa 2048 | openssl pkcs8 -topk8 -inform PEM -out kafka_connector_key.p8 -nocrypt
openssl rsa -in kafka_connector_key.p8 -pubout -out kafka_connector_key.pub

PUBKEY=$(grep -v "PUBLIC KEY" kafka_connector_key.pub | tr -d '\n')

snow sql -q "
CREATE ROLE IF NOT EXISTS PG_CDC_KAFKA_ROLE;
CREATE USER IF NOT EXISTS PG_CDC_KAFKA_USER
  RSA_PUBLIC_KEY='${PUBKEY}'
  DEFAULT_ROLE=PG_CDC_KAFKA_ROLE
  DEFAULT_WAREHOUSE=PG_CDC_WH;
GRANT ROLE PG_CDC_KAFKA_ROLE TO USER PG_CDC_KAFKA_USER;
GRANT USAGE ON WAREHOUSE PG_CDC_WH TO ROLE PG_CDC_KAFKA_ROLE;
GRANT USAGE ON DATABASE PG_CDC_DB TO ROLE PG_CDC_KAFKA_ROLE;
GRANT ALL ON SCHEMA PG_CDC_DB.RAW TO ROLE PG_CDC_KAFKA_ROLE;
"
```

生テーブルは、DebeziumエンベロープをそのままVARIANTで受け止める設計にします(スキーマ変換=`false`)。CDCでは`before`/`after`/`op`をそのまま持つ方が下流のMERGE処理で扱いやすいためです。

```sql
CREATE TABLE IF NOT EXISTS PG_CDC_DB.RAW.ORDERS_CDC_RAW (
  RECORD_METADATA VARIANT,
  RECORD_CONTENT  VARIANT
);
```

## STEP7: Snowflake Sink Connectorを起動する

```json:snowflake-sink-connector.json
{
  "connector.class": "com.snowflake.kafka.connector.SnowflakeSinkConnector",
  "tasks.max": "1",
  "topics": "pgdb.public.orders",
  "snowflake.topic2table.map": "pgdb.public.orders:ORDERS_CDC_RAW",
  "snowflake.url.name": "https://<account>.snowflakecomputing.com",
  "snowflake.user.name": "PG_CDC_KAFKA_USER",
  "snowflake.private.key": "${secretsManager:pg-cdc/snowflake-kafka-user:private_key}",
  "snowflake.role.name": "PG_CDC_KAFKA_ROLE",
  "snowflake.database.name": "PG_CDC_DB",
  "snowflake.schema.name": "RAW",
  "snowflake.ingestion.method": "SNOWPIPE_STREAMING",
  "snowflake.enable.schematization": "false",
  "snowflake.streaming.max.client.lag": "1",
  "key.converter": "org.apache.kafka.connect.storage.StringConverter",
  "value.converter": "org.apache.kafka.connect.json.JsonConverter",
  "value.converter.schemas.enable": "true"
}
```

`value.converter.schemas.enable=true`にしているのは、Debezium側で`schemas.enable=true`にしているためです(JSONのペイロードが`{"schema": ..., "payload": {...}}`の形になり、両者のConverter設定を揃える必要があります)。`snowflake.enable.schematization`は`false`のままにして、テーブル定義済みの`RECORD_METADATA` / `RECORD_CONTENT`にそのまま書き込みます。

コネクタ作成はDebezium側と同じ`create-connector`コマンドで、プラグインとコネクタクラスを差し替えるだけです。

## STEP8: 動作確認

### スナップショットの確認

コネクタ起動直後、既存の`orders`テーブルの全行が`snapshot.mode=initial`によって一括で流れます。`RECORD_CONTENT:payload:op`が`r`(read = スナップショット)のレコードとしてSnowflakeに入っていることを確認します。

```sql
SELECT RECORD_CONTENT:payload:op::string AS op, COUNT(*)
FROM PG_CDC_DB.RAW.ORDERS_CDC_RAW
GROUP BY op;
```

### INSERT/UPDATE/DELETEの反映確認

RDSへ`psql`で接続し、変更を加えます。

```sql
INSERT INTO orders (id, status, amount) VALUES (1001, 'created', 1200);
UPDATE orders SET status = 'shipped' WHERE id = 1001;
DELETE FROM orders WHERE id = 1001;
```

数秒後、Snowflake側で`op`が`c`(create) → `u`(update) → `d`(delete)の順に届くことを確認します。

```sql
SELECT
  RECORD_CONTENT:payload:op::string        AS op,
  RECORD_CONTENT:payload:before:id::int    AS before_id,
  RECORD_CONTENT:payload:after:id::int     AS after_id,
  RECORD_CONTENT:payload:after:status::string AS after_status,
  RECORD_CONTENT:payload:ts_ms::number     AS ts_ms
FROM PG_CDC_DB.RAW.ORDERS_CDC_RAW
WHERE COALESCE(RECORD_CONTENT:payload:after:id, RECORD_CONTENT:payload:before:id) = 1001
ORDER BY ts_ms;
```

- `c`/`u`は`after`にレコードが入り、`before`は`u`のときのみ更新前の値が入ります(RDSのデフォルト`REPLICA IDENTITY DEFAULT`では`before`は主キーのみ、全カラムの前イメージが必要なら対象テーブルに`ALTER TABLE orders REPLICA IDENTITY FULL;`が必要です[^replica-identity])。
- `d`は`before`にのみ削除前の値が入り、`after`は`null`になります。

[^replica-identity]: [Debezium connector for PostgreSQL - REPLICA IDENTITY](https://debezium.io/documentation/reference/stable/connectors/postgresql.html#postgresql-replica-identity) に、`REPLICA IDENTITY`の設定によって`UPDATE`/`DELETE`イベントの`before`に含まれる情報量が変わる旨の記載があります。

## STEP9: 「現在値」テーブルへ反映する

CDCイベントの生ログをそのまま使うと分析しづらいので、Stream + MERGEで最新状態のテーブルへ反映します。

```sql
CREATE TABLE IF NOT EXISTS PG_CDC_DB.CURATED.ORDERS (
  ID INT PRIMARY KEY,
  STATUS STRING,
  AMOUNT NUMBER,
  UPDATED_AT_MS NUMBER
);

CREATE STREAM IF NOT EXISTS PG_CDC_DB.RAW.ORDERS_CDC_STREAM
  ON TABLE PG_CDC_DB.RAW.ORDERS_CDC_RAW;
```

```sql
MERGE INTO PG_CDC_DB.CURATED.ORDERS AS tgt
USING (
  SELECT
    RECORD_CONTENT:payload:op::string AS op,
    COALESCE(RECORD_CONTENT:payload:after:id, RECORD_CONTENT:payload:before:id)::int AS id,
    RECORD_CONTENT:payload:after:status::string AS status,
    RECORD_CONTENT:payload:after:amount::number AS amount,
    RECORD_CONTENT:payload:ts_ms::number AS ts_ms
  FROM PG_CDC_DB.RAW.ORDERS_CDC_STREAM
  QUALIFY ROW_NUMBER() OVER (PARTITION BY id ORDER BY ts_ms DESC) = 1
) AS src
ON tgt.id = src.id
WHEN MATCHED AND src.op = 'd' THEN DELETE
WHEN MATCHED THEN UPDATE SET status = src.status, amount = src.amount, updated_at_ms = src.ts_ms
WHEN NOT MATCHED AND src.op != 'd' THEN
  INSERT (id, status, amount, updated_at_ms) VALUES (src.id, src.status, src.amount, src.ts_ms);
```

これを定期実行のTaskにすれば、Snowflake上に「現在のRDSの状態を追随するテーブル」が維持できます。

## 注意点

| 項目 | 内容 |
| --- | --- |
| レプリケーションスロットの滞留 | コネクタが停止・詰まった状態が続くとレプリケーションスロットが未消費のWALを保持し続け、RDSのストレージを圧迫します。`pg_replication_slots`の`confirmed_flush_lsn`を監視し、長時間停止するなら`slot.drop.on.stop`やアラートを検討します |
| 配信保証 | Kafka Connect全般と同じくat-least-once配信です。今回のMERGEは`ts_ms`降順で1件に絞っているため、同一イベントが重複配信されても冪等になります |
| コスト | RDS + MSK(3ブローカー) + NAT Gateway + MSK Connect(2コネクタ)が常時課金されます。検証後はRDS/MSK/NATをdestroyし、レプリケーションスロットも明示的に削除してください |
| スキーマ変更 | `table.include.list`に対するDDL変更(カラム追加など)はDebeziumがスキーマ変更イベントとして検知しますが、下流のMERGE SQLは手動更新が必要です |
| セキュリティ | DB認証情報・Snowflakeの秘密鍵は必ずSecrets Manager経由(`${secretsManager:...}`)で渡し、コネクタ設定JSONに平文で書かないようにします |

## おわりに

RDS for PostgreSQL → Debezium(MSK Connect) → Amazon MSK → Snowflake Kafka Connector(MSK Connect) → Snowflakeという構成の構築手順を整理しました。
前回のIoT記事と同じくMSK + Snowflake Kafka Connectorの組み合わせですが、ソースがDebeziumになることで、

- スナップショット(初期ロード)とWALベースの継続追跡が1つのコネクタで完結する
- CDCイベントが`before` / `after` / `op`を持つため、単なる追記ではなく「現在値」の再現(UPDATE/DELETEの反映)まで見据えた設計が必要になる

という違いがありました。次は実際にこの手順を流し、レイテンシや障害時の挙動(コネクタ再起動時にスロットから正しく再開できるか等)を検証した記事を書く予定です。
