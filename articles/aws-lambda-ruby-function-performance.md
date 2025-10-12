---
title: "AWS Lambda(Ruby)の起動が遅い…ボトルネックを特定するまでの道のり"
emoji: "💎"
type: "tech" # tech: 技術記事 / idea: アイデア
topics:
  - AWS
  - lambda
  - Ruby
published: true
published_at: "2025-10-14 06:00"
publication_name: "fusic"
---

壮大なタイトルではありますが、先に結論を書くと、

```ruby
require 'aws-sdk'
```

この部分を

```ruby
require 'aws-sdk-sqs'
```

のように、 **使用するモジュール(今回で言うとSQS)に絞る** ことで起動が速くなりました。

そして、もう一つは **Rubyを3.2→3.4に上げること** です。これも高速化に寄与しました。

ポイントとしてはこの2点なのですが、この結論に至るまでに試したことや、他にもこんなアプローチがあったな、など思うことがあったので記事にしてみました。

## 起こっていた問題

弊社内で利用しているSlack Appにて呼び出している「Amazon API Gateway + AWS Lambdaで作成したHTTPSエンドポイント」が、レスポンスを3秒以内に返せていませんでした。

Slack Appで提供しているのはSlash Commandで、3秒以内 [^1] にレスポンスが返ってこないと次のようなタイムアウトエラーが表示されます。

