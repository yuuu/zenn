---
title: "Amazon MSK のトピックを Karafka(Ruby)で購読してファンアウトさせる"
emoji: "❄️"
type: "tech" # tech: 技術記事 / idea: アイデア
topics:
  - aws
  - snowflake
  - kafka
  - ruby
  - iot
published: false
publication_name: "fusic"
---

## はじめに

前回の記事で、M5Stack + ENV3ユニットで計測した温度・湿度・気圧データを、AWS IoT Core → Amazon MSK → Snowflake の経路でTerraformで構築しました。

<!-- TODO: 前回記事(MSK版)の公開後にURLを差し込む -->

このとき、AWS IoT Coreが受け取ったメッセージをMSKのトピック `env-sensor-telemetry` へ流し、MSK Connect + Snowflake Kafka Connector(コンシューマグループ `connect-snowflake-env-sensor-sink`)でSnowflakeへ蓄積しました。

Kafkaを挟む利点のひとつがファンアウトです。同じトピックを別のコンシューマグループから購読すれば、Snowflakeへの蓄積とは独立した処理を足せます。片方の障害や再起動は他方に影響しません。

この記事では、Ruby製のKafkaフレームワーク [Karafka](https://karafka.io/) で「ダッシュボード用の簡易コンシューマ」を書き、MSK Connectと並んで同じトピックを購読します。

コードは前回と同じリポジトリの `karafka/` にあります。

https://github.com/yuuu/stream-iot-data-to-snowflake

## 前提

- 前回のMSK構成(`terraform/kafka/`)が `apply` 済みで、トピック `env-sensor-telemetry` にデータが流れていること
- Ruby実行環境(検証時は Ruby 4.x + Bundler)
- Karafka用のSASL/SCRAMユーザー `AmazonMSK_env-sensor_karafka` がクラスタに登録済みであること
  - `terraform/kafka/` の `scram_users` に `karafka` を含めておけば `aws_msk_scram_secret_association` まで作られます
- MSKはVPC内リソースなので、ローカルから接続するにはVPC内へ到達できる経路が必要です。前回立てた踏み台EC2へのSSHポートフォワードを使います

## Karafka プロジェクト

`karafka/` の中身はシンプルです。

```ruby:karafka/Gemfile
source "https://rubygems.org"

gem "karafka", "~> 2.4"
gem "dotenv", "~> 3.1" # 認証情報は .env(gitignore)から読む
```

MSKへの接続設定と、コンシューマグループ・ルーティングを `karafka.rb` に書きます。コンシューマグループIDを MSK Connect の `connect-*` と別にするのがファンアウトの肝です。

```ruby:karafka/karafka.rb(抜粋)
class KarafkaApp < Karafka::App
  setup do |config|
    config.kafka = {
      "bootstrap.servers": ENV.fetch("KAFKA_BOOTSTRAP"),
      "security.protocol": "sasl_ssl",
      "sasl.mechanisms": "SCRAM-SHA-512",
      "sasl.username": ENV.fetch("KAFKA_SASL_USERNAME"),
      "sasl.password": ENV.fetch("KAFKA_SASL_PASSWORD"),
      "ssl.ca.location": ENV.fetch("KAFKA_SSL_CA_LOCATION", "/etc/ssl/cert.pem"),
      "auto.offset.reset": "earliest"
    }

    # MSK Connect の connect-snowflake-env-sensor-sink とは別のグループにする
    config.group_id = "dashboard-consumer-group"
  end

  routes.draw do
    topic "env-sensor-telemetry" do
      consumer EnvSensorConsumer
    end
  end
end
```

コンシューマは受信JSONをパースして1件ずつログ出力し、`device_id` 別の件数と最新値をメモリに集計するだけの簡易実装です(ダッシュボードの入り口のイメージ)。

```ruby:karafka/app/consumers/env_sensor_consumer.rb(抜粋)
class EnvSensorConsumer < Karafka::BaseConsumer
  def consume
    messages.each do |message|
      payload = JSON.parse(message.raw_payload)
      Karafka.logger.info(
        "[recv] p#{message.partition} o#{message.offset} " \
        "device_id=#{payload['device_id']} temp=#{payload['temperature']} " \
        "event_ts=#{payload['event_timestamp']}"
      )
    end
  end
end
```

SASL/SCRAMの認証情報は `AmazonMSK_env-sensor_karafka` シークレットから取り出して `.env`(gitignore対象)へ書き込みます。リポジトリの `bin/load-secret.sh` が行います。

```bash
cd karafka
bundle install

AWS_PROFILE=<profile> bash bin/load-secret.sh   # Secrets Manager から .env を生成
# もしくは env.sample をコピーして手で埋める

bundle exec karafka server
```

## ローカルからMSKへ届かせる(SSHポートフォワード)

ここが少し手間です。MSKはVPC内にあり、ブローカーは自分をFQDNで広告します(`b-1.envsensorkafka....amazonaws.com:9096` など)。クライアントは最初のブローカーに繋いだあと、広告されたFQDNで各ブローカーへ繋ぎ直します。

そのため `ssh -L 9096:b-1...:9096` を1本張るだけでは足りません。ブローカーの数だけローカルアドレスを用意して各9096をポートフォワードし、`/etc/hosts` で各FQDNをそのアドレスへ向けます。macOSなら以下の要領です(いずれも `sudo` が必要)。

```bash
# ループバックエイリアスを3つ足す
for ip in 127.0.0.2 127.0.0.3 127.0.0.4; do sudo ifconfig lo0 alias $ip up; done
```

```:/etc/hosts に追記
127.0.0.2 b-1.envsensorkafka.xxxx.kafka.ap-northeast-1.amazonaws.com
127.0.0.3 b-2.envsensorkafka.xxxx.kafka.ap-northeast-1.amazonaws.com
127.0.0.4 b-3.envsensorkafka.xxxx.kafka.ap-northeast-1.amazonaws.com
```

```bash
ssh -i terraform/kafka/certs/bastion_ed25519.pem -N \
  -L 127.0.0.2:9096:b-1.envsensorkafka.xxxx...:9096 \
  -L 127.0.0.3:9096:b-2.envsensorkafka.xxxx...:9096 \
  -L 127.0.0.4:9096:b-3.envsensorkafka.xxxx...:9096 \
  ec2-user@<bastion-ip>
```

リポジトリの `terraform/kafka/scripts/lo-setup.sh` / `lo-teardown.sh` が、この `/etc/hosts` 追記とループバックエイリアスの出し入れを行います(ブローカーFQDNは引数、または `terraform output` から取得)。

:::message
JDK 24以降ではSecurity Managerが撤廃され、Kafkaクライアント(JVM実装)のSASL認証が `getSubject is not supported` で失敗します。ローカルでJVM版の `kafka-console-consumer` などを使う場合はJDK 17系を使ってください。Karafkaはlibrdkafka(C実装)なので、この問題の影響を受けません。上記のトンネル経由でそのまま動きます。
:::

## ファンアウトを確認する

Karafkaを起動した状態で、テストメッセージを3件publishします。

```bash
aws iot-data publish \
  --endpoint-url https://<IoTエンドポイント> \
  --topic "env-sensor/FANOUT001" \
  --payload '{"temperature": 17.1, "humidity": 40.0, "pressure": 1005.0}' \
  --cli-binary-format raw-in-base64-out
```

Karafkaのログに出ますし、同時にSnowflakeにも行が増えます。

```
# Karafka
[recv] p1 o532 device_id=FANOUT001 temp=17.1 event_ts=1788073906361
[recv] p0 o4   device_id=FANOUT002 temp=17.2 event_ts=1788073909465
[recv] p0 o5   device_id=FANOUT003 temp=17.3 event_ts=1788073912641
```

踏み台から `kafka-consumer-groups.sh --describe` で両グループのオフセットを見ると、独立して管理されています。

```
GROUP                              P  CURRENT-OFFSET  LOG-END-OFFSET  LAG
dashboard-consumer-group           0  6               6               0
dashboard-consumer-group           1  534             534             0
dashboard-consumer-group           2  2               2               0
connect-snowflake-env-sensor-sink  0  6               6               0
connect-snowflake-env-sensor-sink  1  534             534             0
connect-snowflake-env-sensor-sink  2  2               2               0
```

`dashboard-consumer-group`(Karafka)と `connect-snowflake-env-sensor-sink`(MSK Connect)が、同じ `env-sensor-telemetry` を別々の `__consumer_offsets` エントリでオフセット管理しています。

## おわりに

Karafkaで書いたダッシュボード用コンシューマが、MSK Connectとは独立したコンシューマグループで同じトピックをファンアウト購読できました。

- Karafkaを止めても再起動しても、自分のコミット位置から再開するだけで、Snowflakeへの取り込みには影響しません。
- 逆にSnowflake側のコネクタを作り直しても、Karafka側のオフセットは無関係です。
- リプレイもコンシューマグループ単位で独立して行えます。

「IoTのストリームを1本の基盤として持ち、そこから蓄積・リアルタイム処理・再処理を必要なだけぶら下げる」というのが、Firehose直結にはないKafka構成の強みです。

コードは以下で公開しています。

https://github.com/yuuu/stream-iot-data-to-snowflake
