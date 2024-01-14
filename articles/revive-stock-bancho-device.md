---
title: "M5Stamp S3を使って社内IoTシステムの体重計デバイスを生き返らせる"
emoji: "⚡"
type: "tech" # tech: 技術記事 / idea: アイデア
topics:
  - "M5Stamp"
  - "Arduino"
  - "C"
  - "電子回路"
published: false
publication_name: "fusic"
---

みなさんIoTしてますか？
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
#include <FastLED.h>
#include <WiFi.h>
#include <WiFiMulti.h>
#include <WiFiClientSecure.h>
#include <PubSubClient.h>
#include "HX711.h"
#include "secret.h"

#define PIN_LED 21
#define NUM_LEDS 1
#define PIN_DOUT 1
#define PIN_CLK 3
#define PERIOD_USEC (3600000000ULL)

#define OFFSET 12
#define CALIBRATION -2340.214844

CRGB leds[NUM_LEDS];
WiFiMulti WiFiMulti;
WiFiClientSecure net = WiFiClientSecure();
PubSubClient client(net);
HX711 scale;

void initLED() {
  FastLED.addLeds<WS2812B, PIN_LED, GRB>(leds, NUM_LEDS);
  showLED(0, 0, 0);
}

void showLED(int red, int green, int blue) {
  leds[0] = CRGB(red, green, blue);
  FastLED.show();
}

void connectWiFi() {
  int sum = 0;
  WiFiMulti.addAP(WIFI_SSID, WIFI_PASSWORD);
  USBSerial.printf("Waiting connect to WiFi: %s ...", WIFI_SSID);
  while (WiFiMulti.run() != WL_CONNECTED) {
    USBSerial.print(".");
    delay(1000);
    sum += 1;
    if (sum == 8) {
      USBSerial.print("Conncet WiFi failed!");
      esp_deep_sleep_start();
    }
  }
  USBSerial.println("\nWiFi connected");
  USBSerial.print("IP address: ");
  USBSerial.println(WiFi.localIP());
}

void connectBroker() {
  int sum = 0;
  net.setCACert(ROOT_CA);
  net.setCertificate(CERTIFICATE);
  net.setPrivateKey(PRIVATE_KEY);
  client.setServer(ENDPOINT, 8883);
  while (!client.connect(CLIENT_ID))
  {
    USBSerial.print(".");
    delay(1000);
    sum += 1;
    if (sum == 8) {
      USBSerial.print("Conncet Broker failed!");
      esp_deep_sleep_start();
    }
  }
  USBSerial.println("\nBroker connected");

}

void publish(float weight) {
  char buf[64] = {0};
  sprintf(buf, "{\"weight\": %f}", weight);
  client.publish(TOPIC, buf);
}

void init_weight() {
  scale.begin(PIN_DOUT, PIN_CLK);
  scale.set_scale(CALIBRATION);
  // scale.tare();

  while(!scale.is_ready()) {
    delay(1000);
  }
}

float get_weight() {
  return scale.get_units(10) + OFFSET;
}

void setup() {
  USBSerial.begin(9600);
  USBSerial.println("start");
  esp_sleep_enable_timer_wakeup(PERIOD_USEC);

  initLED();
  showLED(10, 0, 0);
  connectWiFi();
  showLED(0, 10, 0);
  // connectBroker();
  init_weight();
  float weight = get_weight();
  // publish(weight);
  USBSerial.printf("weight: %f\n", weight);
  showLED(0, 0, 10);

  USBSerial.println("end");

  delay(1000);
  showLED(0, 0, 0);
  esp_deep_sleep_start();
}

void loop() {
  delay(1000);
}
```

## AWS Lamda関数の書き換え


## 動作確認


## まとめ

