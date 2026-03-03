# State Management

Dialupにおける状態（assigns）の管理方法。

## 概要

### assignsとは

（基本概念の説明）

### サーバーサイド状態の特徴

（HTTPセッションとは異なる点）

## assignsの構造

### 標準的なキー

（params, inner_contentなど）

### カスタムデータの保持

（ユーザー定義のキー）

## 状態のライフサイクル

### ページ遷移時の状態

（共通プレフィックスの保持）

### レイヤーごとの独立性

（各layout/pageのstate分離）

## 状態の更新方法

### mount時の初期化

（set_defaultの使い方）

### イベントでの更新

（overwriteの使い方）

### 部分更新 vs 全体更新

（:patchと:updateの使い分け）

## 永続化の考慮

### volatileな状態

（プロセス終了で失われる）

### DBへの永続化

（必要なデータの保存）

## ベストプラクティス

### 状態の粒度

（何をassignsに含めるか）

### メモリ使用量の考慮

（大きなデータの扱い）

---

*関連ガイド: [Lifecycle](./lifecycle.md), [Events](./events.md)*
