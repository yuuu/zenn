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

検証用のAWS環境はCloudFormationテンプレートとして用意し、`aws cloudformation deploy`で適用する形にしました。わかりやすさを優先して**1ファイル・1スタック**構成にしています。作業開始時点ではVPCとRDSまでを記述したテンプレートを用意しておき、そこにMSK → MSK Connectプラグイン → MSK Connectコネクタの順でセクションを追記しながら、同じスタック(`pg-cdc`)に対して`aws cloudformation deploy`を繰り返して育てていきます。

```
cloudformation/postgres-debezium-kafka-snowflake/
└── template.yaml   # VPC/RDS/MSK/MSK Connect(プラグイン+コネクタ)を1本にまとめたテンプレート
```

`template.yaml`はリポジトリには最終形(全リソース入り)を置いていますが、実際に手を動かす際は「そのSTEPで説明しているセクションだけを自分のファイルに書き写して`deploy`する → 動作確認する → 次のセクションを追記してまた`deploy`する」という順で進める想定です。CloudFormationのスタック更新は差分適用なので、途中でリソースを追記して再`deploy`すれば、既存分はそのままに新しいリソースだけが作成されます。

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

- AWS CLIで認証できるプロファイルがあること(VPC/RDS/MSK/MSK Connect/IAM/Secrets Managerを作成できる権限。IAMロールを作るため`CAPABILITY_NAMED_IAM`が必要です)
- Snowflake CLI(`snow`)が接続済みであること(今回はDB/ウェアハウス作成権限を持つロールで接続)
- `psql`が使えるクライアント環境(踏み台EC2 + SSM Session Managerのポートフォワード経由で接続します)
- Kafka Connect用カスタムプラグインを作るため、`curl` / `tar` / `zip`が使える環境

以降、変数は次の想定で記載します。適宜読み替えてください。

| 変数 | 値(例) |
| --- | --- |
| リージョン | `ap-northeast-1` |
| VPC CIDR | `10.40.0.0/16` |
| プロジェクト名 / スタック名 | `pg-cdc` |
| RDSインスタンス識別子 | `pg-cdc-source` |
| MSKクラスタ名 | `pg-cdc-kafka` |
| Snowflakeデータベース | `PG_CDC_DB` |

## STEP1: VPC + RDSまでのテンプレートを用意する

作業開始時点でまず用意するのは、VPC(ネットワーク)とRDS for PostgreSQLの2セクションだけです。`template.yaml`は最終的にMSK・MSK Connectまで含む1ファイルに育ちますが、最初はこの範囲だけ書いて動かします。

### ネットワーク(VPC / サブネット / SG / NAT / 踏み台)

MSKと同様、RDSもVPC内リソースです。3AZにプライベートサブネット、NAT Gateway用にパブリックサブネットを1つ用意します。

```yaml:cloudformation/postgres-debezium-kafka-snowflake/template.yaml(抜粋)
Resources:
  Vpc:
    Type: AWS::EC2::VPC
    Properties:
      CidrBlock: !Ref VpcCidr        # 10.40.0.0/16
      EnableDnsSupport: true
      EnableDnsHostnames: true

  PrivateSubnet0:                    # PrivateSubnet1 / PrivateSubnet2 も同様(3AZ)
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref Vpc
      CidrBlock: !Select [0, !Ref PrivateSubnetCidrs]
      AvailabilityZone: !Select [0, !GetAZs ""]
```

セキュリティグループは役割ごとに分けます。今回はMSK Connect側の2コネクタがどちらもIAM認証で接続するため、前回記事(SASL/SCRAM併用)より1本シンプルになっています(MSKを追加するSTEP3で実際に使い始めますが、SGだけ先に作っておきます)。

| SG | 用途 | 主なインバウンド |
| --- | --- | --- |
| `rds-sg` | RDS用 | `mskconnect-sg`と`bastion-sg`から5432 |
| `msk-sg` | MSKブローカー用 | `mskconnect-sg`と`bastion-sg`から9098(IAM) |
| `mskconnect-sg` | MSK Connect用 | 送信のみ(RDS:5432, MSK:9098, Snowflake:443) |
| `bastion-sg` | 踏み台EC2用 | インバウンドなし(SSM Session Manager経由で接続するため22番ポートを開けない) |

