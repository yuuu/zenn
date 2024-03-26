---
title: "Nordic Semiconductor Power Profiler Kit IIでM5Stamp C3の電流値を計測する"
emoji: "⚡"
type: "tech" # tech: 技術記事 / idea: アイデア
topics:
  - M5StampC3
  - P2K
  - 電子工作
published: true
published_at: "2024-03-27 07:00"
publication_name: "fusic"
---

先日、Nordic Semiconductor Power Profiler Kit II(PPK2)という製品を入手しました。

この製品は名前のとおり、組み込みシステムの消費電流を簡単に計測するツールで、PCとUSB接続をし、VOUT/GNDを対象の機器に接続することで簡単に消費電流を計測できます。

![](https://storage.googleapis.com/zenn-user-upload/fd002618d6f8-20240327.png)

この製品は、DigiKeyで15,000円程度で購入できます。

https://www.digikey.jp/ja/products/detail/nordic-semiconductor-asa/NRF-PPK2/13557476

直近だと、M5Stamp C3を用いて遊ぶことが多いので、この機器上でいろいろなプログラムを動かして、消費電流の変化を計測してみることにしました。

## PPK2の使い方

以下の記事がとてもわかりやすいのでこちらを参照ください。

https://elchika.com/article/a25d7295-84ad-4426-a834-0539a39d8333/

## ハードウェア構成

シンプルにPPK2のVOUTとGNDをM5Stamp C3に接続しています。

![](https://storage.googleapis.com/zenn-user-upload/645e8303000f-20240327.jpeg)

## ソフトウェア構成

今回はArduino IDEを使ってファームウェアを書き込み、動作させています。設定は基本的にデフォルトです。

![](https://storage.googleapis.com/zenn-user-upload/8e41eb9088ed-20240327.png)

## 計測

### シンプルなLチカ

M5Stamp C3にはフルカラーLEDが実装されています。手始めにこれを最大出力で点灯→消灯を繰り返したときの消費電流を計測しました。

#### プログラム

```c
#include <M5StampC3LED.h>

M5StampC3LED led = M5StampC3LED();

void setup() {
  Serial.begin(115200);
  led.clear();
}

void loop() {
  led.show(255, 255, 255);
  delay(1000);
  led.show(0, 0, 0);
  delay(1000);
}
```

LEDの制御には自作のラッパーライブラリを使用しています。

https://reference.arduino.cc/reference/en/libraries/m5stampc3led/

#### 結果

![](https://storage.googleapis.com/zenn-user-upload/d365014f4dec-20240327.png)

- LED点灯時: 平均41.56mA、最大48.63mA
- LED消灯時: 平均16.52mA、最大40.40mA

LED点灯で平均25mA程度電流値が増えるようです。

### Wi-Fi接続

では次にWi-Fiに接続した際の消費電流を計測します。

#### プログラム

```c
#include <WiFiManager.h>
#include "secrets.h"

WiFiManager wifiManager;

void setup() {
  Serial.begin(115200);

  char apName[64] = {0};
  uint64_t chipId = ESP.getEfuseMac();
  sprintf(apName, "%s-%04X", AP_NAME_PREFIX, chipId);

  Serial.println("start connected");
  wifiManager.autoConnect(apName, AP_PASSWORD);
  Serial.println("end connected");
}

void loop() {
  delay(1000);
}
```

Wi-Fiの接続には以下ライブラリを使用しています。

https://www.arduino.cc/reference/en/libraries/wifimanager/

#### 結果

![](https://storage.googleapis.com/zenn-user-upload/bf467982ed22-20240327.png)

今回、ロジックアナライザを使っていないので厳密にどのタイミングでWi-Fi接続したかが検証できていないのですが、最大347.22mAが流れるタイミングがあるということがわかりました。

「シンプルなLチカ」での計測は起動時のピークが106.94mAだったのでWi-Fi接続することで250mA程度、消費電流は増えています。

### AWS IoT Coreと接続

Wi-Fi接続後にAWS IoT Coreと接続し、メッセージをPublishして、計測してみました。

#### プログラム

```c
#include <WiFiManager.h>
#include <WiFiClientSecure.h>
#include <MQTT.h>
#include <ArduinoJson.h>
#include "secrets.h"

WiFiManager wifiManager;
WiFiClientSecure wifiClient = WiFiClientSecure();
MQTTClient mqttClient = MQTTClient(256);

void setup() {
  Serial.begin(115200);

  char apName[64] = {0};
  uint64_t chipId = ESP.getEfuseMac();
  sprintf(apName, "%s-%04X", AP_NAME_PREFIX, chipId);

  wifiManager.autoConnect(apName, AP_PASSWORD);

  wifiClient.setCACert(AWS_CERT_CA);
  wifiClient.setCertificate(AWS_CERT_CRT);
  wifiClient.setPrivateKey(AWS_CERT_PRIVATE);
  mqttClient.begin(AWS_IOT_ENDPOINT, 8883, wifiClient);
  
  for (int retry = 0 ; retry < 3 ; retry++) {
    mqttClient.connect(THINGNAME);
    if (mqttClient.connected()) {
      break;
    }
    Serial.print(".");
    delay(5000);
  }

  StaticJsonDocument<200> doc;
  doc["hello"] = "world!";
  
  char jsonBuffer[32];
  serializeJson(doc, jsonBuffer);
  mqttClient.publish("ppk2", jsonBuffer);
}

void loop() {
  delay(1000);
}
```

AWS IoT Coreとの接続や、JSONの生成に以下ライブラリを使用しています。

https://www.arduino.cc/reference/en/libraries/mqtt/
https://www.arduino.cc/reference/en/libraries/arduinojson/

#### 結果

![](https://storage.googleapis.com/zenn-user-upload/d4eb1831659a-20240327.png)

先ほどの結果と比べて、ピークが立つ期間が伸びており、ここでWi-Fi経由でAWS IoT Coreへ接続し、メッセージをPublishしているものと推測されます。

ピーク電流については348.79mAであり、先ほどと大差ないですね。

### Deep Sleep

最後に、Deep Sleepしたときの電流値を計測します。そもそも今回電流値を計測しようと思ったきっかけはDeep Sleep時にどの程度の電流が流れているかを知りたかったためです。

これがわかると、例えば乾電池で駆動した際にどの程度の周期で電池交換が必要かが算出できるようになります。

#### プログラム

```c
void setup() {
  Serial.begin(115200);

  esp_deep_sleep_enable_gpio_wakeup(BIT(3), ESP_GPIO_WAKEUP_GPIO_LOW);
  esp_deep_sleep_start();
}

void loop() {
  delay(1000);
}
```

一応、基板上のボタンを押すことでDeep Sleepから復帰できるようにしているので、計測中に1回押してみることにしました。

#### 結果

全体

![](https://storage.googleapis.com/zenn-user-upload/5e4cf22b1224-20240327.png)

Deep Sleep中を拡大

![](https://storage.googleapis.com/zenn-user-upload/9101c690fedb-20240327.png)

予想通りDeep Sleep中は平均450.21uA、最大21.25mAとなっており、消費電流がかなり抑制できていることが確認できました。

乾電池1本の容量を1500mAhとして、乾電池4本で駆動させる(つまり6000mAh)とすると、13327時間≒555日も待機可能という計算になります。

## まとめ

Deep Sleep時の消費電流は期待通りの値を確認することができました。

電池駆動するIoT機器を作る際は、いかにDeep Sleepする時間を長く、Wi-Fi接続・通信する時間を短くするかが、電池交換の周期を長くするための勘所になりそうです。
