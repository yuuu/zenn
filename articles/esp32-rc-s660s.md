---
title: "ESP32とRC-S660/Sを使ってFeliCaカードを読み取る"
emoji: "🚆"
type: "tech" # tech: 技術記事 / idea: アイデア
topics:
  - esp32
  - felica
  - iot
published: false
publication_name: fusic
---

こちらのポストにあるようなFeliCaカードリーダーを作成しました。


## 使用した機材

- M5Stamp C3 Mate
  - https://www.switch-science.com/products/7474
  - UART通信ができるマイコンボードであれば何でもOKですが、今回はこちらを使用しました。
- SONY RC-S660/S 
  - https://www.switch-science.com/products/9660
  - ドキュメントは[メーカーサイト](https://www.sony.co.jp/Products/felica/business/products/reader/RC-S660S.html)を参照
- 変換基板
  - https://www.switch-science.com/products/1029
  - RC-S660/Sをブレッドボードで使うための変換基板です

## ハードウェア

今回は技術検証ということでブレッドボード上に配線しています。

| No  | M5Stamp C3 Mate | 変換基板 | 
| :-: | --------------- | -------- | 
| 1   | 3V3             | VDD 3.3V | 
| 2   | G19(TX)         | RX       | 
| 3   | G18(RX)         | TX       | 
| 4   | GND             | GND      | 

M5Stamp C3 Mateのピンアサインはこちらのサイトの下の方に画像があります。

https://docs.m5stack.com/ja/core/stamp_c3_mate

変換基板とRC-S660/Sの接続方法はこちらのサイトが参考になります。フラットケーブルの青い面をシールド側にして接続しました。

https://www.hmcircuit.jp/nfc/rcs660_hands_on.html

## ソフトウェア

M5Stamp C3 MateのUART 0はデフォルトだとUSB側を向いていて競合しがちなので、UART 1を使ってRC-S660/Sと通信します。
今回はArduinoを使ってプログラムしており、 `Serial1` クラスを使って通信しています。

ソースコードは以下にアップロードしているので、適宜参考にしてください。
https://github.com/yuuu/rc-s660-example

## 課題


## 感想

FeliCaはいわゆる交通系ICカードとして常に携帯している人が比較的多いですし、iPhone・Apple Watchなどの電子機器でも代替が可能です。
セサミ スマートロックなども交通系ICカードとの連携が可能なユニットが販売されています。 [参考](https://jp.candyhouse.co/products/sesame-touch)

システムの一部に組み込むことで鍵の解錠や打刻、何らかのオペレーション記録など、さまざまな用途で活用可能ですし、IoTとも親和性が高いモジュールと感じました。
