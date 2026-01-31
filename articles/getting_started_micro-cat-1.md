---
title: "IoT向け一体型基板『MicroCat.1』を使ってSORACOMと通信するまで"
emoji: "🐈️"
type: "tech" # tech: 技術記事 / idea: アイデア
topics:
  - SORACOM
  - MicroPython
  - microcat1
  - RP2350
published: true
published_at: "2026-02-02 07:30"
publication_name: "fusic"
---

MicroCat.1は [メカトラックス株式会社](https://mechatrax.com/aboutus/) が販売しているMicroPython搭載LTE Cat.1 bis通信モジュール一体基板です。2025年11月に開催された展示会「EdgeTech+2025」にて発表され、その後2025年12月12日からプレリリース版の販売が始まっています。

https://store.mechatrax.com/product.php?id=84

:::message
台数限定販売となっていますが、執筆時点では「在庫: 27」となっています。
LTE通信モジュールを搭載した基板が5000円で購入できる機会はなかなかないので、IoTに興味のある方はこれを機に購入してみてはいかがでしょうか？
:::

私も販売開始早々に購入したのですが、今日まであまり触れていませんでした。
このタイミングでようやく時間を作ることができたので、実際に触ってみて気付いたことや詰まった点などを記録していきます。

![](/images/getting_started_micro-cat-1/002.jpeg)

## 準備物

作業をはじめるにあたり私が用意したものを列挙します。

- [MicroCat.1](https://store.mechatrax.com/product.php?id=84)
- USB type-Cケーブル
  - 私は [Ankerのケーブル](https://amzn.asia/d/2HD0A1e) を使っています
- SORACOM IoT SIM
  - 私は [plan-D](https://soracom.jp/store/13380/) を使っています
  - サイズはnano(ナノ)です。間違えないよう注意しましょう

## ドキュメントを読む

MicroCat.1の販売ページにドキュメントへのリンクが貼られています。

https://github.com/mechatrax/microcat1

[ハードウェア](https://github.com/mechatrax/microcat1/wiki/%E3%83%8F%E3%83%BC%E3%83%89%E3%82%A6%E3%82%A7%E3%82%A2) についてはさらっと読みました。

- MCUは `RP2350B` でRaspberry Pi Pico 2と同じ
- ピンアサインもRaspberry Pi Pico 2に準拠
- 通信モジュールは `SIM7672JP`
- 前述の通りSIMはnano(ナノ)
- リセットスイッチとブートスイッチがある。おそらくファームウェアを書き換える際にブートスイッチを押すことになる

続いて、[ソフトウェア](https://github.com/mechatrax/microcat1/wiki/%E3%82%BD%E3%83%95%E3%83%88%E3%82%A6%E3%82%A7%E3%82%A2) を読み進めていきます。

- USBでPCと接続するとシリアルポートとして認識される
  - ボーレートがわからない。MicroPythonはだいたい `115200` であることが多いのでそれで試してみる？
- [SIM7672](https://mechatrax.github.io/microcat1/SIM7672.html) というクラスが提供されている
  - これを使うとLTE接続ができそう？
- PSRAMが搭載されている
  - これはRP2350BのRAM(520KB)が足りなくなったときに頼れる外部RAM(8MB)という理解
  - 直近使う予定はないが、いつか使うときがくるかもしれない

最後に [ファームウェア](https://github.com/mechatrax/microcat1/wiki/%E3%83%95%E3%82%A1%E3%83%BC%E3%83%A0%E3%82%A6%E3%82%A7%E3%82%A2) も見ておきます。

- Raspberry Pi Pico2と同じ手順でファームウェアを書き込めるとのこと
  - おそらくブートモードで起動して、認識されるファイルシステムに対して、ファームウェアのバイナリをドラッグ・アンド・ドロップするやり方
  - これができるなら [PicoRuby](https://github.com/picoruby/picoruby) なども気軽に試せそう
- 現時点では [20251211](https://github.com/mechatrax/micropython/releases/tag/r20251211) からアップデートなし

## PCと接続してみる

まずはPCと接続してシリアル接続をしてみましょう。私のPCはmacOSであり、ターミナルエミュレータに [screen](https://formulae.brew.sh/formula/screen) を使いました。

```sh
# screenのインストール
$ brew install screen

# デバイスを確認 
$ ls -l /dev/tty.*
crw-rw-rw-  1 root  wheel  0x9000004 Jan 30 04:59 /dev/tty.Bluetooth-Incoming-Port
crw-rw-rw-  1 root  wheel  0x9000002 Jan 30 04:58 /dev/tty.debug-console
crw-rw-rw-  1 root  wheel  0x9000006 Jan 30 17:16 /dev/tty.soundcoreP40i
crw-rw-rw-  1 root  wheel  0x9000008 Jan 31 07:42 /dev/tty.usbmodem101
crw-rw-rw-  1 root  wheel  0x9000000 Jan 30 04:58 /dev/tty.wlan-debug

# screenで接続(/dev/tty.usbmodem101にボーレート115200で接続する)
$ screen /dev/tty.usbmodem101 115200
```

上記手順でコマンドを実行するとMicroPythonのREPLプロンプトが表示されました。

```sh
MicroPython v1.27.0-1.gfc07f56013 on 2025-12-11; MechaTracks MicroCat.1 with RP2350
Type "help()" for more information.
>>> 
```

この時点でPythonのコードを実行できます。

```sh
>>> 1 + 2
3
>>> 'aaa' + 'bbb'
aaabbb
>>> array = [1, 2, 3]
>>> array.append(4)
>>> array
[1, 2, 3, 4]
>>>
```

screenからの接続は `Ctrl+A` → `K` → `Y` の順で入力すると切断できます。

ちなみに `time` も使えたのですが、取得した時刻は数年前の日時(UnixTime)でした。
おそらくRTCを一度セットしてやる必要があるのだと推測しています。

```sh
>>> import time
>>> time.time()
1609459596 # 日本時間で2021年1月1日 09:06:36
```

`ticks_ms()` という関数を使うことで起動からのtick数が取得できるので、ひとまず検証にはこれを使うことにします。

```sh
>>> time.ticks_ms()
580953
```

## SORACOMにデータを送信してみる

SORACOMにデータを送信します。送信されたデータを確認する手段として [SORACOM Harvest Data](https://soracom.jp/services/harvest/) を使います。次のドキュメントを参考にお手持ちのSORACOMアカウントで、SORACOM Harvest Dataを有効化しておきましょう。

https://users.soracom.io/ja-jp/docs/harvest/enable-data/

MicroCat.1のドキュメントだけだとLTE接続してSORACOMにデータを送信する方法が読み取れませんでしたが、プレリリースが発表された際のPDFファイルにサンプルコードが記述されています。

https://mechatrax.com/uploads/microcat1-pre-flyer-correct.pdf

ひとまずこれを写経してみます。(ただし、そのままだと動作しない部分があったので一部変更しています)

```python
import SIM7672
import requests
import time

m = SIM7672.modem()
m.active(True)
m.connect('soracom.io', 'sora', 'sora', 'IP', 3)
time.sleep(5)

while True:
    data = time.ticks_ms()
    res = requests.post('http://harvest.soracom.io', json=data)
    res.close()
    time.sleep(10)
```

MicroCat.1とシリアル接続して、上記コードをREPLにコピー・アンド・ペーストします。複数行一気に貼り付けて大丈夫です。

LTEとの接続中は青いLEDが点灯し、接続に成功すると点滅に変わるようです。

![](/images/getting_started_micro-cat-1/003.jpeg)

しばらく稼働させた後、SORACOM Harvest Dataのダッシュボードを表示すると、リソースを選択すると次のようなグラフが表示されます。

![](/images/getting_started_micro-cat-1/001.png)

上記プログラムは無限ループをしていますが、キーボードで `Ctrl+C` を入力すれば中断できます。

## プログラムを保存する

毎回プログラムをREPLにコピペするのは大変なので、マイコン中のファイルシステムにソースコードを保存してみます。

次のプログラムをREPLに貼り付けることで `harvest.py` を保存できます。

```python
filename = 'harvest.py'
program = '''import SIM7672
import requests
import time

m = SIM7672.modem()
m.active(True)
m.connect('soracom.io', 'sora', 'sora', 'IP', 3)
time.sleep(5)

while True:
    data = time.ticks_ms()
    res = requests.post('http://harvest.soracom.io', json=data)
    res.close()
    time.sleep(10)
'''

with open(filename, 'w') as f:
    f.write(program)
```

保存したファイルは、次のように `import` することで実行ができます。

```sh
>>> import harvest.py
```

ちなみに、ファイル名を `main.py` にしておくと、MicroCat.1の起動直後にプログラムを自動実行させることもできます。

この場合、シリアル接続してもREPLのプロンプトが表示されなくなりますが、 `Ctrl+C` を入力することで自動実行したプログラムを中断してREPLに切り替えられます。

```sh
# 自動実行したプログラムをCtrl+Cで中断
Traceback (most recent call last):
  File "main.py", line 14, in <module>
KeyboardInterrupt: 
MicroPython v1.27.0-1.gfc07f56013 on 2025-12-11; MechaTracks MicroCat.1 with RP2350
Type "help()" for more information.
>>>
```

## まとめ

MicroPythonの知識が多少必要ではありますが、Webエンジニアが扱いやすいSORACOM IoT SIMに対応したデバイスが登場したこと自体は朗報です。

普段業務で取り組んでいるIoT開発をますます加速させられそうで、今後がより楽しみになりました。

