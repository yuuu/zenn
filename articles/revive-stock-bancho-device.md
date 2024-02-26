---
title: "M5Stamp S3を使って社内IoTシステムの体重計デバイスを生き返らせる"
emoji: "⚡"
type: "tech" # tech: 技術記事 / idea: アイデア
topics:
  - "M5Stamp"
  - "Arduino"
  - "C"
  - "電子回路"
published: true
publication_name: "fusic"
---

みなさんIoTしてますか？

![](https://storage.googleapis.com/zenn-user-upload/580cd97b8a56-20240226.jpg)

かつて弊社にはオフィスにあるウォーターサーバーのボトルの残量を、オフィスに行くことなく把握することのできるIoTシステムが運用されていました。その名も「ストック番長」です。

このシステムは、弊社に中途入社した社員が作ったものでシステムの詳細は以下の記事を読むことで知ることができます。

https://fusic.co.jp/doings/314

無事に開発は完了して約1年間運用を続け、日々ボトルの残量を番長がお知らせしてくれていました。

## その日は突然やってきた

このシステムを継続運用するために、番長の稼働状況をこっそり監視する仕組みを入れていたのですが、ある日突然通知が来なくなりました。

![](https://storage.googleapis.com/zenn-user-upload/115c554db6bd-20240114.png)

原因は当時使用していたWi-Fiのアクセスポイントにあったようで、別のアクセスポイントにつなぎ直すことで番長は生き返る想定でした。しかし、接続するアクセスポイントの情報はデバイスのFW(ファームウェア)にハードコーディングされているので、FWの書き換えが必要です。

ストック番長で使用しているマイコンはESP-WROOM-02というもので、FWを書き換えるための回路が内蔵されていません。開発時は書き換え用の回路を都度ブレッドボード上に作っていたのですが、開発が終わった段階でどこかに行ってしまい、再度回路から作り直す必要がありました。

![](https://storage.googleapis.com/zenn-user-upload/073f69115846-20240114.png)

そんなこんなであれから10ヶ月。そろそろ重い腰を上げて、番長の蘇生に乗り出したというわけです。

## 番長を診断する

実は番長のデバイスを開発したのは自分ではありません。今回、自分が蘇生をするにあたり、現状どのような設計で作られているのかを把握するところから始めました。幸い、前任者はしっかりとドキュメントやソースコードを残していたので、現状把握は容易でした。

![](https://storage.googleapis.com/zenn-user-upload/4b8e05b039cc-20240114.png)

実際に体重計の蓋を開けてみて、基板上の回路が回路図と一致していることも確認できました。

![](https://storage.googleapis.com/zenn-user-upload/542ef5018bee-20240114.png)

番長について簡単にまとめると以下の通りです。

- ESP-WROOM-02というマイコンに、Aruduinoで作ったFWを書き込んでいる。書き込み用の回路は現状ない
- ウォーターサーバーのボトルの重量計測は体重計を改造することで実現している。ロードセルの呼び出しにHX711というADコンバーターを用いている
- FWはPlatformIOのプロジェクトを作成して、ビルド管理している
- 番長が重量計測するのは毎日1回(13時)のみ。このタイミングがずれることを防ぐためにNTPサーバーにアクセスしたり、時刻のズレを補正したりとFWの実装が複雑化している

## 蘇生の方針を決める

診断結果を踏まえ、次のような方針で番長を生き返らせることにしました。

- ESP-WROOM-02は、もっと容易に書き込みができる別のマイコン(もしくはデバイス)に置き換える
- 既存の体重計および回路はできる限り流用する
- 開発環境はPlatformIOからArduinoIDEに変更する。筆者視点ではこちらの方が誰でも気軽にFWを触れそうと感じたため。
- 番長にはもっと頻繁に重量を計測してもらう。代わりに時間のずれは気にしない。

## 回路の改修

ESP-WROOM-02を置き換えるべく、導線を切断します。「名探偵コナン 時計じかけの摩天楼」の最後のシーンを彷彿とさせますね。

![](https://storage.googleapis.com/zenn-user-upload/113c0bf67730-20240114.png)

切りました。もう後戻りはできません。電源供給側の導線が両方とも黒い線で、VccとGNDを取り違えると大変なのでVcc側にビニールテープで印を付けておきました。

![](https://storage.googleapis.com/zenn-user-upload/c334d98108e8-20240114.jpg)

さて、今回置き換え後のマイコンとしてM5Stamp S3を使用しました。名前の通り切手サイズのデバイスでありながら、USB経由でのFW書き込みやWi-Fi接続も可能な優れものです。

![](https://storage.googleapis.com/zenn-user-upload/b76bcc9ff2b4-20240114.png)

これをユニバーサル基板に取付け、元の回路と同じように接続していきました。もう少し綺麗にはんだ付けできると良かったですが、多めに見てください。

![](https://storage.googleapis.com/zenn-user-upload/05a8778319ac-20240114.png)

![](https://storage.googleapis.com/zenn-user-upload/5e081362ed79-20240114.png)

取り付ける部品はマイコンと抵抗のみなので、もしかするとユニバーサル基板は不要で空中はんだでも良かったかもしれません。基板の余白が多いですがこれでも体重計には収まるので、今後の拡張性を残す意味でもこのままにしています。


## FWの書き換え

新しいFWをArduinoIDEで作成しました。起動→Wi-Fi接続→MQTT接続(AWS IoT Core)→deep sleepというシンプルな処理です。

```c
void setup() {
  USBSerial.begin(9600);
  USBSerial.println("start");
  esp_sleep_enable_timer_wakeup(PERIOD_USEC);

  initLED();

  // 起動時点で赤点灯
  showLED(10, 0, 0);
  connectWiFi();

  // WiFi接続成功時点で緑点灯
  showLED(0, 10, 0);
  connectBroker();
  init_weight();
  float weight = get_weight();
  publish(weight);

  // データ送信成功時点で青点灯
  showLED(0, 0, 10);
  USBSerial.println("end");
  delay(1000);
  showLED(0, 0, 0);
  esp_deep_sleep_start();
}
```

ちなみに `PERIOD_USEC` は1時間としています。問題なさそうであれば徐々に周期は延ばしていく予定です。

同じ作業を繰り返し、合計2台の体重計を作成しました。これで準備は完了です。

![](https://storage.googleapis.com/zenn-user-upload/c823a853d9c7-20240226.jpg)

## クラウド側の設計見直し

このシステムのクラウド側はAWS IoT Core, Amazon DynamoDB, AWS Lambdaを活用したサーバーレスアーキテクチャで構築されていました。今後もこの構成を使い続けるつもりではあったのですが、デバイス側の仕様を変えたことで一部見直しが必要でした。

もともとはデバイス側でSNTPクライアントを動作させ、正確な時刻が付与されたデータがクラウドに送信される前提でした。この時刻情報を突合することで、2台の体重計の測定結果を合算していたのです。

![](https://storage.googleapis.com/zenn-user-upload/25826663532a-20240225.png)

しかし、今回生き返らせたデバイスではSNTPクライアントは使用していません。このため2台の体重計が付与するタイムスタンプは毎回ずれます。

![](https://storage.googleapis.com/zenn-user-upload/0172d9a11fd7-20240225.png)

そこでAmazon DynamoDBのテーブル設計を見直して、それぞれのデバイスの最新の測定結果を覚えておき、Amazon EventBridgeでトリガしたLambda関数にて最新の値を取得・合算する方式にしました。

ついでに、AWS SAMを導入して、これまでできていなかったIaC化もしておきました。

## 動作確認

運用から早1ヶ月が経過していますが、毎日ボトルの数を通知してくれています。

![](https://storage.googleapis.com/zenn-user-upload/0fd2686e3d14-20240226.png)

## まとめ

![](https://storage.googleapis.com/zenn-user-upload/d57439c1d0d7-20240226.jpg)

作ったIoTシステムに対する、担当者の引き継ぎやアーキテクチャの変更といった、運用らしい運用ができていることを自分としては喜ばしく感じています。

オフィスで仕事をする人にとって生命線とも言える水を枯渇させないよう、番長にはこれからもしっかり仕事をしてもらいます。
