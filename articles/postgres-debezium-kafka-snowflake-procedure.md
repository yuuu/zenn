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

本記事はもともと実際に手を動かす前の**構築手順の整理**として書き始めましたが、実際にゼロから最後まで通しで構築・動作確認まで行い、そこで見つかった問題点(バージョン差異・AWSアカウント固有の挙動・CloudFormationの制約など)を本文に反映しています。手順どおりに進めれば、この記事の中だけで詰まらずにRDS→Debezium→MSK→Snowflakeのエンドツーエンドの疎通まで確認できるはずです。

- AWS: アカウントは存在するが、VPC・RDSともに未構築の状態から開始
- Snowflake: CLI(`snow`)は接続済みだが、今回用のDB・ウェアハウスは未作成の状態から開始

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
      AvailabilityZone: !Select [0, !Ref AvailabilityZones]
```

:::message
当初`!Select [0, !GetAZs ""]`でAZを取得する形にしていましたが、実際にデプロイするアカウントによっては`Fn::GetAZs`がそのリージョンの全AZを返さないことがありました(`aws ec2 describe-availability-zones`では3AZとも`opt-in-not-required`/`available`なのに、`Fn::GetAZs`は2AZ分しか返さない)。`Fn::Select`が存在しないインデックスを選択しようとして`Template error: Fn::Select cannot select nonexistent value at index 2`で作成に失敗するため、`AvailabilityZones`という`CommaDelimitedList`パラメータ(デフォルト`ap-northeast-1a,ap-northeast-1c,ap-northeast-1d`)を追加し、AZ名を明示的に指定する形に変更しています。
:::

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
      EngineVersion: !Ref EngineVersion       # 16.15
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

以降の手順ではキャプチャ対象として`orders`テーブルの存在を前提にしているので、先に検証用のテーブルを作成しておきます(既存のアプリケーションスキーマがある場合は読み替えてください)。

```sql
CREATE TABLE orders (
  id INT PRIMARY KEY,
  status TEXT NOT NULL,
  amount NUMERIC NOT NULL
);
```

```sql
-- Debezium専用ユーザー
CREATE USER debezium WITH PASSWORD '...';
GRANT rds_replication TO debezium;

-- 対象テーブルへのSELECT権限(スナップショット取得に必要)
GRANT SELECT ON public.orders TO debezium;

-- Publicationを明示的に作成(自動作成に頼らずスコープを絞る)
CREATE PUBLICATION dbz_publication FOR TABLE public.orders;
```

:::message
RDSでは`rds_superuser`が実際のsuperuserではないため、`CREATE USER ... WITH REPLICATION`のようにREPLICATION属性を直接指定することはできません(`ERROR: permission denied to create role`)。`ALTER USER debezium WITH REPLICATION`も同様にエラーになります。代わりに`GRANT rds_replication TO debezium`でロール経由の権限を付与します。
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

:::message
後述のSTEP5で`${secretsmanager:...}`によるシークレット埋め込みを使うため、実は**この時点でプラグインZIPに追加のJARを同梱しておく必要があります**(詳細はSTEP5参照)。この記事ではSTEP3のビルド手順に最初から組み込んでいます。
:::

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
DEBEZIUM_VERSION=3.6.3.Final  # https://debezium.io/releases/ で最新の安定版を確認(3.0.8は既にEOL)

curl -fsSL -o debezium-connector-postgres.tar.gz \
  "https://repo1.maven.org/maven2/io/debezium/debezium-connector-postgres/${DEBEZIUM_VERSION}/debezium-connector-postgres-${DEBEZIUM_VERSION}-plugin.tar.gz"

mkdir -p build/debezium-connector-postgres
tar xzf debezium-connector-postgres.tar.gz -C build/debezium-connector-postgres --strip-components=1
```