:::message
踏み台はSSHキーペア管理が不要なSSM Session Manager方式にしました。`BastionInstance`にはSSM用のIAMロールだけを付与し、セキュリティグループもインバウンドなしで作っています。接続は`aws ssm start-session --target <instance-id>`、RDS/MSKへのポートフォワードは`AWS-StartPortForwardingSessionToRemoteHost`ドキュメントを使います。
:::

:::message
Snowflake Kafka ConnectorはSnowflakeエンドポイントへ443でアウトバウンド接続するため、前回記事と同様にNAT Gatewayが必要です。S3はGatewayエンドポイントで通してNATを経由させません。
:::

### RDS for PostgreSQL(論理レプリケーション有効化)

`rds.logical_replication`はRDS独自のstaticパラメータで、変更するとインスタンスの再起動が必要です[^rds-logical-replication]。デフォルトのパラメータグループは変更できないため、カスタムパラメータグループを作成し、インスタンス作成時から適用します(初回作成時に適用する分には、既存インスタンスへの変更と違って追加の再起動は不要です)。

[^rds-logical-replication]: [Using logical replication with PostgreSQL on Amazon RDS](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/PostgreSQL.Concepts.General.FeatureSupport.LogicalReplication.html) に、`rds.logical_replication`パラメータを`1`にすると`wal_level`が自動的に`logical`になり、`max_wal_senders` / `max_replication_slots` / `max_connections`も引き上げられる旨の記載があります。

```yaml:cloudformation/postgres-debezium-kafka-snowflake/template.yaml(抜粋)
Resources:
  DBParameterGroup:
    Type: AWS::RDS::DBParameterGroup
    Properties:
      Family: postgres16
      Parameters:
        rds.logical_replication: "1"

  DBInstance:
    Type: AWS::RDS::DBInstance
    Properties:
      Engine: postgres
      EngineVersion: !Ref EngineVersion       # 16.4
      DBInstanceClass: !Ref DBInstanceClass   # db.t4g.micro
      ManageMasterUserPassword: true          # マスターパスワードはSecrets Manager管理
      DBSubnetGroupName: !Ref DBSubnetGroup
      DBParameterGroupName: !Ref DBParameterGroup
      VPCSecurityGroups:
        - !Ref RdsSecurityGroup
      PubliclyAccessible: false
      MultiAZ: false
```

ここまで(ネットワーク + RDS)を最初の`deploy`で作成します。

```bash
aws cloudformation deploy \
  --stack-name pg-cdc \
  --template-file cloudformation/postgres-debezium-kafka-snowflake/template.yaml \
  --parameter-overrides ProjectName=pg-cdc \
  --capabilities CAPABILITY_NAMED_IAM

DB_HOST=$(aws cloudformation describe-stacks --stack-name pg-cdc \
  --query "Stacks[0].Outputs[?OutputKey=='DBInstanceEndpointAddress'].OutputValue" --output text)
DB_MASTER_SECRET_ARN=$(aws cloudformation describe-stacks --stack-name pg-cdc \
  --query "Stacks[0].Outputs[?OutputKey=='MasterUserSecretArn'].OutputValue" --output text)
```

マスターパスワードは`ManageMasterUserPassword: true`によりSecrets Manager管理になっているため、`aws secretsmanager get-secret-value --secret-id "$DB_MASTER_SECRET_ARN"`で取得します。

### 論理レプリケーション用ユーザーとPublicationを作成

RDSはプライベートサブネットにあるため、テンプレートで作った踏み台からSSM Session Managerのポートフォワードで接続します(SSHキーペアの管理が不要です)。

```bash
BASTION_ID=$(aws cloudformation describe-stacks --stack-name pg-cdc \
  --query "Stacks[0].Outputs[?OutputKey=='BastionInstanceId'].OutputValue" --output text)

aws ssm start-session --target "$BASTION_ID" \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "{\"host\":[\"$DB_HOST\"],\"portNumber\":[\"5432\"],\"localPortNumber\":[\"15432\"]}"
```

別ターミナルで`psql "host=127.0.0.1 port=15432 dbname=appdb user=postgres"`のように接続します。

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

## STEP2: MSKをテンプレートに追記する

`template.yaml`に`AWS::MSK::Cluster`のセクションを追記します。`kafka.t3.small` ×3、TLS暗号化という基本構成は前回記事と同じですが、認証方式は**IAMのみ**にしました。今回の2コネクタ(Debezium Source / Snowflake Sink)はどちらもMSK Connect上で動きIAM認証を使えるため、前回記事のようにSASL/SCRAMを併用する理由がありません。動作確認用のkafkaクライアントも`aws-msk-iam-auth`ライブラリでIAM認証できるため、SCRAM用のKMSキー・Secrets Manager・`AmazonMSK_`プレフィックス管理を丸ごと省略できます。

