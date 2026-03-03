# Lifecycle

Dialupページのライフサイクル（mount → handle_event → render）について。

## 概要

### ライフサイクルの全体像

（各フェーズの概要図）

## Mountフェーズ

### mount/2の役割

（初期化処理の説明）

### mount/1との使い分け

（静的ページ vs 動的ページ）

### params引数の詳細

（URLパラメータの構造）

### 初期化のベストプラクティス

（何をmountで行うべきか）

## Renderフェーズ

### render/1の役割

（HTML生成のタイミング）

### HEExテンプレート

（~Hと.html.heexの使い分け）

### assignsへのアクセス

（@記法の使い方）

## Eventフェーズ

### handle_event/3の概要

（イベント受信と処理）

### イベントの種類

（ws-click, ws-submitなど）

### 返り値の種類

（:noreply, :update, :patch）

## ライフサイクルの遷移

### 初回アクセス時

（HTTPリクエスト時の流れ）

### WebSocket接続後

（WS経由での更新）

### ページ遷移時

（__navigate時の動作）

## 特殊なケース

### エラー時の挙動

（例外発生時）

### 再接続時

（WebSocket再接続時）

---

*関連ガイド: [State Management](./state-management.md), [Events](./events.md)*
