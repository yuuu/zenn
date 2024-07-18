---
title: "IoTと生成AIを融合！ SORACOM Fluxファーストレビュー"
emoji: "⚡"
type: "tech" # tech: 技術記事 / idea: アイデア
topics:
  - SORACOM
  - SORACOMFlux
  - IoT
  - 生成AI
published: true
published_at: "2024-07-18 22:40"
publication_name: "fusic"
---

昨日開催された[SORACOM Discovery 2024](https://discovery.soracom.jp/2024/)で、SORACOMの新サービスである[SORACOM Flux](https://soracom.jp/services/flux/)が発表されました。

https://soracom.jp/services/flux/

このサービスは今後のIoTシステムの開発を大きく変える可能性があると感じたため、早速試してみました。
今回の検証では、デバイス(Wio LTE)から気温のデータを送信し、生成AIで「その気温は快適か、それとも不快か」を判定させるところまで確認できました。

![](https://storage.googleapis.com/zenn-user-upload/30acf07f13e4-20240718.png)

## SORACOM Fluxとは

以下は[公式サイト](https://soracom.jp/services/flux/)からの引用です。

> SORACOM Flux はローコード IoT アプリケーションビルダーです。
> デバイスから送信されたセンサーデータ、カメラから送信された画像に対して、ルールを適用し、複数のデータソースや生成 AI を組み合わせて分析/判断し、その結果を IoT デバイスの制御に反映させる IoT アプリケーションをローコードで構築できます。

![](https://storage.googleapis.com/zenn-user-upload/d500bc23e82b-20240718.png)

つまり、「これまでAmazon EC2やAWS Lambda上でプログラムを書いて実現していたであろう、IoTでデバイスから収集したデータに対する分析・判断を、ノーコードで生成AIに丸投げできるサービス」と受け取りました。これが本当なら、我々IoTクラウドエンジニアの仕事は半分くらい生成AIで実現できてしまうのでは？という危機感とワクワク感が入り混じった気持ちになりますね。

https://twitter.com/Y_uuu/status/1813396202819641757

## 試すにあたり準備したもの

SORACOM Fluxを試してみるにあたり以下を準備しました。

### ハード

- PC
- SORACOM IoT SIM(plan-D)
- デバイス: Wio LTE JP Version

![](https://storage.googleapis.com/zenn-user-upload/4bde73278488-20240718.png)

### ソフト

- SORACOMアカウント
- SlackのIncoming Webhook URL
- OpenAIのAPI Key

## デバイスにプログラムを書く

ひとまず、Arduinoで以下のようなプログラムを書いて、Wio LTEに書き込みます。リンク先にも記載している通り、バイナリパーサーの設定を忘れないようにしてください。

https://zenn.dev/y_uuu/scraps/83550c0b42410c

Wio LTEへのプログラムの書き込み手順は次のURLを参照ください

https://users.soracom.io/ja-jp/guides/dev-boards/wio-lte/

## SORACOM Fluxの設定

ここからSORACOM Fluxを使用してFluxアプリを作成していきます。

### Fluxアプリの作成

画面左上のハンバーガーメニューをクリックして、「SORACOM Flux」→「Fluxアプリ」という項目を選択します。

![](https://storage.googleapis.com/zenn-user-upload/cd986745baf2-20240718.png)

次のような画面が表示されるので「新しいFluxアプリを作成する」というボタンをクリックします。

![](https://storage.googleapis.com/zenn-user-upload/ab4d363ef670-20240718.png)

Fluxアプリの名前と概要の入力を求められるので次の画像のように入力し、作成ボタンをクリックします。

![](https://storage.googleapis.com/zenn-user-upload/e044c5dc0448-20240718.png)

### イベントチャネルを作成

「SORACOM Flux Studio へようこそ」という画面が表示されるので「イベントチャネルを作成する」というボタンをクリックします。

![](https://storage.googleapis.com/zenn-user-upload/fb2c4c9fa3e9-20240718.png)

「イベントソースを選んでください」と表示されます。今回はWio LTEから送信したデータを元に処理するので「IoTデバイス」を選択して「次へ」をクリックします。

![](https://storage.googleapis.com/zenn-user-upload/f542b6e33a43-20240718.png)

「イベントソース設定」が表示されるので、Wio LTEのSIMに紐づいているSIMグループを選択して、「イベントチャネルを作成」というボタンをクリックします。

![](https://storage.googleapis.com/zenn-user-upload/59bae42a816e-20240718.png)

### アクションを追加

ここまでの操作を終えるとイベントチャネルが選択された状態の画面に遷移するので、「アクション」タブをクリックし、「アクションを追加」というボタンをクリックします。

![](https://storage.googleapis.com/zenn-user-upload/a2e779e5ca9b-20240718.png)

さまざまなアクションを選択できます。今回はひとまず「Webhook」を選択して、OKボタンをクリックします。

![](https://storage.googleapis.com/zenn-user-upload/078c8977d6ee-20240718.png)

Webhookについて実行条件やリクエスト先、ペイロードの構造を指定できます。
今回はひとまず「URL」にSlackのWebhook URLを、「HTTPボディ」に `{ "text": "通知するよ！" }` と入力し、「作成する」というボタンをクリックします。

![](https://storage.googleapis.com/zenn-user-upload/d9d7e5f84402-20240718.png)

## テスト実行

もう一度チャネルを選択して「テスト実行」をクリックします。BODYに `{}` とだけ入力して実行ボタンをクリックすることで、テスト実行が可能です。

![](https://storage.googleapis.com/zenn-user-upload/095e1d327dcc-20240718.png)

実行状況が画面に表示されます。

![](https://storage.googleapis.com/zenn-user-upload/bdf8e31238d5-20240718.png)

Slackを確認したところ確かに「通知するよ！」というメッセージがPOSTされていました。

![](https://storage.googleapis.com/zenn-user-upload/edddf6291a82-20240718.png)

## デバイスからデータを送信してみる

ここまでで準備は整ったので、いよいよWio LTEの電源をONしてみます。

![](https://storage.googleapis.com/zenn-user-upload/2e89ba3f3bb6-20240718.png)

先の手順で書き込んだプログラムによって10秒ごとにJSONデータをSORACOMプラットフォームに送信しています。

Slackへ10秒ごとにPOSTされていれば導通確認成功です。

![](https://storage.googleapis.com/zenn-user-upload/f9257910e6ed-20240718.png)

## 生成AIを使ったアクションを追加してみる

せっかくなので、生成AIを使って何かしらの判断をさせます。

画面上に表示されているチャネルをクリックして、「アクション」タブを選択し、「アクションを追加」をクリックします。

![](https://storage.googleapis.com/zenn-user-upload/dbae7dab69c3-20240718.png)

「AI」を選択してOKボタンをクリックします。

![](https://storage.googleapis.com/zenn-user-upload/6b7ac409a8c3-20240718.png)

ここで使用する生成AIやプロンプトの入力ができます。今回は次の画像のように入力してみました。入力後に「作成する」ボタンをクリックします。

![](https://storage.googleapis.com/zenn-user-upload/6d9fa0f84ea3-20240718.png)

するとこのようにフローが分岐しました。

![](https://storage.googleapis.com/zenn-user-upload/b00aa9b28bea-20240718.png)

## 生成AIの動作確認

Wio LTEの電源をONして、AIアクションの実行履歴を確認します。

![](https://storage.googleapis.com/zenn-user-upload/304edb10f945-20240718.png)

このように、Wio LTEから送信されたデータに対して、AIアクションが実行されていることが確認できました。
Open AI的には気温が26度と27度が、快適と不快の境界のようですね。

## ハマったポイント

### SORACOM　FluxのFreeプランにおける制限に引っかかった

2024年7月18日時点では、Freeプランのみ利用可能です。FreeプランではAIアクション用のクレジットが `200クレジット` 付与されています。

例えば利用するモデルを「Azure OpenAI GPT-4o」とした場合、1回のリクエストで10クレジットが消費されます。つまり、Freeプランでは20回しかリクエストができないということです。

https://soracom.jp/services/flux/#pricing

私の場合、上記を理解せずにWio LTEからどんどんデータを送信してAIアクションを連続実行したため、あっという間にクレジットを使い切ってしまいました😅

### OpenAI GPT-4oへのリクエストに失敗する

クレジットを使い切ったため、自身が保持するOpenAIのAPI Keyを持ち込むことで、検証を再開しました。

しかし、私が個人的に所有しているOpenAIのアカウントは課金をしておらず、GPT-4oが利用できない状態でした。
このとき、AIアクションの実行履歴上は `Unknown Error` というメッセージが表示されました。

![](https://storage.googleapis.com/zenn-user-upload/1492b6d41c21-20240718.png)

このようなメッセージが表示された場合は、OpenAIでGPT-4oが利用できるようになっているか、確認するようにしましょう。

### AIアクションを高頻度で実行すると、待ちが発生したり順番が入れ替わったりする

GPT-4o自体、それまでのモデルと比較して高速に結果を返してくれるものではありますが、それでもリクエスト〜レスポンスに平均数秒を要します。
私が書いたプログラムのように10秒周期でAIアクションを実行すると、実行に時間がかかってしまい、特定のアクションのみなかなか結果が返ってこなかったり、後に実行したリクエストの方が先に実行完了したりといった現象が発生しました。

そもそも、AIアクションを高頻度で実行すると、お財布にも優しくないです。
ここぞというときにのみAIアクションを呼び出すように、データの送信頻度や条件を調整するようにしましょう。

## 感想

まず、UIやドキュメントがわかりやすく、直感的に使用することができました。

今回の検証では試せていませんが、アクションの結果は別のチャネルに出力し、そこからまた別のアクションを...という風にアクションを数珠繫ぎにすることもできます。
これまでAWS Lambdaに書いていた複雑なロジックをノーコードで視覚的に組み立てることができ、IoTバックエンドを簡単に構築できるようになりますね。

SORACOM FluxはこれからのIoTシステムの開発。特にPoCフェーズのスピード感を大きく変えるサービスになる予感がしています。
前述の通り「自分の仕事、半分くらいAIに奪われたなぁ」という複雑な気持ちではありますが、その分より複雑な問題に時間を使うことができるということなので、人間にしか出せない価値を出していくよう頑張りたいと思います。

SORACOM Fluxを使って、IoTや生成AIの社会実装を加速していきましょう💪