```yaml:cloudformation/postgres-debezium-kafka-snowflake/template.yaml(追記分)
Resources:
  # STEP1のVpc/PrivateSubnet*/RdsSecurityGroup/DBInstanceなどはそのまま
  MskCluster:
    Type: AWS::MSK::Cluster
    Properties:
      ClusterName: !Ref ClusterName          # pg-cdc-kafka
      KafkaVersion: !Ref KafkaVersion        # 3.8.x
      NumberOfBrokerNodes: 3
      BrokerNodeGroupInfo:
        InstanceType: !Ref BrokerInstanceType # kafka.t3.small
        ClientSubnets:
          - !Ref PrivateSubnet0
          - !Ref PrivateSubnet1
          - !Ref PrivateSubnet2
        SecurityGroups:
          - !Ref MskSecurityGroup
      EncryptionInfo:
        EncryptionInTransit:
          ClientBroker: TLS
      ClientAuthentication:
        Sasl:
          Iam:
            Enabled: true
```

同じスタックへ再`deploy`します。既存のVPC/RDSはそのまま、MSKだけが新規作成されます。

```bash
aws cloudformation deploy \
  --stack-name pg-cdc \
  --template-file cloudformation/postgres-debezium-kafka-snowflake/template.yaml \
  --parameter-overrides ProjectName=pg-cdc \
  --capabilities CAPABILITY_NAMED_IAM
```

:::message
MSKクラスタの作成には20〜40分程度かかります。`aws cloudformation deploy`はスタックが`UPDATE_COMPLETE`になるまでブロックするので、そのまま待ちます。
:::

## STEP3: MSK Connect用カスタムプラグインを追記する

コネクタは2つ用意するので、プラグインも2つ用意します。プラグインの実体(ZIP)はCloudFormationでは作れない(ビルド成果物なので)ため、①S3バケットのセクションだけ先に追記して`deploy` → ②`aws s3 cp`でZIPをアップロード → ③`AWS::KafkaConnect::CustomPlugin`のセクションを追記してもう一度`deploy`、という2段階になります。`CustomPlugin`はスタック更新時点でS3オブジェクトが実在することを検証するため、この順番を守る必要があります。

### S3バケットを追記してデプロイ

```yaml:cloudformation/postgres-debezium-kafka-snowflake/template.yaml(追記分)
Resources:
  PluginBucket:
    Type: AWS::S3::Bucket
    Properties:
      BucketName: !Sub "${ProjectName}-connect-plugins-${AWS::AccountId}-${AWS::Region}"
      VersioningConfiguration:
        Status: Enabled
      PublicAccessBlockConfiguration:
        BlockPublicAcls: true
        BlockPublicPolicy: true
        IgnorePublicAcls: true
        RestrictPublicBuckets: true

  PluginBucketPolicy:
    Type: AWS::S3::BucketPolicy
    Properties:
      Bucket: !Ref PluginBucket
      PolicyDocument:
        Version: "2012-10-17"
        Statement:
          - Effect: Allow
            Principal:
              Service: kafkaconnect.amazonaws.com
            Action: s3:GetObject
            Resource: !Sub "${PluginBucket.Arn}/*"
            Condition:
              StringEquals:
                aws:SourceAccount: !Ref AWS::AccountId
```

```bash
aws cloudformation deploy \
  --stack-name pg-cdc \
  --template-file cloudformation/postgres-debezium-kafka-snowflake/template.yaml \
  --parameter-overrides ProjectName=pg-cdc \
  --capabilities CAPABILITY_NAMED_IAM

BUCKET_NAME=$(aws cloudformation describe-stacks --stack-name pg-cdc \
  --query "Stacks[0].Outputs[?OutputKey=='PluginBucketName'].OutputValue" --output text)
```

### プラグインZIPをビルドしてアップロード

Maven CentralからDebezium公式のプラグインアーカイブを取得します[^debezium-plugin]。MSK Connectのカスタムプラグインは**ZIP形式**が必須ですが、Debeziumの配布物は`tar.gz`なので展開して再圧縮します。

