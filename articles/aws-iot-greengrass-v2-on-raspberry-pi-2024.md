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


なお、インストーラを実行するための認証情報は `IAM ユーザーからの長期的な認証情報を使用する:` の方法にて設定しました。IAMポリシーは以下ページを参考に必要最低限のものに絞っています。

https://docs.aws.amazon.com/ja_jp/greengrass/v2/developerguide/provision-minimal-iam-policy.html

`account-id` となっているところを自分のAWSアカウントのIDに置き換えるのを忘れないようにしましょう。

```sh
Encountered error - User: arn:aws:iam::xxxxxxxxxxxx:user/yuuu-raspberrypi is not authorized to perform: iam:GetPolicy on resource: policy arn:aws:iam::aws:policy/GreengrassV2TokenExchangeRoleAccess because no identity-based policy allows the iam:GetPolicy action (Service: Iam, Status Code: 403, Request ID: a2a240ea-fc0f-4c4e-819e-ebbd19d256c8); No permissions to lookup managed policy, looking for a user defined policy...
```

Raspberry Piにログインして次のコマンドを実行します。

```sh
# 認証情報の設定
export AWS_ACCESS_KEY_ID=<AWS_ACCESS_KEY_ID>
export AWS_SECRET_ACCESS_KEY=<AWS_SECRET_ACCESS_KEY>


# Javaのインストール
sudo apt update -y && sudo apt install default-jdk -y && java --version

# インストーラのダウンロード(数分かかりました)
curl -s https://d2s8p88vqu9w66.cloudfront.net/releases/greengrass-nucleus-latest.zip > greengrass-nucleus-latest.zip && unzip greengrass-nucleus-latest.zip -d GreengrassInstaller

# インストーラの実行(数分かかりました)
sudo -E java -Droot="/greengrass/v2" -Dlog.store=FILE -jar ./GreengrassInstaller/lib/Greengrass.jar --aws-region ap-northeast-1 --thing-name yuuu-raspberry-pi  --component-default-user ggc_user:ggc_group --provision true --setup-system-service true --deploy-dev-tools true

# ステータス確認(active, enabledと表示されればOK)
sudo systemctl status greengrass.service
```

インストールに成功すると、AWSコンソールの 「Greengrassデバイス→コアデバイス」のページに、セットアップしたコアデバイスが表示されます。

![](https://storage.googleapis.com/zenn-user-upload/eff821ed24f7-20240322.png)

## コンテナコンポーネントの作成

コンテナコンポーネントを作成するため、まずDocker Engineをインストールします。
[Install script](https://docs.docker.com/engine/install/ubuntu/#install-using-the-convenience-script) を使って簡単にインストールできます。

```sh
# Docker Engineのインストール(数分かかりました)
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh

# コンテナ実行権限の付与
sudo usermod -aG docker ggc_user
```

手元のPCで次のコマンドを実行します。

```sh
aws ecr create-repository --repository-name hello-greengrass-container
aws ecr get-login-password --region ap-northeast-1 | docker login --username AWS --password-stdin <ACCOUNT_ID>.dkr.ecr.ap-northeast-1.amazonaws.com

mkdir hello-greengrass-container
cd hello-greengrass-container
touch hello.rb Dockerfile
echo 'puts "Hello, AWS IoT Greengrass!"' >> hello.rb

# dockerfileを作る
```
