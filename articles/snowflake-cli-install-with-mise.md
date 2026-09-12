---
title: "Snowflake CLIをmiseでインストールする"
emoji: "❄️"
type: "tech" # tech: 技術記事 / idea: アイデア
topics:
  - "snowflake"
  - "mise"
  - "cli"
published: true
published_at: "2026-09-14 07:30"
publication_name: "fusic"
---

## はじめに

Snowflake CLIとは、Snowflakeが提供する開発者向けのコマンドラインツールです。
スピーディにアプリケーションを構築したり、SQLを実行したりすることができます。

https://docs.snowflake.com/ja/developer-guide/snowflake-cli/index

Snowflake CLIのインストール方法は[公式手順](https://docs.snowflake.com/ja/developer-guide/snowflake-cli/installation/installation) によると、

- Linuxの場合: debまたはrpmパッケージでインストールする
- macOSの場合: インストーラまたはHomebrewでインストールする
- Windowsの場合: インストーラでインストールする

となっています。

しかし、私は言語環境やCLIを [mise](https://mise.jdx.dev/) でインストールしています。
miseを使ってSnowflake CLIをインストールする方法を調べました。

## インストール方法

結論、次のコマンドでインストールできることがわかりました。

```sh
mise use -g uv pipx:snowflake-cli
```

ドキュメントに[高度なローカルインストール](https://docs.snowflake.com/ja/developer-guide/snowflake-cli/installation/installation#install-with-pipx)として記載されている [pipx](https://github.com/pypa/pipx) を使ったインストール方法です。
mise の `pipx:` バックエンドは、`uv` がインストールされていれば pipx 本体の代わりに内部で `uv tool install`（uvx相当）を使う仕様になっているため、事前に `uv` をインストールしておく必要があります。

:::message
例では `-g` オプションを付けていますがグローバルにインストールするか、ローカルにインストールするかは適宜選択してください。
:::

## miseにおけるpipxとは

pipxバックエンドとしてmiseの公式ドキュメントに記載があります。

https://mise.jdx.dev/dev-tools/backends/pipx.html

Pythonで作られたCLIをmiseに追加するためのバックエンドです。
名前はpipxですが、`uv` がインストールされていれば内部的にはpipxの代わりに `uv` を使い、CLIごとに独立した仮想環境(venv)を作ることで、他のpipライブラリとの依存関係の衝突を避けられる仕組みになっています。

## 接続設定

無事にSnowflake CLIをインストールできたら、接続設定もしておきましょう。
OAuthを使う前提であれば、私が以前公開したこちらの記事がおすすめです。

https://zenn.dev/fusic/articles/snowflake-cli-oauth

## おわりに

この方法であれば、OSがLinux, macOS, Windowsのどれであっても同じ方法でインストールできますし、miseの設定ファイルを移設すれば同じ環境を再現しやすいです。

すでにmiseを使っている方におすすめです。