```bash
DEBEZIUM_VERSION=3.0.8  # https://debezium.io/releases/ で最新の安定版を確認

curl -fsSL -o debezium-connector-postgres.tar.gz \
  "https://repo1.maven.org/maven2/io/debezium/debezium-connector-postgres/${DEBEZIUM_VERSION}/debezium-connector-postgres-${DEBEZIUM_VERSION}-plugin.tar.gz"

mkdir -p build/debezium-connector-postgres
tar xzf debezium-connector-postgres.tar.gz -C build/debezium-connector-postgres --strip-components=1
(cd build && zip -r ../debezium-connector-postgres.zip debezium-connector-postgres)

aws s3 cp debezium-connector-postgres.zip "s3://${BUCKET_NAME}/debezium-connector-postgres.zip"
```

[^debezium-plugin]: [Deploy Debezium on Kafka Connect Cluster on AWS - Debezium Documentation](https://debezium.io/documentation/reference/stable/operations/debezium-on-kubernetes.html) 系のガイドでも、AWS上のKafka Connectへは公式プラグインアーカイブをそのまま/再パッケージして配置する方式が案内されています。MSK Connectのカスタムプラグインの制約(ZIP必須)は[Amazon MSK Connect - Custom plugins](https://docs.aws.amazon.com/msk/latest/developerguide/msk-connect-plugins.html)を参照してください。

Snowflake Kafka Connectorも同様に、前回記事と同じ手順(Maven Centralからfat jarを取得しS3経由で登録)です。

```bash
SNOWFLAKE_CONNECTOR_VERSION=3.2.2

curl -fsSL -o snowflake-kafka-connector.jar \
  "https://repo1.maven.org/maven2/com/snowflake/snowflake-kafka-connector/${SNOWFLAKE_CONNECTOR_VERSION}/snowflake-kafka-connector-${SNOWFLAKE_CONNECTOR_VERSION}.jar"

mkdir -p build/snowflake-kafka-connector
cp snowflake-kafka-connector.jar build/snowflake-kafka-connector/
(cd build && zip -r ../snowflake-kafka-connector.zip snowflake-kafka-connector)

aws s3 cp snowflake-kafka-connector.zip "s3://${BUCKET_NAME}/snowflake-kafka-connector.zip"
```

### カスタムプラグインのセクションを追記してデプロイ

ZIPのアップロードが終わったら、`template.yaml`に2つの`AWS::KafkaConnect::CustomPlugin`を追記します。

```yaml:cloudformation/postgres-debezium-kafka-snowflake/template.yaml(追記分)
Resources:
  DebeziumPlugin:
    Type: AWS::KafkaConnect::CustomPlugin
    Properties:
      ContentType: ZIP
      Location:
        S3Location:
          BucketArn: !GetAtt PluginBucket.Arn
          FileKey: !Ref DebeziumPluginKey # debezium-connector-postgres.zip

  SnowflakePlugin:
    Type: AWS::KafkaConnect::CustomPlugin
    Properties:
      ContentType: ZIP
      Location:
        S3Location:
          BucketArn: !GetAtt PluginBucket.Arn
          FileKey: !Ref SnowflakePluginKey # snowflake-kafka-connector.zip
```

```bash
aws cloudformation deploy \
  --stack-name pg-cdc \
  --template-file cloudformation/postgres-debezium-kafka-snowflake/template.yaml \
  --parameter-overrides ProjectName=pg-cdc \
  --capabilities CAPABILITY_NAMED_IAM
```

## STEP4: Snowflake側の受け皿を準備する

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

### コネクタ用の認証情報をSecrets Managerへ登録

テンプレートにこの後追記するコネクタは、DBパスワードとSnowflakeの秘密鍵を直書きせず、Secrets ManagerのARNをパラメータとして受け取る作りにしています。鍵・パスワードそのものをGitで管理するテンプレートファイルに含めないためです。STEP1で作った`debezium`ユーザーのパスワードと、上で生成した秘密鍵をそれぞれ登録します。

```bash
DEBEZIUM_DB_SECRET_ARN=$(aws secretsmanager create-secret \
  --name pg-cdc/debezium-db-user \
  --secret-string "{\"password\":\"<STEP1で設定したパスワード>\"}" \
  --query ARN --output text)

PRIVATE_KEY_BODY=$(grep -v "PRIVATE KEY" kafka_connector_key.p8 | tr -d '\n')

SNOWFLAKE_KEY_SECRET_ARN=$(aws secretsmanager create-secret \
  --name pg-cdc/snowflake-kafka-user \
  --secret-string "{\"private_key\":\"${PRIVATE_KEY_BODY}\"}" \
  --query ARN --output text)
```

## STEP5: MSK Connectコネクタをテンプレートに追記し、両方デプロイする

最後に、Debezium Source ConnectorとSnowflake Sink Connector、それらが使うMSK Connect実行ロールを`template.yaml`に追記します。実行ロールには、Kafkaクラスタへの`kafka-cluster:Connect` / `*Topic*` / `*Group*`権限、ENI管理権限、Secrets Managerへの`GetSecretValue`権限を付与しています。

コネクタ設定のポイントは以下です。

- `plugin.name=pgoutput`(RDSはネイティブの`pgoutput`が使え、追加の拡張インストールが不要)
- `topic.prefix`でトピック名の接頭辞(サーバー論理名)を決める
- `table.include.list`でキャプチャ対象を明示的に絞る
- `snapshot.mode=initial`で初回起動時に既存データを一括取り込みしてからWAL追跡に切り替える
- SMTは使わず、`before` / `after` / `op` を含むDebeziumのエンベロープをそのままJSONで流す(Snowflake側でVARIANTとして受け止め、SQLで加工する方針のため)
- `value.converter.schemas.enable=true`にしているのは、Snowflake Sink側の同項目と揃える必要があるためです(JSONのペイロードが`{"schema": ..., "payload": {...}}`の形になります)

```yaml:cloudformation/postgres-debezium-kafka-snowflake/template.yaml(追記分)
Resources:
  DebeziumPostgresSourceConnector:
    Type: AWS::KafkaConnect::Connector
    Properties:
      ConnectorConfiguration:
        connector.class: io.debezium.connector.postgresql.PostgresConnector
        database.hostname: !GetAtt DBInstance.Endpoint.Address
        database.port: !GetAtt DBInstance.Endpoint.Port
        database.user: !Ref DebeziumDbUsername
        database.password: !Join ["", ["${secretsManager:", !Ref DebeziumDbSecretArn, ":password}"]]
        database.dbname: !Ref DBName
        topic.prefix: !Ref DebeziumTopicPrefix         # pgdb
        table.include.list: !Ref DebeziumTableIncludeList # public.orders
        plugin.name: pgoutput
        publication.name: !Ref DebeziumPublicationName # dbz_publication
        publication.autocreate.mode: disabled
        slot.name: !Ref DebeziumSlotName               # dbz_pgdb_slot
        snapshot.mode: initial
        key.converter.schemas.enable: "false"
        value.converter.schemas.enable: "true"
        heartbeat.interval.ms: "10000"
      Plugins:
        - CustomPlugin:
            CustomPluginArn: !Ref DebeziumPlugin
            Revision: !GetAtt DebeziumPlugin.Revision
      ServiceExecutionRoleArn: !GetAtt ConnectExecutionRole.Arn

  SnowflakeSinkConnector:
    Type: AWS::KafkaConnect::Connector
    Properties:
      ConnectorConfiguration:
        connector.class: com.snowflake.kafka.connector.SnowflakeSinkConnector
        topics: !Sub "${DebeziumTopicPrefix}.${DebeziumTableIncludeList}" # pgdb.public.orders
        snowflake.topic2table.map: !Ref SnowflakeTopic2TableMap
        snowflake.url.name: !Ref SnowflakeAccountUrl
        snowflake.user.name: !Ref SnowflakeUser
        snowflake.private.key: !Join ["", ["${secretsManager:", !Ref SnowflakePrivateKeySecretArn, ":private_key}"]]
        snowflake.role.name: !Ref SnowflakeRole
        snowflake.database.name: !Ref SnowflakeDatabase
        snowflake.schema.name: !Ref SnowflakeSchema
        snowflake.ingestion.method: SNOWPIPE_STREAMING
        snowflake.enable.schematization: "false"
        snowflake.streaming.max.client.lag: "1"
        key.converter: org.apache.kafka.connect.storage.StringConverter
        value.converter.schemas.enable: "true"
      Plugins:
        - CustomPlugin:
            CustomPluginArn: !Ref SnowflakePlugin
            Revision: !GetAtt SnowflakePlugin.Revision
      ServiceExecutionRoleArn: !GetAtt ConnectExecutionRole.Arn
```

`database.password` / `snowflake.private.key`は`Fn::Join`で`${secretsManager:<ARN>:password}`という文字列を組み立てています(MSK Connect側がこの構文をランタイムで解決してくれるので、平文を書かずに済みます[^msk-connect-secrets])。CloudFormationの`Fn::Sub`は`${...}`をテンプレート側の置換として解釈してしまうため、ここは意図的に`Fn::Join`にしている点に注意してください。同様に`database.hostname`はSTEP1で作った`DBInstance`を`!GetAtt`で直接参照しています。1ファイルにまとめたことで、他スタックの値をパラメータ経由で受け渡す必要がなくなりました。

[^msk-connect-secrets]: [Externalize secrets for MSK Connect connector configuration](https://docs.aws.amazon.com/msk/latest/developerguide/mkc-externalize-secrets.html)

`heartbeat.interval.ms`を設定しているのは、対象テーブルの更新頻度が低い場合でもレプリケーションスロットのLSNを定期的に前進させ、WALの滞留を防ぐためです[^debezium-heartbeat]。

[^debezium-heartbeat]: [Debezium connector for PostgreSQL - Heartbeat messages](https://debezium.io/documentation/reference/stable/connectors/postgresql.html#postgresql-heartbeat-messages) に、低頻度更新テーブルではハートビートなしだとLSNが進まずWALが溜まり続けるリスクが明記されています。

ここまでの準備(RDSはテンプレート内から直接参照、STEP4で登録した2つのSecrets Manager ARN、Snowflakeアカウント情報)が揃ったら、最後のデプロイでDebezium/Snowflake両コネクタを作成します。

```bash
aws cloudformation deploy \
  --stack-name pg-cdc \
  --template-file cloudformation/postgres-debezium-kafka-snowflake/template.yaml \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
    ProjectName=pg-cdc \
    DebeziumDbSecretArn="$DEBEZIUM_DB_SECRET_ARN" \
    SnowflakeAccountUrl="https://<account>.snowflakecomputing.com" \
    SnowflakePrivateKeySecretArn="$SNOWFLAKE_KEY_SECRET_ARN"
```

デプロイ後、両コネクタが`RUNNING`になっていることを確認します。

```bash
aws kafkaconnect list-connectors --query "connectors[].{name:connectorName,state:connectorState}"
```

CloudWatch Logsのロググループ`/msk-connect/pg-cdc`に、Debezium側のスナップショット完了ログ(`Snapshot ended with SnapshotResult`など)が出ていれば取り込みが動いています。

## STEP6: 動作確認

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

## STEP7: 「現在値」テーブルへ反映する

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
| コスト | RDS + MSK(3ブローカー) + NAT Gateway + MSK Connect(2コネクタ)が常時課金されます。検証後は`aws cloudformation delete-stack --stack-name pg-cdc`で一括削除できます(S3バケットは中身を空にしてから)。レプリケーションスロットも明示的に削除してください |
| スキーマ変更 | `table.include.list`に対するDDL変更(カラム追加など)はDebeziumがスキーマ変更イベントとして検知しますが、下流のMERGE SQLは手動更新が必要です |
| セキュリティ | DB認証情報・Snowflakeの秘密鍵は必ずSecrets Manager経由(`${secretsManager:...}`)で渡し、CloudFormationテンプレートに平文で書かないようにします。`template.yaml`もARNだけをパラメータで受け取る作りにしています |

## おわりに

RDS for PostgreSQL → Debezium(MSK Connect) → Amazon MSK → Snowflake Kafka Connector(MSK Connect) → Snowflakeという構成の構築手順を整理しました。
前回のIoT記事と同じくMSK + Snowflake Kafka Connectorの組み合わせですが、ソースがDebeziumになることで、

- スナップショット(初期ロード)とWALベースの継続追跡が1つのコネクタで完結する
- CDCイベントが`before` / `after` / `op`を持つため、単なる追記ではなく「現在値」の再現(UPDATE/DELETEの反映)まで見据えた設計が必要になる

という違いがありました。CloudFormationも前回のTerraformから1ファイル・1スタック構成に変え、VPC/RDSという「土台」から始めてMSK・MSK Connectを追記していく流れにしたことで、どのSTEPでどのリソースが増えるかが1つのファイルの差分として追いやすくなりました。次は実際にこの手順を流し、レイテンシや障害時の挙動(コネクタ再起動時にスロットから正しく再開できるか等)を検証した記事を書く予定です。
