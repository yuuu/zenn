---
title: "AWS Lambda with RubyでSlackからのリクエストを検証する方法"
emoji: "✅"
type: "tech" # tech: 技術記事 / idea: アイデア
topics:
  - "aws"
  - "lambda"
  - "ruby"
  - "slack"
published: true
---

Amazon API Gateway + AWS Lambdaで構築したAPIで、Slackからのリクエストを受ける際、そのリクエストがSlackからのリクエストかどうか検証する方法に悩んだのでメモ。

LambdaのランタイムはRuby 3.2を使用している前提です。

## 使用するRuby Gem

以下のRuby Gemを使用します。

```ruby:Gemfile
gem 'rack'
gem 'slack-ruby-client'
```

## 環境変数

https://api.slack.com/apps へアクセスし、自分が登録しているAppの `Basic Infomation` を開きます。

`Signing Secret` に表示されている文字列をコピーして、AWS Lambdaの環境変数 `SLACK_SIGNING_SECRET` にセットしておきます。
AWS SAMを使うのであればテンプレートに以下のように記述します。

```yaml:template.yaml
# 省略

Parameters: # ここを追加
  SlackSigningSecret:
    Type: String
    Description: Slack Signing Secret

Resources:
  WorldClockFunction:
    Type: AWS::Serverless::Function
    Properties:
      CodeUri: hello_world/
      Handler: app.lambda_handler
      Runtime: ruby3.2
      Environment: # ここを追加
        Variables:
          SLACK_SIGNING_SECRET: !Ref SlackSigningSecret

# 省略
```

## Rubyのソースコード

以下のようなソースコードを実行することでリクエストを検証することができます。

検証に失敗すると例外が `raise` されます。

```ruby:app.rb
require 'slack-ruby-client'
require 'rack'

def lambda_handler(event:, context:)
  env = {
    'rack.input' => StringIO.new(event['body']),
    'HTTP_X_SLACK_REQUEST_TIMESTAMP' => event.dig('headers', 'X-Slack-Request-Timestamp'),
    'HTTP_X_SLACK_SIGNATURE' => event.dig('headers', 'X-Slack-Signature')
  }
  req = Rack::Request.new(env)
  slack_request = Slack::Events::Request.new(req)
  slack_request.verify!

  # 以降省略
end
```
