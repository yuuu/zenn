---
title: "C Extensionを含むRuby Gemの作り方"
emoji: "💎"
type: "tech" # tech: 技術記事 / idea: アイデア
topics:
  - Ruby
  - C
published: true
published_at: "2025-09-15 18:00"
publication_name: "fusic"
---

![](https://storage.googleapis.com/zenn-user-upload/9534ecf93be5-20250915.png)

Rubyには数多くのライブラリ（Gem）が公開されており、アプリケーション開発を効率的に進めるうえで欠かせない存在となっています。その中でも、Rubyだけでは表現しにくい高速な処理や既存のC言語ライブラリを活用する場合に用いられるのが C Extension(日本語でC言語拡張) です。

C Extensionを含むGemの作成方法については、これまでも多くの記事や資料が存在します。しかし、検索で見つかる情報の多くは古く、Rubyやビルドツールのバージョン差異により、手順通りに進めてもエラーが出てしまうケースが少なくありません。

そこで本記事では、2025年時点で実際に動作確認できた最新の手順をまとめます。

## 前提

次のコマンドがインストールされていること。

| コマンド | バージョン |
|--------|------------|
| ruby   | 3.4.5      |
| gem    | 3.6.9      |
| bundler | 2.6.9 |
| gcc    | Apple clang version 17.0.0 |
| make   | 3.81       |

バージョンは私が動作確認したときのものです。OSはmacOS(Apple Silicon)を使用しています。

## お題

今回はお題としてトランプカード(PlayingCard)を表現するクラスを作成します。

- カードは数字とマークを持つ
- `Card#number` で数字を、 `Card#mark` でマークを取得可能
- `==` は数字とマークが一致すれば `true` を返す

## 実装

### Gemの作成

Ruby Gemの雛形を作成します。 `playing_cards` は作成するGemの名前です。 `--ext` オプションを付与することでC Extensionを使用するための雛形も生成してくれます。

```sh
$ bundle gem playing_cards --ext
$ cd playing_cards
```

このままだと `bundle exec rake build` したときにエラーが出ます。

```sh
$ bundle exec rake build
/opt/homebrew/bin/gmake install sitearchdir=../../../../lib/playing_cards sitelibdir=../../../../lib/playing_cards target_prefix=
/usr/bin/install -c -m 0755 playing_cards.bundle ../../../../lib/playing_cards
cp tmp/arm64-darwin24/playing_cards/3.4.5/playing_cards.bundle tmp/arm64-darwin24/stage/lib/playing_cards/playing_cards.bundle
rake aborted!
Running `gem build -V /Users/yuhei/ghq/github.com/yuuu/playing_cards/playing_cards.gemspec` failed with the following output:

WARNING:  See https://guides.rubygems.org/specification-reference/ for help
ERROR:  While executing gem ... (Gem::InvalidSpecificationException)
    metadata['homepage_uri'] has invalid link: "TODO: Put your gem's website or public repo URL here."
```

エラーを回避するため `playing_cards.gemspec` を次のように修正します。

```diff:playing_cards.gemspec
diff --git a/playing_cards.gemspec b/playing_cards.gemspec
index 203fbb9..8f43b11 100644
--- a/playing_cards.gemspec
+++ b/playing_cards.gemspec
@@ -8,17 +8,17 @@ Gem::Specification.new do |spec|
   spec.authors = ["Yuhei Okazaki"]
   spec.email = ["okazaki@fusic.co.jp"]
 
-  spec.summary = "TODO: Write a short summary, because RubyGems requires one."
-  spec.description = "TODO: Write a longer description or delete this line."
-  spec.homepage = "TODO: Put your gem's website or public repo URL here."
+  spec.summary = "Write a short summary, because RubyGems requires one." # TODOを消す
+  # spec.description = "TODO: Write a longer description or delete this line." # コメントアウト
+  # spec.homepage = "TODO: Put your gem's website or public repo URL here." # コメントアウト
   spec.license = "MIT"
   spec.required_ruby_version = ">= 3.1.0"
 
   spec.metadata["allowed_push_host"] = "TODO: Set to your gem server 'https://example.com'"
 
-  spec.metadata["homepage_uri"] = spec.homepage
-  spec.metadata["source_code_uri"] = "TODO: Put your gem's public repo URL here."
-  spec.metadata["changelog_uri"] = "TODO: Put your gem's CHANGELOG.md URL here."
+  # spec.metadata["homepage_uri"] = spec.homepage # コメントアウト
+  # spec.metadata["source_code_uri"] = "TODO: Put your gem's public repo URL here." # コメントアウト
+  # spec.metadata["changelog_uri"] = "TODO: Put your gem's CHANGELOG.md URL here." # コメントアウト
 
   # Specify which files should be added to the gem when it is released.
   # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
```

これでビルドが通るようになります。

```sh
$ bundle exec rake build
/opt/homebrew/bin/gmake install sitearchdir=../../../../lib/playing_cards sitelibdir=../../../../lib/playing_cards target_prefix=
/usr/bin/install -c -m 0755 playing_cards.bundle ../../../../lib/playing_cards
cp tmp/arm64-darwin24/playing_cards/3.4.5/playing_cards.bundle tmp/arm64-darwin24/stage/lib/playing_cards/playing_cards.bundle
playing_cards 0.1.0 built to pkg/playing_cards-0.1.0.gem.
```

### クラスやメソッドの定義

`ext/playing_cards/playing_cards.c` がC ExtensionのC言語ソースです。今回は次のように記述することでクラスやメソッドを定義しました。

```c:ext/playing_cards/playing_cards.c
#include "playing_cards.h"

typedef struct {
  int number;
  VALUE mark;
} Card;

static void card_mark_func(void *ptr)
{
  Card *c = (Card *)ptr;
  if (c && c->mark) rb_gc_mark(c->mark);
}

static void card_free(void *ptr)
{
  xfree(ptr);
}

static const rb_data_type_t card_type =
{
  "Card",
  {card_mark_func, card_free, 0,},
  0, 0, RUBY_TYPED_FREE_IMMEDIATELY,
};

static VALUE
card_allocate(VALUE klass)
{
  Card *ptr;
  return TypedData_Make_Struct(klass, Card, &card_type, ptr);
}

static VALUE
card_initialize(VALUE self, VALUE number, VALUE mark)
{
  Card *ptr;
  TypedData_Get_Struct(self, Card, &card_type, ptr);

  int n = NUM2INT(number);
  if (n < 1 || n > 13) {
    rb_raise(rb_eArgError, "number must be between 1 and 13");
  }

  ptr->number = n;
  VALUE m = StringValue(mark);          // Ruby文字列に変換
  RB_OBJ_WRITE(self, &ptr->mark, m);    // write barrier 付きで保存

  return self;
}

static VALUE
card_number(VALUE self)
{
  Card *ptr;
  TypedData_Get_Struct(self, Card, &card_type, ptr);
  return INT2NUM(ptr->number);
}

static VALUE
card_mark(VALUE self)
{
  Card *ptr;
  TypedData_Get_Struct(self, Card, &card_type, ptr);
  return rb_str_dup(ptr->mark);
}

static VALUE
card_equal(VALUE self, VALUE other)
{
  if (CLASS_OF(self) != CLASS_OF(other)) return Qfalse;

  Card *p1, *p2;
  TypedData_Get_Struct(self, Card, &card_type, p1);
  TypedData_Get_Struct(other, Card, &card_type, p2);

  if (p1->number == p2->number && rb_str_equal(p1->mark, p2->mark)) {
    return Qtrue;
  }
  return Qfalse;
}

RUBY_FUNC_EXPORTED void
Init_playing_cards(void)
{
  VALUE cCard = rb_define_class("Card", rb_cObject);
  rb_define_alloc_func(cCard, card_allocate);
  rb_define_method(cCard, "initialize", card_initialize, 2);
  rb_define_method(cCard, "number", card_number, 0);
  rb_define_method(cCard, "mark", card_mark, 0);
  rb_define_method(cCard, "==", card_equal, 1);
}
```

`Init_playing_cards` が肝で、最初にこの関数が呼ばれることでクラスが定義され、RubyのメソッドとC言語の関数をつなぎ合わせています。この仕組みやmrubyやmruby/c(PicoRuby)でも同様ですね。

古い記事だと `Init_playing_cards` を定義するときに `RUBY_FUNC_EXPORTED` が使われていないことがあります。`RUBY_FUNC_EXPORTED` を省略すると、定義したクラスやメソッドが非公開となり、動作確認時に呼び出せなくなるので注意です。

## 動作確認

### ビルド

C Extensionを含むRuby Gemの動作確認をする際にはコンパイルが必要です。
次のようなコマンドを実行することでコンパイルします。

```sh
$ bundle exec rake compile
/opt/homebrew/bin/gmake install sitearchdir=../../../../lib/playing_cards sitelibdir=../../../../lib/playing_cards target_prefix=
/usr/bin/install -c -m 0755 playing_cards.bundle ../../../../lib/playing_cards
cp tmp/arm64-darwin24/playing_cards/3.4.5/playing_cards.bundle tmp/arm64-darwin24/stage/lib/playing_cards/playing_cards.bundle
```

### 実行

`irb` を起動して動作確認をしましょう。 `-I` は指定したディレクトリを読み込むオプション、 `-r` は予め `require` をするためのオプションです。

```sh
$ irb -Ilib -rplaying_cards
irb(main):001> c1 = Card.new(1, 'spade')
=> #<Card:0x0000000120f6d378>
irb(main):002> c2 = Card.new(2, 'spade')
=> #<Card:0x0000000124077450>
irb(main):003> c1 == c2
=> false
irb(main):004> c1 == c1
=> true
irb(main):005> c1.number
=> 1
irb(main):006> c1.mark
=> "spade"
```

もしくは次のようなワンライナーでの実行も可能です。

```sh
$ ruby -Ilib -rplaying_cards -e "c1 = Card.new(1, 'spade'); puts c1.number; puts c1.mark"
1
spade
```

## デバッグ

### 拡張機能のインストール

デバッグ環境を構築するために、VS Codeの拡張機能をインストールします。

https://marketplace.visualstudio.com/items?itemName=ms-vscode.cpptools-extension-pack

### コンパイルオプションの追加

`ext/playing_cards/extconf.rb` に次のようなコードを追加します。


```diff:ext/playing_cards/extconf.rb
diff --git a/ext/playing_cards/extconf.rb b/ext/playing_cards/extconf.rb
index 73f1e7a..feeb2ab 100644
--- a/ext/playing_cards/extconf.rb
+++ b/ext/playing_cards/extconf.rb
@@ -2,6 +2,11 @@
 
 require "mkmf"
 
+if ENV["DEBUG"]
+  CONFIG["optflags"] = "-O0"
+  CONFIG["debugflags"] = "-ggdb3"
+end
+
 # Makes all symbols private by default to avoid unintended conflict
 # with other gems. To explicitly export symbols you can use RUBY_FUNC_EXPORTED
 # selectively, or entirely remove this flag.
```

このコードは `DEBUG` という環境変数が定義されているときに、最適化を無効化し、デバッグフラグを有効化するものです。
次のコマンドでコンパイルしなおします。

```sh
$ bundle exec rake clean
$ DEBUG=1 bundle exec rake compile
```

### デバッガを起動

VS Codeを起動し、画面左側の「実行とデバッグ」をクリックします。

![](https://storage.googleapis.com/zenn-user-upload/988a998c0255-20250915.png)

次に「launch.jsonファイルを作成します」をクリックします。

![](https://storage.googleapis.com/zenn-user-upload/19e7379c3f1c-20250915.png)

「C++」をクリックします。

![](https://storage.googleapis.com/zenn-user-upload/ac5a701885a4-20250915.png)

「C/C++: (lldb)起動」をクリックします。

![](https://storage.googleapis.com/zenn-user-upload/45ebeffe0e28-20250915.png)

`program` には `ruby` コマンドの絶対パスを入力します。絶対パスは次のように確認します。

```sh
$ which ruby                                    
/Users/yuhei/.local/share/mise/installs/ruby/3.4.5/bin/ruby
```

`args` には `ruby` コマンドに渡すオプションを入力します。今回は `["-Ilib", "-rplaying_cards", "-e", "c1 = Card.new(1, 'spade'); c2 = Card.new(1, 'spade'); puts c1 == c2"]` のように入力しました。 `-e` の部分が実行したいRubyスクリプトです。

最終的に、 `launch.json` は次のようになりました。

```json:.vscode/launch.json
{
    "version": "0.2.0",
    "configurations": [
        {
            "name": "(lldb) Launch",
            "type": "cppdbg",
            "request": "launch",
            "program": "/Users/yuhei/.local/share/mise/installs/ruby/3.4.5/bin/ruby",
            "args": ["-Ilib", "-rplaying_cards", "-e", "c1 = Card.new(1, 'spade'); c2 = Card.new(1, 'spade'); puts c1 == c2"],
            "stopAtEntry": false,
            "cwd": "${workspaceFolder}",
            "environment": [],
            "externalConsole": false,
            "MIMode": "lldb"
        }
    ]
}
```

準備ができたら `F5` キーを入力して、デバッガをします。

このように、C言語のソースコードにブレイクポイントを設定しておくことで、プログラムを中断したり1行だけ実行したり、変数の値を確認したり、といったことが可能となります。

![](https://storage.googleapis.com/zenn-user-upload/5988cbe01ee1-20250915.png)

## 参考

- https://guides.rubygems.org/gems-with-extensions/
- https://blog.wataash.com/ja/ruby-c-extension/
- https://serpapi.com/blog/how-to-debug-ruby-c-extension-in-vs-code/