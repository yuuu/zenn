---
title: "2024年版 Raspberry Pi上でAWS IoT Greengrassを動かすまでの手順書"
emoji: "🍀"
type: "tech" # tech: 技術記事 / idea: アイデア
topics:
  - "aws"
  - "awsiotcore"
  - "iot"
  - "raspberrypi"
published: false
---

## Raspberry Piの準備

Rasbpeery Piを使うため、以下のものを準備しました。
今回は手元にあったRaspberry Pi 4を使用しましたが、おそらく5でも同様に動作するはずです。

| 名前 | 詳細 | 用途 |
| ---- | ---- | ---- |
| シングルボードコンピュータ | Raspberry Pi 4 Model B | ボード上でLinuxを起動し、その上でAWS IoT Greengrassを動かす |
| microSDカード | KIOXIA class10 16GB | Raspberry Pi OSを焼き、ストレージとして使用 |
| マルチカードリーダー | ELECOM MR-C20BK | microSDカードの読み書きができれば何でもOK |

microSDカードにはRasbperry Pi OSを書き込みます。
現在(2024年)では、Raspberry Pi Imagerと呼ばれるツールが提供されているので、これをインストールして起動することで書き込みます。

https://www.raspberrypi.com/software/

Raspberry Pi Imagerを起動したら書き込みの設定ができます。今回は写真のように設定しました。
現在は、64bit版が推奨されています。

![](https://storage.googleapis.com/zenn-user-upload/9ab62921979a-20240315.png)

この画面が表示されたら、 `設定を編集する` をクリックしましょう。
デフォルトだとユーザー名やパスワードもデフォルトのままですし、SSHのポートも開いていないためです。

![](https://storage.googleapis.com/zenn-user-upload/9d54a7441f2f-20240315.png)

以下のように設定をしておきます。
ユーザー名はできれば `pi` 以外に変えておいた方が良いです。後の手順でmDNSでアクセスすることを考えると、ホスト名も他と重複しない名前にしておいたほうが良いですね。

![](https://storage.googleapis.com/zenn-user-upload/aafbb922ee79-20240315.png)

SSHを有効化します。できれば「公開鍵認証のみを許可する」を選択した方がセキュリティとしては望ましいです。

![](https://storage.googleapis.com/zenn-user-upload/a583113b91ad-20240315.png)

書き込みには10〜20分程度かかります。
起動したらSSHログインしましょう。

## AWS IoT Greengrassのセットアップ

AWS IoT Greengrassコンソールに表示されるコマンドをコピー&ペーストしていく方法でAWS IoT Greengrassコアソフトウェアをインストールします。
手順は以下のドキュメントを参考にしてください。

https://docs.aws.amazon.com/ja_jp/greengrass/v2/developerguide/install-greengrass-v2-console.html
