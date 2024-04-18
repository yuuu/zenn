---
title: "デバイスをAWS IoT Coreに接続する前にやるべきこと"
emoji: "🗝️"
type: "tech" # tech: 技術記事 / idea: アイデア
topics:
  - aws
  - awsiotcore
  - iot
published: true
published_at: "2024-04-18 15:00"
publication_name: "fusic"
---

AWSを用いたIoTシステムにおいて、真っ先に候補に上がるサービスがAWS IoT Coreです。
デバイスをAWS IoT Coreに接続する際、接続先のエンドポイントを確認したり、モノを登録して証明書を取得したり、といった準備が必要です。

![](https://storage.googleapis.com/zenn-user-upload/505ab5b344aa-20240418.png)

具体的な手順はAWSのドキュメントにも記載があります。
しかし、図が少ない、ページが複数に分かれている、機械翻訳が怪しいといった点で、これからAWS IoT Coreを使い始める人には少しオススメしづらいです。
https://docs.aws.amazon.com/ja_jp/iot/latest/developerguide/security.html

そういった状況を踏まえ、本記事ではAWS IoT Coreを初めて使う方向けに、デバイスを接続するためにやるべき手順をまとめます。

## 【注意】本記事では解説しないこと

本記事では次の内容については触れません。ご注意ください。

- X.509そのものの説明や理論
- 「IAM ユーザー、グループ、ロール」や「Amazon Cognito ID」といった「X.509」以外のクライアント認証方法
- AWS IoT Coreへユーザー自身が用意した証明書を持ち込んで利用する方法
- AWS IoT Core フリートプロビジョニングを利用したプロビジョニング方法

## エンドポイントを確認する

まず、デバイスにとっての接続先となる、「エンドポイント」を確認しましょう。

![](https://storage.googleapis.com/zenn-user-upload/2ff4e27b8306-20240418.png)

[AWS マネジメントコンソール](https://aws.amazon.com/jp/console/)にサインインします。
サインインしたら画面上部の「検索」と書かれた箇所に「iot core」と入力することで、AWS IoT Coreのコンソール画面に移動します。

![](https://storage.googleapis.com/zenn-user-upload/3ad3aa86617f-20240417.png)

画面左側のメニューの下から3番目にある「設定」をクリックすると、画面中央に「エンドポイント」が表示されます。
ここに記載されている文字列をコピーしておきましょう。

![](https://storage.googleapis.com/zenn-user-upload/3196308c14ca-20240417.png)

## 証明書を作成する

### AWS IoT Core ポリシーを作成する

次の手順として、デバイスを認証するために必要な「証明書」を作成していきます。しかし、「証明書」を作成する際には「AWS IoT Core ポリシー」を選択する必要があり、これはあらかじめ作成しておく方がスムーズに作業を進められます。

「AWS IoT Core ポリシー」とは、その証明書を持つクライアントにどういったアクションを許可するかを記載したJSONドキュメントです。JSONドキュメントを直接編集することもできますし、画面操作から作成することもできます。本記事では画面操作から作成する方法を解説します。

AWS IoT Coreのコンソール画面左側のメニューにて、「セキュリティ」→「ポリシー」をクリックします。すると画面右上に「ポリシーを作成」というボタンが表示されるのでこれをクリックします。

![](https://storage.googleapis.com/zenn-user-upload/8b1a7116b2c7-20240417.png)

フォームが表示されたら、「ポリシー名」を入力します。

![](https://storage.googleapis.com/zenn-user-upload/dbf345b0d0e1-20240417.png)

続いて、このポリシーで許可するアクションを入力します。「ポリシー効果」「ポリシーアクション」「ポリシーリソース」をそれぞれ入力します。画像は、接続およびパブリッシュ(AWS IoT Coreへのデータ送信)を全て許可する例です。入力したら「作成」をクリックしましょう。

![](https://storage.googleapis.com/zenn-user-upload/94f6e0bab929-20240417.png)

### モノを作成する

いよいよ「証明書」を作成します。証明書は単体でも作成は可能ですが、AWS IoT Coreでは「モノ」を作成することで証明書だけでなくモノのプロパティ(名前やタイプ)・グループも併せて設定できます。こちらの方が便利なので、モノを作成していきます。

![](https://storage.googleapis.com/zenn-user-upload/25c7b0621e7c-20240418.png)

AWS IoT Coreのコンソール画面左側のメニューにて、「すべてのデバイス」→「モノ」をクリックします。すると画面右上に「モノを作成」というボタンが表示されるのでこれをクリックします。

![](https://storage.googleapis.com/zenn-user-upload/18efb019a38c-20240417.png)

「作成するモノの数」を指定する画面が表示されます。今回は1つのモノを作成するので「1つのモノを作成」をクリックし「次へ」をクリックします。

![](https://storage.googleapis.com/zenn-user-upload/2ed2eb36dfb9-20240417.png)

「モノのプロパティを指定」と書かれたフォームが表示されます。「モノの名前」に任意の名前を入力しましょう。

![](https://storage.googleapis.com/zenn-user-upload/66cd0894dbbc-20240417.png)

そのまま画面をスクロールして「次へ」をクリックします。

![](https://storage.googleapis.com/zenn-user-upload/2e674bf97050-20240417.png)

続いて証明書の作成方法を選択します。今回は「新しい証明書を自動生成 (推奨)」をクリックし、「次へ」をクリックしましょう。

![](https://storage.googleapis.com/zenn-user-upload/575b87697ba2-20240417.png)

この証明書にアタッチするポリシーを選択します。先ほど作成したポリシーを選択し、「モノを作成」をクリックしましょう。

![](https://storage.googleapis.com/zenn-user-upload/626653e67ae6-20240417.png)

「証明書とキーをダウンロード」というモーダルが表示されます。「デバイス証明書」「キーファイル」「ルートCA証明書」が後々必要となるのでそれぞれダウンロードしておきましょう。

![](https://storage.googleapis.com/zenn-user-upload/b58d170098d2-20240417.png)

## まとめ

以上がエンドポイントの確認および証明書の作成手順です。これらの情報をデバイスに渡すことで、デバイスから接続やデータの送信が行えるようになります。

画面遷移が多く最初は混乱しがちですが、慣れると自然に行えるようになるので、必要に応じてこの記事を見返しながら覚えていってください。

## 参考

- https://d1.awsstatic.com/whitepapers/ja_JP/device-manufacturing-provisioning.pdf