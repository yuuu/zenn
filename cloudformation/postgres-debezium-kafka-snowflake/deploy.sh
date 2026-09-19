#!/usr/bin/env bash
# PostgreSQL -> Debezium -> MSK -> Snowflake 検証環境の構築手順(参考スクリプト)。
# 上から順に一つずつ実行してください。一括実行を想定したものではありません。
# 事前に `aws configure` 等でCLIの認証情報を設定しておくこと。

set -euo pipefail

REGION="ap-northeast-1"
PROJECT_NAME="pg-cdc"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

# ---------------------------------------------------------------------------
# STEP1: ネットワーク(VPC / サブネット / SG / NAT / 踏み台)
# ---------------------------------------------------------------------------
aws cloudformation deploy \
  --region "$REGION" \
  --stack-name "${PROJECT_NAME}-network" \
  --template-file 01-network.yaml \
  --parameter-overrides ProjectName="$PROJECT_NAME" \
  --capabilities CAPABILITY_NAMED_IAM

# ---------------------------------------------------------------------------
# STEP2: RDS for PostgreSQL
# ---------------------------------------------------------------------------
aws cloudformation deploy \
  --region "$REGION" \
  --stack-name "${PROJECT_NAME}-rds" \
  --template-file 02-rds.yaml \
  --parameter-overrides ProjectName="$PROJECT_NAME"

DB_HOST="$(aws cloudformation describe-stacks --region "$REGION" \
  --stack-name "${PROJECT_NAME}-rds" \
  --query "Stacks[0].Outputs[?OutputKey=='DBInstanceEndpointAddress'].OutputValue" --output text)"
DB_MASTER_SECRET_ARN="$(aws cloudformation describe-stacks --region "$REGION" \
  --stack-name "${PROJECT_NAME}-rds" \
  --query "Stacks[0].Outputs[?OutputKey=='MasterUserSecretArn'].OutputValue" --output text)"

echo "RDSエンドポイント: $DB_HOST"
echo "マスターパスワードは Secrets Manager ($DB_MASTER_SECRET_ARN) を参照してください"

# ---------------------------------------------------------------------------
# STEP2.5: 踏み台(SSM)経由でRDSへ接続し、debeziumユーザー/Publicationを作成
# ---------------------------------------------------------------------------
# BASTION_ID="$(aws cloudformation describe-stacks --region "$REGION" \
#   --stack-name "${PROJECT_NAME}-network" \
#   --query "Stacks[0].Outputs[?OutputKey=='BastionInstanceId'].OutputValue" --output text)"
#
# aws ssm start-session --region "$REGION" --target "$BASTION_ID" \
#   --document-name AWS-StartPortForwardingSessionToRemoteHost \
#   --parameters "{\"host\":[\"$DB_HOST\"],\"portNumber\":[\"5432\"],\"localPortNumber\":[\"15432\"]}"
#
# 別ターミナルで:
#   psql "host=127.0.0.1 port=15432 dbname=appdb user=postgres"
#   -- 以下をRDS上で実行 --
#   -- CREATE USER debezium WITH REPLICATION PASSWORD '<生成したパスワード>';
#   -- GRANT rds_replication TO debezium;
#   -- GRANT SELECT ON public.orders TO debezium;
#   -- CREATE PUBLICATION dbz_publication FOR TABLE public.orders;

# Debezium用パスワードをSecrets Managerへ登録(コネクタ設定の ${secretsManager:...} から参照)
# DEBEZIUM_DB_PASSWORD="<上でCREATE USERしたパスワード>"
# DEBEZIUM_DB_SECRET_ARN="$(aws secretsmanager create-secret \
#   --region "$REGION" \
#   --name "${PROJECT_NAME}/debezium-db-user" \
#   --secret-string "{\"password\":\"${DEBEZIUM_DB_PASSWORD}\"}" \
#   --query ARN --output text)"

# ---------------------------------------------------------------------------
# STEP3: Amazon MSK
# ---------------------------------------------------------------------------
aws cloudformation deploy \
  --region "$REGION" \
  --stack-name "${PROJECT_NAME}-msk" \
  --template-file 03-msk.yaml \
  --parameter-overrides ProjectName="$PROJECT_NAME"
# MSKクラスタの作成には20〜40分程度かかる

# ---------------------------------------------------------------------------
# STEP4: MSK Connectプラグイン用S3バケット
# ---------------------------------------------------------------------------
BUCKET_NAME="${PROJECT_NAME}-connect-plugins-${ACCOUNT_ID}"

