---
title: "子供に頼まれてMinecraft Forge Server 1.12.2をAWS上に立てるお仕事をした"
emoji: "🌏"
type: "tech" # tech: 技術記事 / idea: アイデア
topics:
  - Minecraft
  - Forge
  - AWS
  - EC2
published: true
published_at: "2024-05-07 07:30"
publication_name: "fusic"
---

我が家の子供はMinecraft(以下マイクラ)が大好きで、日々マイクラで何かを作っています。
私自身、マイクラのことはよく知らないのですが、マイクラでちょっと凝ったものを作ろうとするとModと呼ばれるものを入れるらしく、Modを入れると手持ちのノートPCだと重くなってしまうという問題があるとのこと。

普段はノートPC上にマイクラを起動して遊んでいるのですが、Modを入れても快適に遊ぶ方法の1つに「別のマシン上にサーバーを立てる」という方法があるようです。そこで、私がAWS上にサーバーを立てることになりました。

「2〜3時間で終わるだろう」と軽い気持ちで作業を始めたのですが、子供から提示された要件が想定以上にシビアで2〜3人日の作業になってしまいました...

## 私の属性

- AWSを使ったお仕事をしている
- マイクラのことは何もわからない
- マイクラが大好きな子供(9歳)がいる

## 子供から提示された要件

今回、子供からは以下のような要件が提示されました。なお、実際には作業を進めていく上でこれらの要件がクリアになっていったので、手戻りの連続でした。。。

- マイクラのバニラサーバーではなく、Minecraft Forgeと呼ばれるMODシステムを持ったサーバーを立てる必要がある
- Minecraft Forgeのバージョンは `1.12.2` であること
    - 子供が使用したいModが対応しているバージョンが `1.12.2` のため
        - https://www.curseforge.com/minecraft/mc-mods/realtrainmod
- Modが導入されていること
- ワールドは「スーパーフラット」であること
    - 最初は「スーパーフラット」ってなんやねん...という状況でしたが、こういうものらしいです。
        - https://minecraft.fandom.com/ja/wiki/%E3%82%B9%E3%83%BC%E3%83%91%E3%83%BC%E3%83%95%E3%83%A9%E3%83%83%E3%83%88

ちなみに、普通にマイクラで遊ぶだけであれば、AWSのブログにとてもわかり易い記事があり、これを参考に作業すれば立ち上がります。

https://aws.amazon.com/jp/blogs/news/setting-up-a-minecraft-java-server-on-amazon-ec2/

:::message
この記事について、ユーザーデータのスクリプト中でインストールしている `java-17-amazon-corretto-headless` だと、最新版のマインクラフト `1.20.6` は起動できませんでした。
代わりに `java-21-amazon-corretto-headless` をインストールするようにしましょう。
:::

## EC2インスタンスを立てる

ひとまず、EC2インスタンスを立てるところから始めます。初めて作業する人は以下の記事がわかりやすいです。

https://dev.classmethod.jp/articles/creation_vpc_ec2_for_beginner_1/
https://dev.classmethod.jp/articles/creation_vpc_ec2_for_beginner_2/

記事の手順から変更する必要がある点をまとめます。

- セキュリティグループの設定で `インバウンド TCP 25565` を追加で許可しておく
- EC2のAMIを選択する際にアーキテクチャを `64 ビット (Arm)` とし、 `Amazon Linux 2023 AMI` を選択する
- EC2のインスタンスタイプは `t4g.medium` を選択する
    - `t4g.small` でも問題ないかもしれませんが、Modを使うとのことで2GBのメモリを割り当てる想定をして `t4g.medium` を選択しました

## Java 8をインストール

ここも試行錯誤の末に至った結論ですが、Minecraft Forge 1.12.2はJava 8でないと動作しないようです。

https://www.kkaneko.jp/tools/minecraft/minecraft1122forge.html

以下のサイトからARM版のrpmファイルをダウンロードします。

https://www.oracle.com/jp/java/technologies/javase/javase8u211-later-archive-downloads.html

