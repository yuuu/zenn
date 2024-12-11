---
title: "IoTで防犯対策！SORACOMとM5StampC3で自宅を守れるか？"
emoji: "👮"
type: "tech" # tech: 技術記事 / idea: アイデア
topics:
  - soracom
  - aws
  - m5stampc3
  - iot
published: true
published_at: "2024-12-11 06:45"
publication_name: fusic
---

本記事は[SORACOM Advent Calendar 2024](https://qiita.com/advent-calendar/2024/soracom)の11日目の記事です。

世の中には2種類の人間がいます。「窓の施錠をまったく気にしない人間」と「窓の施錠が気になってしまい何度も確認する人間」です。無論、**私は後者**です。

![](https://storage.googleapis.com/zenn-user-upload/56372fe775e0-20241207.jpeg)

「闇バイト」「空き巣」「強盗」。2024年はそういった物騒なニュースを多く目にした年だったように思います。犯罪の手法は多様化していますが、きちんと戸締まりをするだけで防げる犯罪は多いはずです。

「IoTで戸締まりを自動化」というのは誰でも一度は考えたことがあるのではないでしょうか。実際、窓やドアを取り扱うYKK AP 株式会社は[ミモット](https://www.ykkap.co.jp/consumer/products/window/mimott)という戸締り安心システムを2019年から提供していました。しかし残念ながら2025年1月末で販売終了予定とのことです。

https://www.ykkap.co.jp/consumer/products/window/mimott

そんなことを調べてみるうちに、**「どうやらIoTで戸締まりするのはビジネスとしては厳しい。では2024年の今、個人でそれを実現するとどれほどのものが出来上がるのか」**、気になってきました。

:::message
私は毎年12月に「SORACOMを使って○○を作ってみた」という記事を投稿しています。
長い前置きを書きましたが、要は「今年もやったぞ！」ということです。

- [電子ペーパーを使って"やさしい"IoTサイネージを作った！](https://zenn.dev/fusic/articles/9be8c036a9a1ba) (2023年)
- [ソラカメを使って「寝坊した自分がライブ配信されるIoTシステム」を作った！](https://qiita.com/Y_uuu/items/f69015a41b3dff9bfee0) (2022年)
- [SOSした同僚を確実にお助けするためのIoTパトランプを作った](https://qiita.com/Y_uuu/items/9c781f269167d73ee262) (2021年)
- [SORACOMとM5Stackを使ってポケベルを現代に復刻させた](https://zenn.dev/y_uuu/articles/aac958991e8cb6) (2020年)
:::

## 作ったもの

こういったデバイスを窓の鍵に取り付けることで、その窓の施錠状態をクラウドに送信するIoTシステムを開発しました。

![](https://storage.googleapis.com/zenn-user-upload/bd5ffdbbd94c-20241207.jpeg)

クラウドに送信できてしまえば「一定期間開きっぱなしだったら通知をする」「開け閉めを通知する」など、いろいろな活用方法が考えられます。今回は「戸締まり状況を教えてくれるSlackコマンド」を用意しました。

![](https://storage.googleapis.com/zenn-user-upload/8a5c75b9fd29-20241207.png)

## ソースコード

こちらのGitHubリポジトリに公開しています。

https://github.com/yuuu/tojimari


## システム構成とデバイス

デバイスを設計するにあたり、「窓に取り付ける」という点が大きな制約になります。具体的には次のような点に留意する必要があります。

- 窓に取り付けたときに見た目を大きく損なわないサイズ感であること
- 複数の窓に取り付けることを想定し、1台あたりの金額が比較的安価であること
- 電池で長期間駆動できること

上記の制約を考えたとき、各デバイスがWi-FiやLTEでクラウドと通信するのは厳しいことがわかります。そこで次の図のように、部屋の一角にBLEゲートウェイを設置し、窓に取り付けたデバイス(BLEセンサー)が発するBLE信号をクラウドに中継する方式を採用しました。

![](https://storage.googleapis.com/zenn-user-upload/1a7e2852e357-20241207.png)

## デバイスの設計(BLEセンサー)

### 部品選定

以下部品を選定し、購入しました。

| 名前 | 用途 | 価格 |
| ---- | ---- | ---- |
| [M5Stamp C3 Mate](https://www.switch-science.com/products/7474?srsltid=AfmBOoqnhmzpbOTPZ-sN_HsaEll5HsvDNmpPOr7Bv-ij0wYj9Pbp9WXM) | マイコンモジュール | 1,496円 | 
| [電池ボックス 単3×3本 リード線](https://akizukidenshi.com/catalog/g/g102667/) | 電源 | 70円 | 
| [リードスイッチ](https://akizukidenshi.com/catalog/g/g104209/) | センサー | 380円(5個入) | 
| セリア 丸型超強力マグネット | 磁石 | 105円(3個入) | 


マイコンモジュールに関して、今回の場合は極力小さくてBLE通信ができれば何でも良かったのですが、たまたま手元にM5Stamp C3 Mateが複数余っていたので使った、という程度です。より小ささを追究するなら[M5Stamp S3](https://www.switch-science.com/products/8777?_pos=1&_sid=626b8d35f&_ss=r)や[M5Stamp Pico Mate](https://www.switch-science.com/products/7360?srsltid=AfmBOopryky9ErU4jtSKjoY_EYIcu9zyplIjrYFoBkQtmKKp9C0qOZFY)といったデバイスも候補になり得ます。

窓の鍵に取り付けた磁石が近づいたかどうかで施錠状況を判定します。これはリードスイッチという部品を使います。リードスイッチは磁石が近づくと導通するスイッチです。

https://standexelectronics.com/ja/reed-switch-technology-ja/what-is-a-reed-switch-and-how-does-it-work/

### 組み立て

これらの部品を組み立てていきます。まずは電池ボックスをM5Stamp C3 MateのVCC, GNDへはんだ付けします。

![](https://storage.googleapis.com/zenn-user-upload/164088d24e61-20241207.jpeg)

続いてリードスイッチをはんだ付けします。今回はGPIOを `INPUT_PULLUP` する前提でG8とGNDへ直接はんだ付けしています。

![](https://storage.googleapis.com/zenn-user-upload/3ed521d51575-20241207.jpeg)

あとはこれらがピッタリ収まる筐体を3Dプリンタで出力しました。

![](https://storage.googleapis.com/zenn-user-upload/26fc95b1d836-20241207.jpeg)
![](https://storage.googleapis.com/zenn-user-upload/f3659b19ec65-20241207.jpeg)

ピッタリ収まるまでの試行錯誤が大変でしたが、最終的に次の写真のような箱型デバイスが完成しました。

![](https://storage.googleapis.com/zenn-user-upload/e8be45e9b2ef-20241207.jpeg)

### 組み込みソフトウェアの設計・実装

マイコンモジュール上で動作する組み込みソフトウェアを実装します。特に凝ったことをするわけではないので、シンプルにArduino IDEでプログラムを書いて書き込んでいます。

https://github.com/yuuu/tojimari/blob/main/devices/ble-sensor/ble-sensor.ino

電池を極力長持ちさせるため、10秒周期でDeepSleepさせるようにしています。今回は技術検証という目的も兼ねていたので10秒としましたが、戸締まりという用途を考えるともっと周期を延ばすのも手です。
BLE Advertiseを行い、そこに施錠状態(1 or 0)を載せています。

このように磁石を近づけることで読み出せる値が変化することを確認しました。(施錠時は緑に、開放時は赤く光るようにしています)

![](https://storage.googleapis.com/zenn-user-upload/993efd263915-20241207.jpeg)
![](https://storage.googleapis.com/zenn-user-upload/ac070fa369ff-20241207.jpeg)

## デバイスの設計(BLEゲートウェイ)

### 部品選定

BLEゲートウェイもM5Stamp C3 Mateを使用しました。このマイコンだけでBLE通信もクラウドとの通信も実現できますし、こちらは電源の制約もないため、電池ボックスは不要、代わりにUSB type-CのケーブルとUSB電源アダプタを用意しました。

| 名前 | 用途 | 価格 |
| ---- | ---- | ---- |
| [M5Stamp C3 Mate](https://www.switch-science.com/products/7474?srsltid=AfmBOoqnhmzpbOTPZ-sN_HsaEll5HsvDNmpPOr7Bv-ij0wYj9Pbp9WXM) | マイコンモジュール | 1,496円 | 
| USB type-Cケーブル | 電源 | 0円(家にあるものを使用) | 
| USB電源アダプタ | 電源 | 0円(家にあるものを使用) | 

こちらは窓に取り付けることもないですし、あまり見た目にこだわる必要はないため、電源が取れる適当な場所に設置するのみです。

![](https://storage.googleapis.com/zenn-user-upload/4b817793a7b5-20241207.jpeg)

### 組み込みソフトウェアの設計・実装

BLEゲートウェイはSORACOM Arcを使ってSORACOMと接続しています。ESP32のマイコンからSORACOM Arcに接続する方法はこちらの記事を参照ください。

https://tech.fusic.co.jp/posts/2022-04-24-m5stack-soracom-arc/

あとは、BLEセンサーが定期的にAdvertiseする信号を受信し、それをSORACOMに送信するのみです。

https://github.com/yuuu/tojimari/blob/main/devices/ble-scanner/ble-scanner.ino

## クラウドの設計・構築

SORACOMにデータを送信できるようになったら[こちらのドキュメント](https://users.soracom.io/ja-jp/docs/funnel/aws-iot/)を参考に、AWS IoT Coreにそのデータを転送します。

AWS側は以下の構成図のように構成しました。IaCにはAWS SAMを使用しています。

![](https://storage.googleapis.com/zenn-user-upload/50adbf6e1c6d-20241207.png)

AWS IoT Coreに送信されたデータはもれなくAmazon DynamoDBに書き込まれます。これはAWS SAMテンプレート中でAWS IoT Coreのアクションルールを作成することで実現しています。具体的にはこのあたり。

https://github.com/yuuu/tojimari/blob/6dc76c230684c6bb34937dea616d434abcc419b1/template.yaml#L85

Slackからスラッシュコマンドを実行すると、Amazon API Gatewayのエンドポイントに対してHTTPS POSTされ、AWS LambdaがAmazon DynamoDBの値を読み出してレスポンスする、という流れです。AWS Lambdaのソースコードは次の通りです。

https://github.com/yuuu/tojimari/blob/main/tojimari/app.rb

## 動作確認

さっそく窓の鍵の近くにBLEセンサーを設置してみました。

![](https://storage.googleapis.com/zenn-user-upload/23e6161e43f2-20241208.jpeg)

このとき、Slackでスラッシュコマンドを実行すると、「戸締まり完了！」と教えてくれます。(アイコンが「雀」なのは御愛嬌です)

![](https://storage.googleapis.com/zenn-user-upload/69269d2ff641-20241208.png)

では、窓を解錠してみます。

![](https://storage.googleapis.com/zenn-user-upload/40898acedcb5-20241208.jpeg)

Slackでスラッシュコマンドを実行すると、「開いている窓がある」と教えてくれました！

![](https://storage.googleapis.com/zenn-user-upload/a64395778217-20241208.png)

## 今後の課題

### 電池はどれだけ保つのか？

今回はSORACOM Advent Calendar 2024に間に合わせようと慌てて製作をしていたため、このBLEセンサーが電池交換をせずにどれだけ連続稼働できるのか検証ができていません。

少なくとも10秒周期では1ヶ月保つかどうか、という結果になると予想しています。周期をもう少し延ばして半年くらい保つようになるといいなと思います。

### 複数台になっても対応ができるのか？

BLEセンサー1台での動作確認はうまくいきましたが、家には窓が複数あります。台数が増えたときにも今の仕組みが機能するのかは気になるところです。設計上は複数台になっても動作はするはず。

### 通信の途絶やデバイスの障害にどう気づくか？

今の設計ではBLEセンサーが突然故障したり電池が切れたときに気づく手段がありません。一定期間、クラウドにデータが送信されて来ない場合はアラートを出す仕組みを入れる、といった方法で対策が必要です。

## あとがき

思い描いていた戸締まりを確認するIoTシステムを、無事に実現できました。

ちなみに、冒頭に「IoTで戸締まりするのはビジネスとしては厳しい」と書きましたが、セサミスマートロックを販売しているCANDY HOUSEから、「オープンセンサー」なるものが販売されていることに気づきました。

https://jp.candyhouse.co/products/sesame-opensensor

この製品はセサミスマートロックと連携して、適切なタイミングでドアの鍵を施錠するものだと思っていたのですが、これは窓に取り付けて施錠状態を確認する用途でも使えるようです。

CR1632電池1本で稼働し、電池寿命は10年。見た目を損なわないデザイン性があり、価格は約1,000円。いやぁ、プロの設計はすごいですね💦早速1台ポチりました。
