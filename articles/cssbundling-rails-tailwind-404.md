---
title: "cssbundling-railsでTailwindCSSを指定して404エラーが出たときの対処法"
emoji: "📝"
type: "tech" # tech: 技術記事 / idea: アイデア
topics:
  - ruby
  - rails
  - tailwindcss
published: true
published_at: "2025-10-20 17:15"
publication_name: "fusic"
---

久々に `rails new` したときに不可解なエラーが出たため、備忘録を残します。

## 発生した現象

`bin/dev` でRailsアプリケーションを起動しブラウザでアクセスし、DevToolを確認したところ「コンソール」や「ネットワーク」タブにて404エラーが表示される。

![](https://storage.googleapis.com/zenn-user-upload/ade20f3bbe64-20251019.png)
![](https://storage.googleapis.com/zenn-user-upload/65e855d2757a-20251019.png)

## 前提条件

- [CSS Bundling for Rails](https://github.com/rails/cssbundling-rails) ( `cssbundling-rails` )でTailwindCSS( `tailwind` )を指定している
    - 私は `rails new sample-app --javascript=esbuild --css=tailwind --skip-test` で新しいRailsアプリケーションを作成しようとして、本現象に直面しました。

## 対処方法

`cssbundling-rails` のIssuesに同様の問題と対処方法の記載がありました。

https://github.com/rails/cssbundling-rails/issues/175

`app/assets/stylesheets/application.tailwind.css` を`app/assets/tailwind/application.css` に移動・リネームします。

```sh
$ mkdir app/assets/tailwind
$ mv app/assets/stylesheets/application.tailwind.css app/assets/tailwind/application.css
```

このファイルは `package.json` から参照されているので、上記の移動後のパスに修正します。

```diff json:package.json
{
  "name": "app",
  "private": true,
  "devDependencies": {
    "esbuild": "^0.25.11"
  },
  "scripts": {
    "build": "esbuild app/javascript/*.* --bundle --sourcemap --format=esm --outdir=app/assets/builds --public-path=/assets",
-    "build:css": "npx @tailwindcss/cli -i ./app/assets/stylesheets/application.tailwind.css -o ./app/assets/builds/application.css --minify"
+    "build:css": "npx @tailwindcss/cli -i ./app/assets/tailwind/application.css -o ./app/assets/builds/application.css --minify"
  },
  "dependencies": {
    "@hotwired/stimulus": "^3.2.2",
    "@hotwired/turbo-rails": "^8.0.18",
    "@tailwindcss/cli": "^4.1.14",
    "tailwindcss": "^4.1.14"
  }
}
```

これで問題は回避できます。

![](https://storage.googleapis.com/zenn-user-upload/3d0f76ccaaa1-20251019.png)

## 原因

根本原因は不明ですが、 `app/assets/stylesheets` 配下に置かれているCSSファイルを、 `@tailwindcss/cli` と `esbuild` によって2重で処理してしまっているように見えました。修正前の「ネットワーク」タブを見ると、2つのCSSファイルに対してGETしてしまっているためです。

----

ちなみに、すでに対処のためのPull RequestもOpenされているので、これがマージされればこのような問題は発生しなくなると予想されます。

https://github.com/rails/cssbundling-rails/pull/174