aws cloudformation deploy \
  --region "$REGION" \
  --stack-name "${PROJECT_NAME}-mskconnect-bucket" \
  --template-file 04-mskconnect-bucket.yaml \
  --parameter-overrides ProjectName="$PROJECT_NAME" BucketName="$BUCKET_NAME"

# ---------------------------------------------------------------------------
# STEP4.5: プラグインZIPを作成してアップロード
# ---------------------------------------------------------------------------
# DEBEZIUM_VERSION=3.0.8  # https://debezium.io/releases/ で最新の安定版を確認
# curl -fsSL -o debezium-connector-postgres.tar.gz \
#   "https://repo1.maven.org/maven2/io/debezium/debezium-connector-postgres/${DEBEZIUM_VERSION}/debezium-connector-postgres-${DEBEZIUM_VERSION}-plugin.tar.gz"
# mkdir -p build/debezium-connector-postgres
# tar xzf debezium-connector-postgres.tar.gz -C build/debezium-connector-postgres --strip-components=1
# (cd build && zip -r ../debezium-connector-postgres.zip debezium-connector-postgres)
# aws s3 cp debezium-connector-postgres.zip "s3://${BUCKET_NAME}/debezium-connector-postgres.zip"
#
# SNOWFLAKE_CONNECTOR_VERSION=3.2.2
# curl -fsSL -o snowflake-kafka-connector.jar \
#   "https://repo1.maven.org/maven2/com/snowflake/snowflake-kafka-connector/${SNOWFLAKE_CONNECTOR_VERSION}/snowflake-kafka-connector-${SNOWFLAKE_CONNECTOR_VERSION}.jar"
# mkdir -p build/snowflake-kafka-connector
# cp snowflake-kafka-connector.jar build/snowflake-kafka-connector/
# (cd build && zip -r ../snowflake-kafka-connector.zip snowflake-kafka-connector)
# aws s3 cp snowflake-kafka-connector.zip "s3://${BUCKET_NAME}/snowflake-kafka-connector.zip"

# ---------------------------------------------------------------------------
# STEP5: MSK Connectカスタムプラグイン登録
# ---------------------------------------------------------------------------
aws cloudformation deploy \
  --region "$REGION" \
  --stack-name "${PROJECT_NAME}-mskconnect-plugins" \
  --template-file 05-mskconnect-plugins.yaml \
  --parameter-overrides ProjectName="$PROJECT_NAME"

# ---------------------------------------------------------------------------
# STEP6: Snowflake側の受け皿(snow CLIで実行。別途 snowflake.sql 等を用意)
# ---------------------------------------------------------------------------
# snow sql -f snowflake_setup.sql
#
# キーペア生成 & Secrets Manager登録:
#   openssl genrsa 2048 | openssl pkcs8 -topk8 -inform PEM -out kafka_connector_key.p8 -nocrypt
#   openssl rsa -in kafka_connector_key.p8 -pubout -out kafka_connector_key.pub
#   PRIVATE_KEY_BODY="$(grep -v 'PRIVATE KEY' kafka_connector_key.p8 | tr -d '\n')"
#   SNOWFLAKE_KEY_SECRET_ARN="$(aws secretsmanager create-secret \
#     --region "$REGION" \
#     --name "${PROJECT_NAME}/snowflake-kafka-user" \
#     --secret-string "{\"private_key\":\"${PRIVATE_KEY_BODY}\"}" \
#     --query ARN --output text)"

# ---------------------------------------------------------------------------
# STEP7: MSK Connectコネクタ(Debezium Source / Snowflake Sink)を起動
# ---------------------------------------------------------------------------
# aws cloudformation deploy \
#   --region "$REGION" \
#   --stack-name "${PROJECT_NAME}-mskconnect-connectors" \
#   --template-file 06-mskconnect-connectors.yaml \
#   --capabilities CAPABILITY_NAMED_IAM \
#   --parameter-overrides \
#     ProjectName="$PROJECT_NAME" \
#     DebeziumDbHost="$DB_HOST" \
#     DebeziumDbSecretArn="$DEBEZIUM_DB_SECRET_ARN" \
#     SnowflakeAccountUrl="https://<account>.snowflakecomputing.com" \
#     SnowflakePrivateKeySecretArn="$SNOWFLAKE_KEY_SECRET_ARN"

echo "ここまででVPC / RDS / MSK / MSK Connectプラグイン登録が完了しています。"
echo "STEP2.5・4.5・6・7はコメントアウトされたコマンドを、値を埋めながら手動で実行してください。"
