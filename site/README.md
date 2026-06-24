# Dialup 公式サイト

https://dialup-framework.org/

このディレクトリは [Dialup](https://github.com/SouichiroTsujimoto/Dialup) リポジトリ内の紹介サイトアプリです。フレームワーク本体はリポジトリルートの path 依存として参照します。

## ローカル開発

```bash
cd site
mix deps.get
mix compile
PORT=4001 mix run --no-halt
```

## Docker

リポジトリルートから:

```bash
docker compose up --build
```
