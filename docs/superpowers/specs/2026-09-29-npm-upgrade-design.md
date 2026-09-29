# npm-upgrade 設計仕様書

## 1. 概要
`npm-upgrade` は、Node.js プロジェクト（特に Cloud Functions for Firebase や GCP Cloud Functions を含むバックエンド/フルスタックプロジェクト）において、メジャーバージョンを含む依存パッケージの一括アップグレード、自動修正、ビルド/静的検証、セキュリティ診断（npm audit）、CHANGELOG/リリースノートの抽出とAI要約、網羅的なPR起票、そして**マージタイミングでのCloud Functions等への自動デプロイ設定の検証・構築**をシームレスに行うスキルです。

---

## 2. ゴール & 非ゴール
### ゴール
- `dart-pub-upgrade` と同様に、メジャーバージョンを含む全依存パッケージの一括アップグレードを自動実行できること。
- ロックファイルの差分を正確に解析し、直接依存（dependencies / devDependencies）と間接依存（transitive）を識別して差分データを抽出できること。
- `npm audit` によるセキュリティ診断結果を取り込み、既知の脆弱性への対応状況を明示できること。
- `lint --fix` / `format` 等の自動修正を行い、差分があれば個別コミットを作成すること。
- `build` / `test` 等の静的検証を行い、ビルド成否を確認すること。
- 対象リポジトリにおいて「mainブランチマージ時のCloud Functions自動デプロイ（GitHub Actions）」が構成されているかを点検し、未設定の場合はOIDC連携ベースのワークフロー作成を支援すること。
- すべての更新パッケージを網羅した詳細なPR本文を生成し、`gh pr create` で起票すること。

### 非ゴール
- 単なるパッケージ個別対話調査（`npm explain` や `diff_lock.py` のみを提供するツール）にとどまること（対話的調査は必要に応じて補足として利用するが、メインは全自動アップグレード＆PR＆デプロイ担保）。

---

## 3. ディレクトリ構成
```
npm-upgrade/
├── SKILL.md                          # スキルのメイン定義、エージェント手順、PRテンプレート
├── scripts/
│   ├── package.json                  # スクリプトメタデータ
│   └── bin/
│       └── npm-upgrade.mjs           # Node.js ネイティブ ESM CLI スクリプト
└── references/
    └── deploy-functions.md           # Cloud Functions (Firebase / GCP) の GHA デプロイ設定リファレンス
```

---

## 4. コンポーネント詳細設計

### 4.1 CLI スクリプト (`scripts/bin/npm-upgrade.mjs`)
外部依存パッケージを極力排除し、Node.js 18+ の標準ライブラリ（`node:fs`, `node:path`, `node:child_process`, `node:https` 等）および `npx npm-check-updates` を利用して動作。

- **オプション**:
  - `--path <path>`: 対象プロジェクトディレクトリ（デフォルト: `.`）
  - `--fix`: `lint --fix` 等の自動修正を実行するか（デフォルト: `true`）
  - `--verify`: `build` / `test` の検証を実行するか（デフォルト: `true`）
  - `--audit`: `npm audit` を実行して脆弱性情報を取得するか（デフォルト: `true`）
- **主要処理ステップ**:
  1. **Git状態チェック**: 未コミット変更の検知、リポジトリルート特定。
  2. **パッケージマネージャ判定**: `package-lock.json` (npm), `pnpm-lock.yaml` (pnpm), `yarn.lock` (yarn)。
  3. **既存バージョンのスナップショット**: lockfile および `package.json` から現在のバージョンマップを取得。
  4. **トピックブランチ作成**: `chore/deps/upgrade-npm-packages-YYYYMMDD` をチェックアウト。
  5. **アップグレード実行**:
     - `npx npm-check-updates -u` で `package.json` の制約を最新に更新。
     - `npm install`（または `pnpm install` / `yarn install`）で lockfile を更新。
  6. **更新差分の抽出**:
     - 更新前後の lockfile を比較し、アップグレードされた全パッケージ一覧を作成。
     - `package.json` を走査し、`isDirect`（直接依存か間接依存か）を判定。
  7. **npmレジストリ API & セキュリティ監査**:
     - npm registry API (`https://registry.npmjs.org/<pkg>`) を参照し、リポジトリURL（GitHub等）を取得。
     - `npm audit --json` を実行し、アドバイザリ情報をパース。
     - `.npm_upgrade/changelog_diffs.json` に差分メタデータを出力。
  8. **アップグレードコミット**: `chore(deps): パッケージの一括アップグレード` をコミット。
  9. **自動修正の実行**:
     - `npm run lint -- --fix` や `npm run format` を試行。差分があれば `fix(deps): パッケージ変更に伴う自動修正` をコミット。
  10. **ビルド・型チェック検証**:
      - `npm run build` や `npx tsc --noEmit`、`npm test` を実行し、結果を出力。

### 4.2 マージ時デプロイの自動点検・構築連携 (`deploy-functions.md` & SKILL.md)
Cloud Functions を含むプロジェクトにおいて、マージ後にデプロイが確実に行われることを担保します。
1. **ワークフローの点検**:
   - リポジトリの `.github/workflows/` 以下に、`main` / `master` への push / merge で発火するデプロイワークフローが存在するか検索（`firebase deploy`, `google-github-actions/deploy-cloud-functions` などのキーワード検査）。
2. **未設定時の自動構築**:
   - `firebase.json` が存在し、functions が設定されている場合：
     - Google Cloud / Firebase の Workload Identity Federation (OIDC) を用いた安全なデプロイワークフロー（`.github/workflows/deploy-functions.yaml`）の雛形を生成・提案（リポジトリ内の `github-actions-oidc` スキルと完全連携）。
3. **PR本文への記録**:
   - PRの「マージ時のデプロイ」セクションに、自動デプロイワークフロー名、対象リージョン/プロジェクト、または手動デプロイの要否を記録。

### 4.3 PR起票テンプレートと最終出力
- **PR本文構成**:
  - `## 概要`: アップグレード全体の目的とサマリー
  - `## 🚨 特に注目すべき重要な変更点`: 破壊的変更・メジャーアップデート（直接依存を中心に要約）
  - `## 🛠️ 自動修復・ビルド検証結果`: lint fix、build、typecheck、test の結果
  - `## 🔒 セキュリティ診断 (npm audit)`: 解決した脆弱性・残存する脆弱性
  - `## 🚀 マージ時デプロイ (Cloud Functions等)`: 自動デプロイワークフロー状況、反映対象
  - `## ⚠️ 手動対応・要確認が必要な点`: ビルドエラーや要動作確認事項（ある場合は Draft PR、ない場合は通常の PR）
  - `## 📦 アップグレードされたパッケージ詳細`:
    - 直接依存: パッケージ名（旧 ➔ 新）、npm/GitHubリンク、CHANGELOG要約
    - 間接依存: パッケージ名（旧 ➔ 新）、npmリンク（100%全件記載、省略厳禁）
- **最終出力**:
  - `PULL_REQUEST_URL: <URL>` または `PULL_REQUEST_URL: none`

---

## 5. テスト・検証戦略
- スクリプト単体動作テスト（ローカルでダミーの Node.js / package.json を作成して `npm-upgrade.mjs` の引数パース、判定、diff抽出のユニットテストを実施）。
- SKILL.md の記述が Dart Skills CLI 1.0 仕様およびリポジトリルールに完全に準拠していることの確認。