![](https://storage.googleapis.com/zenn-user-upload/0b2ebba635cc-20251012.png)

調査開始時点では、AWS LambdaのランタイムにRuby 3.2を使用していました。

## 調べたこと

### Amazon CloudWatch Logsのログを見る

まずは現状のログを確認します。今回はAWS SAM CLIを使って開発しているので `sam logs` で簡単に確認できます。

```sh
2025-10-12T11:05:56.076000 INIT_START Runtime Version: ruby:3.2.v88        Runtime Version ARN: arn:aws:lambda:ap-northeast-1::runtime:6cca5cd7fcc10ba69d4c8f2c974eb5357c499f412222223275153eb457776f7a
2025-10-12T11:05:56.808000 Ignoring bigdecimal-3.3.1 because its extensions are not built. Try: gem pristine bigdecimal --version 3.3.1
2025-10-12T11:05:57.145000 START RequestId: 434b8d14-c2d8-4153-a036-c249874f1bf0 Version: $LATEST
# ...省略
2025-10-12T11:06:02.041000 END RequestId: 434b8d14-c2d8-4153-a036-c249874f1bf0
2025-10-12T11:06:02.041000 REPORT RequestId: 434b8d14-c2d8-4153-a036-c249874f1bf0  Duration: 4895.04 ms    Billed Duration: 5961 ms        Memory Size: 128 MB     Max Memory Used: 78 MB  Init Duration: 1065.68 ms
```

INIT [^2] に約1秒、START〜ENDで約5秒かかっていますね。メモリは78/128MBとなっているので、メモリが枯渇しているといったことはなさそうです。

### Rubyのバージョンを3.2→3.4にアップグレードする

使用しているAWS LambdaのランタイムはRuby 3.2でした。まだサポート期間内ではありますが、現在ではRuby 3.4も使えるようになっています。

https://docs.aws.amazon.com/ja_jp/lambda/latest/dg/lambda-ruby.html

来年の春にはEOLになってしまうのでどちらにせよRuby 3.4に上げる必要がありますし、Ruby 3.0以降はバージョンを上げて動作に支障をきたすことは少ないです。

というわけでまずは脳死でRubyのバージョンを上げてみました。

```diff yaml:template.yaml
# 省略

Resources:
  CreateNikoFunction:
    Type: AWS::Serverless::Function # More info about Function Resource: https://github.com/awslabs/serverless-application-model/blob/master/versions/2016-10-31.md#awsserverlessfunction
    Properties:
      CodeUri: create_niko/
      Handler: app.lambda_handler
-      Runtime: ruby3.2
+      Runtime: ruby3.4

# 省略
```

ログを見てみましょう。

```sh
2025-10-12T11:13:03.067000 INIT_START Runtime Version: ruby:3.4.v48        Runtime Version ARN: arn:aws:lambda:ap-northeast-1::runtime:cf4e6290512ae5cfeb745b415f3e245ce6eedaee217d27bb4a18d813697cb27d
2025-10-12T11:13:03.770000 Ignoring bigdecimal-3.3.1 because its extensions are not built. Try: gem pristine bigdecimal --version 3.3.1
2025-10-12T11:13:03.895000 START RequestId: 4dec978e-10e5-48a7-b66f-3286dda89d33 Version: $LATEST
# ...省略
2025-10-12T11:13:06.190000 END RequestId: 4dec978e-10e5-48a7-b66f-3286dda89d33
2025-10-12T11:13:06.190000 REPORT RequestId: 4dec978e-10e5-48a7-b66f-3286dda89d33  Duration: 2293.74 ms    Billed Duration: 3119 ms        Memory Size: 128 MB     Max Memory Used: 75 MB  Init Duration: 824.77 ms
```

ここは正直予想外だったのですが、速くはなっています。Ruby自体が高速化したのか、ランタイムOSの違い(Amazon Linux2 → Amazon Linux 2023)なのかはわかりませんが、約2.5秒縮みました。

まだトータル3秒は切れていないので、調査を続けます。

### lambda_handlerの処理時間を測ってみる

ログで処理時間は確認できているのであまり意味のない作業ではありますが、念の為コード上でも処理時間を測ってみることにしました。雑に `lambda_handler` の最初から最後まででどれくらいの時間がかかっているか計測します。

計測コードは次のようなdebug printを差し込む方法です。 **これは後でもっと良い方法があったことに気づいたので後述します。**

```diff ruby:app.rb
+require 'time'

# 省略

def lambda_handler(event:, context:)
+  puts "START: #{Time.now.iso8601}"

  # 省略

+  puts "END: #{Time.now.iso8601}"
end
```

実行結果は次の通りです。

```sh
2025-10-12T11:22:14.139000 INIT_START Runtime Version: ruby:3.4.v48        Runtime Version ARN: arn:aws:lambda:ap-northeast-1::runtime:cf4e6290512ae5cfeb745b415f3e245ce6eedaee217d27bb4a18d813697cb27d
2025-10-12T11:22:14.859000 Ignoring bigdecimal-3.3.1 because its extensions are not built. Try: gem pristine bigdecimal --version 3.3.1
2025-10-12T11:22:14.995000 START RequestId: 69b5eff3-3b37-4493-af1b-b2c54e1cd59f Version: $LATEST
2025-10-12T11:22:14.996000 START: 2025-10-12T20:22:14+09:00
# ...省略
2025-10-12T11:22:17.406000 END: 2025-10-12T20:22:17+09:00
2025-10-12T11:22:17.427000 END RequestId: 69b5eff3-3b37-4493-af1b-b2c54e1cd59f
2025-10-12T11:22:17.427000 REPORT RequestId: 69b5eff3-3b37-4493-af1b-b2c54e1cd59f  Duration: 2431.61 ms    Billed Duration: 3285 ms        Memory Size: 128 MB     Max Memory Used: 75 MB  Init Duration: 852.76 ms
```

`Time.now.iso8601` が秒単位での表示のため、ms単位での実行時間がわからないですね。とはいえざっくり3秒程度かかっていることの裏付けは取れました。

### Lambda SnapStartの導入を検討

この問題についてSlackで話しているときに、社内のエンジニアからおすすめされた方法です。

https://docs.aws.amazon.com/ja_jp/lambda/latest/dg/snapstart.html

> Lambda SnapStart は通常、関数コードを変更することなく、わずか 1 秒未満の起動パフォーマンスを提供できます。SnapStart を使用すると、リソースをプロビジョニングしたり、複雑なパフォーマンス最適化を実装したりすることなく、応答性が高くスケーラブルなアプリケーションを簡単にビルドできます。

と記載されています。すごい！

しかし、ドキュメントをよく読むと次のような記載があります。

:::message
SnapStart は、次の Lambda マネージドランタイムで使用できます。

- Java 11 以降
- Python 3.12 以降
- .NET 8 以降。Lambda Annotations framework for .NET を使用している場合は、Amazon.Lambda.Annotations バージョン 1.6.0 以降にアップグレードして、SnapStart との互換性を確保してください。

他のマネージドランタイム (nodejs22.x や ruby3.4 など)、OS 専用ランタイム、およびコンテナイメージはサポートされていません。
:::

というわけで、ランタイムにRuby 3.4を使っているとLambda SnapStartは導入できないようです。残念。

### 思い切ってLambda関数を空っぽにしてみる

コールドスタートにかかる時間を改善できないとなると「RubyでLambda関数を書く限りこれ以上は速くならないのでは？」という気持ちになってきました。

そこで、Lambda関数の中身をほぼ空っぽにして、最速でどの程度の処理時間となるのか計測してみることにしました。

Lambda関数の中身を以下のようにします。レスポンスを返すのみです。

```ruby:app.rb
def lambda_handler(event:, context:)
  { statusCode: 200, body: '' }
end
```

結果は次のようになりました。

```sh
2025-10-12T11:37:10.870000 INIT_START Runtime Version: ruby:3.4.v48        Runtime Version ARN: arn:aws:lambda:ap-northeast-1::runtime:cf4e6290512ae5cfeb745b415f3e245ce6eedaee217d27bb4a18d813697cb27d
2025-10-12T11:37:11.097000 START RequestId: 8491a07b-8ff5-48c7-8a0f-518cd9b1efa6 Version: $LATEST
2025-10-12T11:37:11.111000 END RequestId: 8491a07b-8ff5-48c7-8a0f-518cd9b1efa6
2025-10-12T11:37:11.111000 REPORT RequestId: 8491a07b-8ff5-48c7-8a0f-518cd9b1efa6  Duration: 13.93 ms      Billed Duration: 237 ms Memory Size: 128 MB     Max Memory Used: 36 MB  Init Duration: 222.70 ms
```

**えっ、速い。** Durationが小さいのは予想どおりですが、Init Durationが約1/4になっている点が意外でした。コードが小さくなるとINITの処理時間も短くなる...？

### AWS SDKをモジュール単位でrequireする

空っぽのLambda関数での計測結果を踏まえ、INIT処理について調べてみたところ次の記事にたどり着きました。

https://aws.amazon.com/jp/blogs/news/operating-lambda-performance-optimization-part-2/

ポイントはこの部分です。

:::message
関数は必要なライブラリと依存関係のみをインポートすることが重要です。たとえば、AWS SDK で Amazon DynamoDBのみを使用する場合は、SDK 全体ではなく個別のサービスを要求できます。
(中略)
テストでは、AWS SDK 全体ではなく DynamoDB ライブラリのみとすると、インポートが 125 ミリ秒速くなりました。
:::

「まさにこれじゃん！」と思い、コードを次のように修正して計測してみました。

```diff ruby:app.rb
require 'uri'
require 'date'
require 'json'
-require 'aws-sdk'
+require 'aws-sdk-sqs'

# 省略
```

ログを見てみましょう。

```sh
2025-10-12T11:30:01.193000 INIT_START Runtime Version: ruby:3.4.v48        Runtime Version ARN: arn:aws:lambda:ap-northeast-1::runtime:cf4e6290512ae5cfeb745b415f3e245ce6eedaee217d27bb4a18d813697cb27d
2025-10-12T11:30:01.599000 Ignoring bigdecimal-3.3.1 because its extensions are not built. Try: gem pristine bigdecimal --version 3.3.1
2025-10-12T11:30:01.674000 START RequestId: 5ac800bf-1dac-4885-9975-e7b0bc9494b2 Version: $LATEST
# ...省略
2025-10-12T11:30:03.422000 END RequestId: 5ac800bf-1dac-4885-9975-e7b0bc9494b2
2025-10-12T11:30:03.422000 REPORT RequestId: 5ac800bf-1dac-4885-9975-e7b0bc9494b2  Duration: 1748.24 ms    Billed Duration: 2226 ms        Memory Size: 128 MB     Max Memory Used: 69 MB  Init Duration: 476.82 ms
```

Init Durationも短くなりましたし、Durationも短くなりました。これで3秒の壁は無事突破できたことになります。

Durationが短くなった要因は不明ですが、取り込むAWS SDKがコンパクトになったことで、メソッド探索等が全体的に速くなった？と推測しています。

## 振り返り

### Rubyでの処理時間の計測にはBenchmarkを使うべき

処理時間を計測するときに雑に `Time.now.iso8601` を用いましたが、Rubyには `Benchmark` というクラスが用意されています。これを用いると、処理時間をより簡単・正確に計測できます。

```diff ruby:app.rb
require 'uri'
require 'date'
require 'json'
+require 'benchmark'
+
+time = Benchmark.realtime do
require 'aws-sdk'
+end
+puts "'require aws-sdk' time=#{time}s"
```

ログを見るとINITに0.7秒かかっていることが一目瞭然です。Benchmarkを使っていろいろな箇所を計測する習慣をつけるようにしましょう。

```sh
2025-10-12T11:59:38.949000 INIT_START Runtime Version: ruby:3.4.v48        Runtime Version ARN: arn:aws:lambda:ap-northeast-1::runtime:cf4e6290512ae5cfeb745b415f3e245ce6eedaee217d27bb4a18d813697cb27d
2025-10-12T11:59:39.761000 Ignoring bigdecimal-3.3.1 because its extensions are not built. Try: gem pristine bigdecimal --version 3.3.1
2025-10-12T11:59:39.886000 'require aws-sdk' time=0.7275828179999999s
2025-10-12T11:59:39.893000 START RequestId: d6b17538-214f-469e-84c0-d81abd49b2e7 Version: $LATEST
# ...省略
2025-10-12T11:59:42.295000 END RequestId: d6b17538-214f-469e-84c0-d81abd49b2e7
2025-10-12T11:59:42.295000 REPORT RequestId: d6b17538-214f-469e-84c0-d81abd49b2e7  Duration: 2401.24 ms    Billed Duration: 3340 ms        Memory Size: 128 MB     Max Memory Used: 75 MB  Init Duration: 938.48 ms
```

### YJIT

RubyではYJITと呼ばれる機能が存在します。この機能はAWS Lambdaでも使用することができます。

https://docs.aws.amazon.com/ja_jp/lambda/latest/dg/lambda-ruby.html#ruby-yjit

次のように環境変数を追加すればOKです。

```diff yaml:template.yaml
      Environment:
        Variables:
          SLACK_TOKEN: !Ref SlackAppToken
          QUEUE_NAME: !GetAtt CreateNikoQueue.QueueName
          TZ: Asia/Tokyo
+          RUBY_YJIT_ENABLE: "1"
```

有効化されたことを確認するため、Rubyのコードにも1行追加をしておきます。

```diff ruby:app.rb
require 'uri'
require 'date'
require 'json'
require 'aws-sdk-sqs'

+puts "YJIT ENABLED: #{RubyVM::YJIT.enabled?()}"
```

結果はこのようになりました。

```sh
2025-10-12T12:03:54.734000 INIT_START Runtime Version: ruby:3.4.v48        Runtime Version ARN: arn:aws:lambda:ap-northeast-1::runtime:cf4e6290512ae5cfeb745b415f3e245ce6eedaee217d27bb4a18d813697cb27d
2025-10-12T12:03:55.252000 Ignoring bigdecimal-3.3.1 because its extensions are not built. Try: gem pristine bigdecimal --version 3.3.1
2025-10-12T12:03:55.351000 YJIT ENABLED: true
2025-10-12T12:03:55.357000 START RequestId: 5ee15a53-bd19-4118-8750-ee7e837ed3cd Version: $LATEST
# ...省略
2025-10-12T12:03:57.989000 END RequestId: 5ee15a53-bd19-4118-8750-ee7e837ed3cd
2025-10-12T12:03:57.990000 REPORT RequestId: 5ee15a53-bd19-4118-8750-ee7e837ed3cd  Duration: 2632.14 ms    Billed Duration: 3251 ms        Memory Size: 128 MB     Max Memory Used: 71 MB  Init Duration: 618.68 ms
```

残念ながら遅くなっています。今回のような単発処理ではコンパイルのオーバーヘッドの方が大きく、かえって遅くなってしまったようです。

同じ処理を繰り返し呼び出すようなLambda関数であれば、性能向上に寄与する可能性はあります。

## まとめ

以上がボトルネックを明らかにするまでに私が試したアプローチです。特に目新しいことはしていなくて、ひたすら計測と試行錯誤を繰り返す泥臭い作業ですね。

AWS LambdaのRubyランタイムを使っている方の参考になれば幸いです。

[^1]: https://docs.slack.dev/tools/java-slack-sdk/ja-jp/guides/slash-commands/
[^2]: https://docs.aws.amazon.com/ja_jp/lambda/latest/dg/lambda-runtime-environment.html