ダウンロードしたファイルはSCPコマンドを使うなどして、EC2インスタンスにアップロードします。
そのEC2インスタンスにSSHログインし、以下のコマンドを実行することで、Java 8をインストールします。

```sh
$ sudo yum localinstall jdk-8u401-linux-aarch64.rpm
```

## Minecraft Forgeをインストール

ここからMinecraft Forgeをインストールします。

最新版であれば公式ドキュメントや参考になるサイトがたくさんあるのですが、古いバージョンをインストールするため手順が最新版とは少し異なっています。

### jarファイルのダウンロード

こちらのページからバージョン1.12.2の「Installer」と「Universal」のファイルをそれぞれダウンロードします。

https://files.minecraftforge.net/net/minecraftforge/forge/index_1.12.2.html

ダウンロードしたファイルはSCPコマンドを使うなどしてEC2インスタンスにアップロードします。

### インストール

ここからはEC2インスタンス上で作業します。
次のようにコマンドを実行してディレクトリを作成し、jarファイルがディレクトリの中に格納された状態にします。
`x` の部分は実際のファイル名に合わせてください。

```sh
$ mkdir forge_server
$ mv ~/forge-1.12.2-xx.xx.x.xxxx-installer.jar ./forge_server
$ mv ~/forge-1.12.2-xx.xx.x.xxxx-universal.jar ./forge_server
$ cd forge_server
```

次のコマンドで、Installerを実行します。

```sh
java -jar ./forge-1.12.2-xx.xx.x.xxxx-installer.jar nogui --installServer
```

### サーバーの起動

次のコマンドでUniversalのファイルを実行します。EULA(使用許諾契約)がまだなのでエラーが発生します。

```sh
java -Xms2048M -Xmx2048M -jar forge-1.12.2-xx.xx.x.xxxx-universal.jar nogui
```

このとき、同じディレクトリに生成された `eula.txt` をエディタで開き、以下のように編集します。

```sh
vi eula.txt

#By changing the setting below to TRUE you are indicating your agreement to our EULA (https://account.mojang.com/documents/minecraft_eula).
#Sat May 04 22:55:58 UTC 2024
eula=true # ここをfalse→trueに変更
```

再度同じコマンドを実行することでサーバーが起動します。

```sh
java -Xms2048M -Xmx2048M -jar forge-1.12.2-xx.xx.x.xxxx-universal.jar nogui
```

## Minecraftの環境を整備する

### Modのインストール

インストールを実行したディレクトリに `mods` というディレクトリが生成されています。ここに、Modファイルを投げ込むことでインストールできます。
今回は、以下の2つのModを導入しました。

- https://www.curseforge.com/minecraft/mc-mods/realtrainmod
- https://www.curseforge.com/minecraft/mc-mods/ngtlib

### コマンド実行

サーバーが起動すると、プロンプトが表示され、ここでMinecraftのコマンドを実行できます。
今回は子供からもらった情報を元に、以下のように入力しておきました。

```
/gamemode c @a                  # 全てのプレイヤーをクリエイティブモードに変更
/op (プレイヤー名)                # プレイヤーにオペレータ権限を付与
/time set day                   # ワールドを昼にする
/gamerule doDaylightCycle false # 昼と夜の切り替えをOFFにする
```

### ワールドをスーパーフラットにする

インストールを実行したディレクトリにある `server.properties` を開いて、 `level-type` を変更します。

```sh
vi server.properties

level-type=FLAT # DEFAULT→FLATに変更
```

## その後対応したこと

効率的にサーバーを運用するために以下ポストの対応をしています。
DiscordのSlash Commandを実現するのも結構な作業だったので、機会があれば別途記事を書きたいと思います。

https://twitter.com/Y_uuu/status/1787443625066102803

## まとめ

子供が遊んでいるゲームくらいの認識でしかなかったマイクラですが、サーバーを立てるとなるとLinuxやクラウドの知識が必須の作業で、なかなか大変ということがわかりました。

お子様に「サーバーを立ててほしい」と言われた際は、具体的にどういうサーバーが欲しいのかしっかりヒアリングしてから作業するようにしましょう💦

## 参考

- https://mc.server-memo.net/forge_server_install/
