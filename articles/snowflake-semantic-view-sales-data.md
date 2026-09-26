---
title: "商品の販売データを例にSnowflake Semantic Viewの活用方法を考えてみる"
emoji: "❄️"
type: "tech" # tech: 技術記事 / idea: アイデア
topics:
  - snowflake
  - semanticview
  - cortex
published: false
publication_name: fusic
---

## はじめに

TODO: Semantic Viewとは何か（テーブル・カラムに対して「商品名」「売上合計」のようなビジネス用語の意味付けを行う機能）、この記事で実現すること（商品マスタ・売上データを例にSemantic Viewを作り、集計クエリで問い合わせる）を書く。あわせて、単なる構文紹介に留めず「Cortex Analyst（自然言語AI）から使うことを見据えて、日本語でどう意味付け（`WITH SYNONYMS` / `COMMENT`）を設計すると問い合わせ精度が変わるか」を検証するのが本記事の軸である旨を書く。

## 事前準備

TODO: Snowflake CLIの接続設定へのリンク

https://zenn.dev/fusic/articles/snowflake-cli-oauth

https://zenn.dev/fusic/articles/snowflake-cli-install-with-mise

## サンプルデータを投入する

TODO: 商品マスタ・売上テーブルのDDLとダミーデータ投入（`snow sql -f`）

## Semantic Viewを作成する

TODO: `CREATE SEMANTIC VIEW ... TABLES (...) RELATIONSHIPS (...) FACTS (...) DIMENSIONS (...) METRICS (...)` の実行と、各句（TABLES/RELATIONSHIPS/FACTS/DIMENSIONS/METRICS）が何を表すかの説明

## 日本語での意味付け（COMMENT・SYNONYMS）を設計する

TODO: `WITH SYNONYMS`（別名の完全な候補を列挙する）と`COMMENT`（LLMが意味を推測する手がかりになる自然文）の役割の違いを説明する。あえて一部の業務用語（「客単価」「商品ジャンル」）を最初はSYNONYMSに含めずにSemantic Viewを作った理由（後段でBefore/Afterを比較するため）を書く。

## Semantic Viewに問い合わせる

TODO: `SELECT * FROM SEMANTIC_VIEW(...)` 構文でのカテゴリ別集計・月別推移・WHERE句によるフィルタ・FACTSでの明細取得の実行結果と、素のSQL（GROUP BY）との比較結果

## Cortex Analystから自然言語で問い合わせる（発展）

TODO: 実機検証がうまくいった場合のみ、Semantic ViewをMCPサーバー経由でClaude Desktopから自然言語で問い合わせた結果を書く。うまくいかなかった場合はこの章ごと削除する。

### そのまま日本語で聞いてみる

TODO: 「カテゴリ別の売上合計を教えて」等の質問と、実際の回答・ツール呼び出し内容

### シノニムを追加する前後で回答精度を比較する

TODO: 「客単価を教えて」「商品ジャンルごとの売上を見せて」といった、SYNONYMSに未登録の業務用語で質問した場合の結果（Before）と、`ALTER SEMANTIC VIEW`でシノニムを追加した後に同じ質問をした結果（After）を比較し、日本語での意味付けが自然言語AIからの問い合わせ精度にどう影響するかを考察する。これが本記事のメインの気づきになる想定。

## クリーンアップ

TODO: 作成したオブジェクトの削除手順

## おわりに

TODO: Semantic Viewを使ってみた所感（従来のビューやCortex Analystのセマンティックモデルとの違い、日本語での意味付け設計の勘所など）とまとめ
