# npm-upgrade 実装計画

## 目標
`dart-pub-upgrade` のワークフローと設計を踏襲し、Node.js / Cloud Functions プロジェクト向けに全自動でパッケージ一括アップグレード、自動修正、ビルド・静的検証、セキュリティ診断（npm audit）、CHANGELOG/差分要約、PR起票、およびマージ時Cloud Functions自動デプロイ設定の点検・構築を行うスキル `npm-upgrade` を実装する。

---

## 提案する変更

### 1. `npm-upgrade/references/deploy-functions.md` の作成
- Firebase Cloud Functions および GCP Cloud Functions 向けの GitHub Actions デプロイワークフローテンプレート集
- GitHub Actions OIDC (Workload Identity) を利用したセキュアなキーレスデプロイ設定手順（`github-actions-oidc` スキルと互換）
- `main` ブランチへの push / merge をトリガーとする設定

### 2. `npm-upgrade/scripts/` の作成
- `npm-upgrade/scripts/package.json`: 最小限のメタデータ（`"type": "module"`）
- `npm-upgrade/scripts/bin/npm-upgrade.mjs`:
  - 外部ランタイム依存なしで Node.js 18+ の標準機能で動作する ESM スクリプト
  - 未コミット変更検知、Gitルート検出、パッケージマネージャ判定（npm / pnpm / yarn）
  - トピックブランチ作成 (`chore/deps/upgrade-npm-packages-YYYYMMDD`)
  - `npx npm-check-updates -u` による最新メジャーバージョンへの更新と `npm install` 実行
  - lockfile の差分解析による更新パッケージ一覧（旧 ➔ 新）の抽出、直接依存（dependencies / devDependencies）vs 間接依存（transitive）の分類
  - `npm audit --json` による脆弱性スキャン情報の収集
  - npm registry API (`https://registry.npmjs.org/<pkg>`) から GitHub repository URL を取得
  - `.npm_upgrade/changelog_diffs.json` へのデータ書き出し
  - アップグレードコミット (`chore(deps): パッケージの一括アップグレード`)
  - 自動修正 (`npm run lint -- --fix` / `npm run format`) と差分コミット
  - 静的検証 (`npm run build` / `npm test` 等) の実行とログ出力

### 3. `npm-upgrade/SKILL.md` の作成
- YAML frontmatter (name, description)
- ワークフロー手順:
  1. `npm-upgrade.mjs` スクリプトの実行
  2. 静的解析・ビルド結果の確認と追加修正
  3. CHANGELOG / 差分データの読み込み
  4. マージ時デプロイ（Cloud Functions等）のワークフロー確認 & 未設定時の作成支援
  5. AIによる要約・分析およびPR本文生成（直接依存詳細・間接依存100%全件記載・デプロイ対象明記）
  6. `gh pr create` による起票（要確認事項の有無に応じた Draft / Ready 判定）
  7. クリーンアップ & 最終行 `PULL_REQUEST_URL: ...` 出力
- 📄 PR本文の標準テンプレート

### 4. `README.md` の更新
- ルートの `README.md` に `npm-upgrade` の説明とリンクを追加。

---

## 検証計画
1. **スクリプト動作検証**:
   - 一時ディレクトリにダミーの `package.json` と `package-lock.json` を用意し、Gitリポジトリを初期化。
   - `node scripts/bin/npm-upgrade.mjs --path <dummy_dir>` を実行し、lockfile の更新、ブランチ作成、コミット作成、差分 JSON 出力が正しく行われることを確認。
   - エラーハンドリング（未コミット変更がある場合のエラー終了等）を検証。
2. **静的検証・フォーマット確認**:
   - `npm-upgrade.mjs` の構文チェック（`node --check`）。
   - ドキュメント内の相対パスが正しくリンクされているか確認。
3. **リポジトリルール準拠の確認**:
   - 秘匿情報が含まれていないこと。
   - ニックネーム等の不要な記述がないこと。
   - 作業完了後に `main` ブランチに直接コミット・PUSH すること。
