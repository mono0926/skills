---
name: git-commit-formatter
description: GitのコミットメッセージをConventional Commits仕様に従って日本語でフォーマットします。
---

# Git Commit Formatter Skill

Gitのコミットメッセージを作成する際は、**Conventional Commits** の仕様に従い、以下のルールを厳守してください。

## ルール

1. **言語**: メッセージは **日本語** で記述してください。ただし、ライブラリ名や固有名詞など（例: Google, Flutter, Firebase）は英語表記を使用してください。
2. **構造**:
   - **1行目**: 変更内容の簡潔な要約（`<type>[scope]: <description>`）。
   - **2行目**: 空行（詳細がある場合）。
   - **3行目以降**: 必要に応じて、変更の詳細理由や影響範囲を箇条書きで記述してください。
3. **参照情報**: 関連するドキュメントや参考ページがある場合は、URLや出典を具体的かつ明確に記述してください。

## フォーマット

```text
<type>[optional scope]: <description>

- <詳細内容1>
- <詳細内容2>
- Ref: <URLまたは関連情報>

```

## Typeの定義

- **feat**: 新機能
- **fix**: バグ修正
- **docs**: ドキュメントのみの変更
- **style**: コードの意味に影響しない変更（空白、フォーマットなど）
- **refactor**: バグ修正も機能追加も行わないコード変更（リファクタリング）
- **perf**: パフォーマンスを向上させるコード変更
- **test**: テストの追加・修正
- **chore**: ビルドプロセスやツール、ライブラリの変更

## 例

### 基本的な例

`feat(auth): Googleログインを実装`

### 詳細を含む例

```text
feat(auth): Googleログインを実装

- Firebase Authを使用してGoogleプロバイダを追加
- ログイン成功時にホーム画面へ遷移するロジックを実装
- エラーハンドリング（キャンセル時、ネットワークエラー時）を追加
- Ref: [https://firebase.google.com/docs/auth/flutter/google-signin](https://firebase.google.com/docs/auth/flutter/google-signin)

```