:::message
`${secretsmanager:...}`によるシークレット埋め込みは、実はMSK Connectの組み込み機能ではありません。OSSの[msk-config-providers](https://github.com/aws-samples/msk-config-providers)というライブラリをプラグインZIPに同梱し、後述のWorker Configurationで明示的に有効化する必要があります(参照: [Tutorial: Externalizing sensitive information using config providers](https://docs.aws.amazon.com/msk/latest/developerguide/msk-connect-config-provider.html))。同梱しないと、コネクタ起動時に`ClassNotFoundException: com.amazonaws.kafka.config.providers.SecretsManagerConfigProvider`で失敗します。
:::

```bash
MSK_CONFIG_PROVIDERS_VERSION=0.5.0

curl -fsSL -o msk-config-providers.jar \
  "https://github.com/aws-samples/msk-config-providers/releases/download/v${MSK_CONFIG_PROVIDERS_VERSION}/msk-config-providers-${MSK_CONFIG_PROVIDERS_VERSION}-all.jar"

cp msk-config-providers.jar build/debezium-connector-postgres/
(cd build && zip -r ../debezium-connector-postgres.zip debezium-connector-postgres)

aws s3 cp debezium-connector-postgres.zip "s3://${BUCKET_NAME}/debezium-connector-postgres.zip"
```

[^debezium-plugin]: [Deploy Debezium on Kafka Connect Cluster on AWS - Debezium Documentation](https://debezium.io/documentation/reference/stable/operations/debezium-on-kubernetes.html) 系のガイドでも、AWS上のKafka Connectへは公式プラグインアーカイブをそのまま/再パッケージして配置する方式が案内されています。MSK Connectのカスタムプラグインの制約(ZIP必須)は[Amazon MSK Connect - Custom plugins](https://docs.aws.amazon.com/msk/latest/developerguide/msk-connect-plugins.html)を参照してください。

Snowflake Kafka Connectorも同様に、前回記事と同じ手順(Maven Centralからfat jarを取得しS3経由で登録)です。こちらにもmsk-config-providersを同梱します。

```bash
SNOWFLAKE_CONNECTOR_VERSION=4.1.0  # 3.2.2は既に古い。connector.classがバージョンで変わる点に注意(後述)

curl -fsSL -o snowflake-kafka-connector.jar \
  "https://repo1.maven.org/maven2/com/snowflake/snowflake-kafka-connector/${SNOWFLAKE_CONNECTOR_VERSION}/snowflake-kafka-connector-${SNOWFLAKE_CONNECTOR_VERSION}.jar"

mkdir -p build/snowflake-kafka-connector
cp snowflake-kafka-connector.jar msk-config-providers.jar build/snowflake-kafka-connector/
```

:::message
Snowflake Kafka Connector 4.1.0で暗号化秘密鍵(後述のキーペア認証)を使う場合、`bc-fips` / `bcpkix-fips`(Bouncy Castle FIPSプロバイダ)が別途必要です。同梱しないと`NoClassDefFoundError: org/bouncycastle/jcajce/provider/BouncyCastleFipsProvider`で失敗します[^bc-fips]。
:::

```bash
curl -fsSL -o bc-fips-2.1.0.jar \
  "https://repo1.maven.org/maven2/org/bouncycastle/bc-fips/2.1.0/bc-fips-2.1.0.jar"
curl -fsSL -o bcpkix-fips-2.1.8.jar \
  "https://repo1.maven.org/maven2/org/bouncycastle/bcpkix-fips/2.1.8/bcpkix-fips-2.1.8.jar"

cp bc-fips-2.1.0.jar bcpkix-fips-2.1.8.jar build/snowflake-kafka-connector/
(cd build && zip -r ../snowflake-kafka-connector.zip snowflake-kafka-connector)

aws s3 cp snowflake-kafka-connector.zip "s3://${BUCKET_NAME}/snowflake-kafka-connector.zip"
```

[^bc-fips]: [java.lang.NoClassDefFoundError: org/bouncycastle/jcajce/provider/BouncyCastleFipsProvider (solved) · Issue #888](https://github.com/snowflakedb/snowflake-kafka-connector/issues/888) に、Kafka Connector 4.1.0では`bc-fips/2.1.0`と`bcpkix-fips/2.1.8`が必要である旨の記載があります。

### カスタムプラグインのセクションを追記してデプロイ

ZIPのアップロードが終わったら、`template.yaml`に2つの`AWS::KafkaConnect::CustomPlugin`を追記します。

```yaml:cloudformation/postgres-debezium-kafka-snowflake/template.yaml(追記分)
Resources:
  # Nameは必須プロパティ。固定文字列のままFileKey(ZIPの中身)を差し替えて再デプロイすると
  # 「置き換えが必要なのに同名リソースが既存のため更新できない」エラーになるため、
  # プラグインのバージョンをNameにも含めている(内容を差し替えるたびにNameも変える)。
  # また"."を含む名前はMSK Connect側で拒否されるため、FileKeyそのものは使えない。
  DebeziumPlugin:
    Type: AWS::KafkaConnect::CustomPlugin
    Properties:
      Name: !Sub "${ProjectName}-debezium-postgres-connector-v2"
      ContentType: ZIP
      Location:
        S3Location:
          BucketArn: !GetAtt PluginBucket.Arn
          FileKey: !Ref DebeziumPluginKey # debezium-connector-postgres.zip

  SnowflakePlugin:
    Type: AWS::KafkaConnect::CustomPlugin
    Properties:
      Name: !Sub "${ProjectName}-snowflake-kafka-connector-v3"
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
GRANT ALL ON FUTURE TABLES IN SCHEMA PG_CDC_DB.RAW TO ROLE PG_CDC_KAFKA_ROLE;
"
```

生テーブルは、DebeziumエンベロープをそのままVARIANTで受け止める設計にします(スキーマ変換=`false`)。CDCでは`before`/`after`/`op`をそのまま持つ方が下流のMERGE処理で扱いやすいためです。

```sql
CREATE TABLE IF NOT EXISTS PG_CDC_DB.RAW.ORDERS_CDC_RAW (
  RECORD_METADATA VARIANT,
  RECORD_CONTENT  VARIANT
);
```

:::message
`GRANT ALL ON SCHEMA`は**その時点で既に存在するテーブル**には効きません(スキーマ自体への権限のみ)。上の`GRANT ... ON FUTURE TABLES`を先に実行してから`CREATE TABLE`する順序にすることで、作成と同時に`PG_CDC_KAFKA_ROLE`へテーブル権限が付与されます。順序を逆にすると、Snowflake Sink Connector起動時に`Table 'ORDERS_CDC_RAW' already exists, but current role has no privileges on it.`というSQLコンパイルエラーで失敗します(その場合は`GRANT ALL ON ALL TABLES IN SCHEMA PG_CDC_DB.RAW TO ROLE PG_CDC_KAFKA_ROLE;`で事後救済できます)。
:::

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

:::message
STEP5のコネクタ設定で`${secretsmanager:...}`により参照するのは、このARN**ではなく**シークレット**名**(`pg-cdc/debezium-db-user`など)です。理由は後述します。
:::

## STEP5: MSK Connectコネクタをテンプレートに追記し、両方デプロイする

最後に、Debezium Source ConnectorとSnowflake Sink Connector、それらが使うMSK Connect実行ロール、そしてこの2つのコネクタが共有するWorker Configurationを`template.yaml`に追記します。

### MSKのブートストラップブローカー文字列を取得する

`AWS::MSK::Cluster`は`BootstrapBrokerStringSaslIam`をCloudFormationの`Fn::GetAtt`で取得できません(readOnlyPropertiesに含まれるのは`Arn`/`CurrentVersion`のみ)。そのため、STEP2で作成済みのMSKクラスタに対してCLIで直接取得し、`MskBootstrapServers`パラメータとしてSTEP5のdeployに渡す形にしています。

```bash
MSK_CLUSTER_ARN=$(aws cloudformation describe-stacks --stack-name pg-cdc \
  --query "Stacks[0].Outputs[?OutputKey=='MskClusterArn'].OutputValue" --output text)

MSK_BOOTSTRAP_SERVERS=$(aws kafka get-bootstrap-brokers \
  --cluster-arn "$MSK_CLUSTER_ARN" \
  --query "BootstrapBrokerStringSaslIam" --output text)
```

### Worker Configuration(シークレット埋め込み用のconfig provider)

STEP3で触れたとおり、`${secretsmanager:...}`によるシークレット埋め込みはOSSの[msk-config-providers](https://github.com/aws-samples/msk-config-providers)を使う仕組みです。プラグインZIPにJARを同梱するだけでなく、Worker Configurationで`config.providers`を明示的に定義する必要があります。

```yaml:cloudformation/postgres-debezium-kafka-snowflake/template.yaml(追記分)
Resources:
  ConnectWorkerConfiguration:
    Type: AWS::KafkaConnect::WorkerConfiguration
    Properties:
      Name: !Sub "${ProjectName}-secrets-worker-config"
      PropertiesFileContent:
        Fn::Base64:
          !Sub |
            key.converter=org.apache.kafka.connect.json.JsonConverter
            key.converter.schemas.enable=false
            value.converter=org.apache.kafka.connect.json.JsonConverter
            value.converter.schemas.enable=true
            config.providers=secretsmanager
            config.providers.secretsmanager.class=com.amazonaws.kafka.config.providers.SecretsManagerConfigProvider
            config.providers.secretsmanager.param.region=${AWS::Region}
```

:::message
`PropertiesFileContent`は**Base64エンコード済みの文字列**を渡す必要があります(CLIの`--properties-file-content`と同じ)。プレーンテキストをそのまま渡すと`Invalid Base64 scheme`で失敗するため、`Fn::Base64`で包んでいます。
:::

### 実行ロールにSecrets Manager権限を追加

config providerは`GetSecretValue` / `DescribeSecret`に加え、`GetResourcePolicy` / `ListSecretVersionIds`も要求します。STEP1〜4で使ってきた`ConnectExecutionRole`のSecretsステートメントに追記します。

```yaml:cloudformation/postgres-debezium-kafka-snowflake/template.yaml(抜粋・追記分)
              - Sid: Secrets
                Effect: Allow
                Action:
                  - secretsmanager:GetSecretValue
                  - secretsmanager:DescribeSecret
                  - secretsmanager:GetResourcePolicy
                  - secretsmanager:ListSecretVersionIds
                Resource:
                  - !Sub "arn:aws:secretsmanager:${AWS::Region}:${AWS::AccountId}:secret:${ProjectName}/*"
```

### コネクタ本体

コネクタ設定のポイントは以下です。

- `plugin.name=pgoutput`(RDSはネイティブの`pgoutput`が使え、追加の拡張インストールが不要)
- `topic.prefix`でトピック名の接頭辞(サーバー論理名)を決める
- `table.include.list`でキャプチャ対象を明示的に絞る
- `snapshot.mode=initial`で初回起動時に既存データを一括取り込みしてからWAL追跡に切り替える
- SMTは使わず、`before` / `after` / `op` を含むDebeziumのエンベロープをそのままJSONで流す(Snowflake側でVARIANTとして受け止め、SQLで加工する方針のため)
- `value.converter.schemas.enable=true`にしているのは、Snowflake Sink側の同項目と揃える必要があるためです
- `decimal.handling.mode: double`(後述)
- `topic.creation.enable: "true"`(後述)
- `KafkaConnectVersion: "3.7.x"`(後述)

```yaml:cloudformation/postgres-debezium-kafka-snowflake/template.yaml(追記分)
Resources:
  DebeziumPostgresSourceConnector:
    Type: AWS::KafkaConnect::Connector
    Properties:
      KafkaConnectVersion: !Ref KafkaConnectVersion  # 3.7.x
      ConnectorConfiguration:
        connector.class: io.debezium.connector.postgresql.PostgresConnector
        database.hostname: !GetAtt DBInstance.Endpoint.Address
        database.port: !GetAtt DBInstance.Endpoint.Port
        database.user: !Ref DebeziumDbUsername
        database.password: !Join ["", ["${secretsmanager:", !Ref ProjectName, "/debezium-db-user:password}"]]
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
        decimal.handling.mode: double
        heartbeat.interval.ms: "10000"
        topic.creation.enable: "true"
        topic.creation.default.replication.factor: "3"
        topic.creation.default.partitions: "1"
      Plugins:
        - CustomPlugin:
            CustomPluginArn: !Ref DebeziumPlugin
            Revision: !GetAtt DebeziumPlugin.Revision
      WorkerConfiguration:
        WorkerConfigurationArn: !Ref ConnectWorkerConfiguration
        Revision: 1
      ServiceExecutionRoleArn: !GetAtt ConnectExecutionRole.Arn

  SnowflakeSinkConnector:
    Type: AWS::KafkaConnect::Connector
    Properties:
      KafkaConnectVersion: !Ref KafkaConnectVersion  # 3.7.x
      ConnectorConfiguration:
        connector.class: com.snowflake.kafka.connector.SnowflakeStreamingSinkConnector
        topics: !Sub "${DebeziumTopicPrefix}.${DebeziumTableIncludeList}" # pgdb.public.orders
        snowflake.topic2table.map: !Ref SnowflakeTopic2TableMap
        snowflake.url.name: !Ref SnowflakeAccountUrl
        snowflake.user.name: !Ref SnowflakeUser
        snowflake.private.key: !Join ["", ["${secretsmanager:", !Ref ProjectName, "/snowflake-kafka-user:private_key}"]]
        snowflake.role.name: !Ref SnowflakeRole
        snowflake.database.name: !Ref SnowflakeDatabase
        snowflake.schema.name: !Ref SnowflakeSchema
        snowflake.ingestion.method: SNOWPIPE_STREAMING
        snowflake.enable.schematization: "false"
        snowflake.streaming.max.client.lag: "1"
        snowflake.streaming.validate.compatibility.with.classic: "false"
        key.converter: org.apache.kafka.connect.storage.StringConverter
        value.converter.schemas.enable: "true"
      Plugins:
        - CustomPlugin:
            CustomPluginArn: !Ref SnowflakePlugin
            Revision: !GetAtt SnowflakePlugin.Revision
      WorkerConfiguration:
        WorkerConfigurationArn: !Ref ConnectWorkerConfiguration
        Revision: 1
      ServiceExecutionRoleArn: !GetAtt ConnectExecutionRole.Arn
```

ここは実際に手を動かしてハマったポイントが多いので、順番に補足します。

:::message
**KafkaConnectVersionは`"2.7.1"`と`"3.7.x"`しか選べません**(`aws kafkaconnect create-connector`にわざと不正な値を渡すと有効な選択肢がエラーメッセージで表示されます)。Debezium 3.x系のプラグインを`2.7.1`のワーカーに載せると、プラグインスキャン自体は成功するのにクラスが認識されず`Failed to find any class that implements Connector and which name matches io.debezium.connector.postgresql.PostgresConnector`で作成に失敗します。`3.7.x`を指定してください。
:::

:::message
Snowflake Kafka Connector **4.1.0からクラス名が変わっています**。旧来の`com.snowflake.kafka.connector.SnowflakeSinkConnector`のままだと`Failed to find any class that implements Connector`で失敗します。Snowpipe Streaming専用の`com.snowflake.kafka.connector.SnowflakeStreamingSinkConnector`を指定してください。また、既存のSnowflake Kafka Connector v3からの移行を前提にした互換性チェックがデフォルトで有効になっており、新規構築でも`snowflake.streaming.validate.compatibility.with.classic: "false"`を明示しないと`Config value 'snowflake.streaming.classic.offset.migration' is invalid...`のようなバリデーションエラーで起動に失敗します。
:::

:::message
`${secretsManager:<ARN>:key}`(元の想定)ではなく`${secretsmanager:<シークレット名>:key}`(小文字・シークレット名)にしている点に注意してください。config providerの実装はプレースホルダーをコロンで単純に分割しているため、ARN自体に含まれるコロン(`arn:aws:secretsmanager:ap-northeast-1:...`)を渡すと最初のコロンまでしか読まれず、`secretsmanager:GetSecretValue on resource: arn`のようなAccessDeniedになります。ARNではなくシークレット名(`pg-cdc/debezium-db-user`)を使うことでこの問題を避けられます。
:::

:::message
Amazon MSKの**デフォルトのクラスタ設定は`auto.create.topics.enable=false`**です。カスタムのMSK Configurationを何も指定していない場合、Debeziumが最初にメッセージを送ろうとするトピック(`__debezium-heartbeat.pgdb`や`pgdb.public.orders`)がまだ存在せず、`UNKNOWN_TOPIC_OR_PARTITION`の警告が延々と出続けて(特にハートビートトピックの場合)本来のCDCイベント送信までブロックされることがあります。Kafka Connectのソースコネクタが自前でトピックを作成できる`topic.creation.enable=true`(+`topic.creation.default.*`)を設定することで、ブローカー側の設定を変えずに解決できます。
:::

:::message
`decimal.handling.mode`を指定しないと(デフォルトの`precise`のまま)、`amount`のようなNUMERIC型が`{"scale": 0, "value": "AyA="}`のようなbase64エンコードされたDecimalとしてSnowflakeに届きます。STEP6・STEP7のSQLで単純に`::number`キャストするには`decimal.handling.mode: double`が必要です[^debezium-decimal]。
:::

[^debezium-decimal]: [Debezium connector for PostgreSQL - Decimal values](https://debezium.io/documentation/reference/stable/connectors/postgresql.html#postgresql-decimal-types) にモード一覧の記載があります。

`database.hostname`はSTEP1で作った`DBInstance`を`!GetAtt`で直接参照しています。1ファイルにまとめたことで、他スタックの値をパラメータ経由で受け渡す必要がなくなりました。

`heartbeat.interval.ms`を設定しているのは、対象テーブルの更新頻度が低い場合でもレプリケーションスロットのLSNを定期的に前進させ、WALの滞留を防ぐためです[^debezium-heartbeat]。

[^debezium-heartbeat]: [Debezium connector for PostgreSQL - Heartbeat messages](https://debezium.io/documentation/reference/stable/connectors/postgresql.html#postgresql-heartbeat-messages) に、低頻度更新テーブルではハートビートなしだとLSNが進まずWALが溜まり続けるリスクが明記されています。

ここまでの準備(RDSはテンプレート内から直接参照、MSKのブートストラップブローカー文字列、STEP4で登録した2つのSecrets Manager ARN、Snowflakeアカウント情報)が揃ったら、最後のデプロイでDebezium/Snowflake両コネクタを作成します。

```bash
aws cloudformation deploy \
  --stack-name pg-cdc \
  --template-file cloudformation/postgres-debezium-kafka-snowflake/template.yaml \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
    ProjectName=pg-cdc \
    MskBootstrapServers="$MSK_BOOTSTRAP_SERVERS" \
    DebeziumDbSecretArn="$DEBEZIUM_DB_SECRET_ARN" \
    SnowflakeAccountUrl="https://<account>.snowflakecomputing.com" \
    SnowflakePrivateKeySecretArn="$SNOWFLAKE_KEY_SECRET_ARN"
```

:::message
`aws cloudformation deploy`は、`--parameter-overrides`で**明示的に指定しなかったパラメータをテンプレートのデフォルト値ではなく「前回デプロイ時の値」のまま引き継ぎます**。STEP3でプラグインZIPの中身を差し替えて`DebeziumPluginKey`のデフォルト値を変えても、過去のデプロイで一度でも値が確定していると、明示的に`DebeziumPluginKey=...`を渡さない限り古い値のまま更新されません(プラグインの中身が変わらないため、当然config providerも読み込まれずClassNotFoundExceptionになります)。デプロイのたびに、そのSTEPで関係するパラメータは面倒でも毎回明示的に指定するのが安全です。
:::

:::message
2025年11月に導入されたCloudFormationの事前検証機能(Early Validation)に既知の不具合があり、本記事のテンプレートのように複数の組み込み関数(`Fn::GetAtt` / `Fn::Base64`など)を組み合わせた正当なテンプレートでも`Validation failed with N error(s)`のように誤検知することがあります[^cfn-early-validation]。`aws cloudformation deploy`(内部的にチェンジセットを使う)でこれに遭遇した場合は、`aws cloudformation update-stack --disable-validation`で直接更新することで回避できます(`deploy`と違い、パラメータは`ParameterKey=...,ParameterValue=...`形式のJSON/リストで渡します)。
:::

[^cfn-early-validation]: [CloudFormation now allows for early validation to detect resource conflicts and other issues when creating change sets](https://dev.classmethod.jp/en/articles/cloudformation-early-validation/) がこの機能の概要です。誤検知の実例は[deploy 0.57.1: past the capability fix, now CreateStack fails CFN Early Validation post-transform](https://github.com/spore-host/lagotto/issues/145) などでも報告されています。

デプロイ後、両コネクタが`RUNNING`になっていることを確認します。

```bash
aws kafkaconnect list-connectors --query "connectors[].{name:connectorName,state:connectorState}"
```

CloudWatch Logsのロググループ`/msk-connect/pg-cdc`に、Debezium側のスナップショット完了ログ(`Snapshot ended with SnapshotResult`など)が出ていれば取り込みが動いています。

## STEP6: 動作確認

### スナップショットの確認

コネクタ起動直後、既存の`orders`テーブルの全行が`snapshot.mode=initial`によって一括で流れます。`RECORD_CONTENT:op`が`r`(read = スナップショット)のレコードとしてSnowflakeに入っていることを確認します。

```sql
SELECT RECORD_CONTENT:op::string AS op, COUNT(*)
FROM PG_CDC_DB.RAW.ORDERS_CDC_RAW
GROUP BY op;
```

:::message
`RECORD_CONTENT`は`{"schema": ..., "payload": {...}}`のように`payload`でラップされた形にはなりません。Kafka Connectのフレームワークが`value.converter.schemas.enable=true`のJSONを一度Structへデシリアライズし、Snowflake Kafka Connectorがその**データ部分**(schemaを除いたペイロード相当)をそのままRECORD_CONTENTへ書き込むためです。`op` / `before` / `after`はすべて`RECORD_CONTENT`直下にあります(`RECORD_CONTENT:payload:op`ではなく`RECORD_CONTENT:op`)。
:::

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
  RECORD_CONTENT:op::string        AS op,
  RECORD_CONTENT:before.id::int    AS before_id,
  RECORD_CONTENT:after.id::int     AS after_id,
  RECORD_CONTENT:after.status::string AS after_status,
  RECORD_CONTENT:ts_ms::number     AS ts_ms
FROM PG_CDC_DB.RAW.ORDERS_CDC_RAW
WHERE COALESCE(RECORD_CONTENT:after.id, RECORD_CONTENT:before.id) = 1001
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
    RECORD_CONTENT:op::string AS op,
    COALESCE(RECORD_CONTENT:after.id, RECORD_CONTENT:before.id)::int AS id,
    RECORD_CONTENT:after.status::string AS status,
    RECORD_CONTENT:after.amount::number AS amount,
    RECORD_CONTENT:ts_ms::number AS ts_ms
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
| セキュリティ | DB認証情報・Snowflakeの秘密鍵は必ずSecrets Manager経由(`${secretsmanager:...}`、msk-config-providers経由)で渡し、CloudFormationテンプレートに平文で書かないようにします。`template.yaml`もARNだけをパラメータで受け取る作りにしています |

## おわりに

RDS for PostgreSQL → Debezium(MSK Connect) → Amazon MSK → Snowflake Kafka Connector(MSK Connect) → Snowflakeという構成を、実際にSTEP1から動作確認まで通しで構築しました。
前回のIoT記事と同じくMSK + Snowflake Kafka Connectorの組み合わせですが、ソースがDebeziumになることで、

- スナップショット(初期ロード)とWALベースの継続追跡が1つのコネクタで完結する
- CDCイベントが`before` / `after` / `op`を持つため、単なる追記ではなく「現在値」の再現(UPDATE/DELETEの反映)まで見据えた設計が必要になる

という違いがありました。CloudFormationも前回のTerraformから1ファイル・1スタック構成に変え、VPC/RDSという「土台」から始めてMSK・MSK Connectを追記していく流れにしたことで、どのSTEPでどのリソースが増えるかが1つのファイルの差分として追いやすくなりました。

実際に手を動かしてみると、公式ドキュメントのサンプルだけでは気づきにくい落とし穴がいくつもありました。特に大きかったのは次の3つです。

- **`${secretsManager:...}`はMSK Connectの組み込み機能ではなかった** — OSSのconfig provider(msk-config-providers)をプラグインZIPに同梱し、Worker Configurationで明示的に有効化する必要があり、しかもシークレットはARNではなく名前で参照する必要がありました
- **MSKのデフォルト設定は`auto.create.topics.enable=false`** — Debeziumのハートビートトピックがブロックされ、一見コネクタは`RUNNING`なのにCDCイベントがまったく流れない状態にハマりました
- **ライブラリのメジャーバージョンアップで前提が変わる** — Snowflake Kafka Connector 4.1.0でコネクタクラス名が変わり、KafkaConnectVersionも`2.7.1`では新しいDebeziumプラグインをロードできませんでした

次は実際にこの構成でレイテンシや障害時の挙動(コネクタ再起動時にスロットから正しく再開できるか等)を検証した記事を書く予定です。
