---
name: npm-upgrade
description: Upgrade npm/Node.js packages (including major versions), resolve warnings/errors, run security audit, extract CHANGELOGs, ensure Cloud Functions merge-triggered deployment, and create a Pull Request.
---

# npm-upgrade

このスキルは、Node.js / npm プロジェクト（Cloud Functions for Firebase や GCP Cloud Functions、Next.js 等を含む）において、メジャーバージョンを含む依存パッケージの一括アップグレードを行い、コードの自動修復・ビルド検証・セキュリティ監査（`npm audit`）を行い、変更点のCHANGELOG/リリースノートを抽出してAIが要約した上で、マージ時のCloud Functions自動デプロイ設定を点検・担保し、プルリクエスト（PR）を自動起票するスキルです。

---

## フロー

### 1. `npm-upgrade` ヘルパースクリプトの実行
- 実行コマンド:
  ```bash
  node <path_to_skill>/scripts/bin/npm-upgrade.mjs --path "$PWD/<path_to_project>"
  ```
  - `<path_to_skill>`: 本 `SKILL.md` が配置されているディレクトリへの相対/絶対パス（例: `npm-upgrade` または `.agents/skills/npm-upgrade`）
  - `<path_to_project>`: アップグレード対象の Node.js プロジェクトが存在するディレクトリへの相対パス（ルート直下なら `.`、サブディレクトリなら `functions` など）
- **スクリプトの全自動動作**:
  1. 未コミット変更のチェック（変更がある場合はエラー終了）。
  2. プロジェクトのパッケージマネージャ（`npm` / `pnpm` / `yarn`）をロックファイルから自動判定。
  3. アップグレード前のロックファイル内容から現行バージョンを記録。
  4. トピックブランチ（`chore/deps/upgrade-npm-packages-YYYYMMDD`）を作成・チェックアウト。
  5. `npm-check-updates -u` による最新メジャーバージョンへの更新と、ロックファイルの再生成を実行。
  6. アップグレード前後のロックファイル差分から、更新された全パッケージ（旧バージョン ➔ 新バージョン）を特定。
  7. `package.json` を解析し、各パッケージが**直接依存 (`isDirect: true`)** か**間接依存 (`isDirect: false`)** かを自動判定。
  8. npm レジストリ API からパッケージの GitHub リポジトリ URL やメタデータを並行取得。
  9. `npm audit --json` を実行し、脆弱性情報を収集。
  10. `<path_to_project>/.npm_upgrade/changelog_diffs.json` に差分メタデータを出力。
  11. `chore(deps): パッケージの一括アップグレード` コミットを作成。
  12. `lint --fix` / `format` などの自動修復を実行し、差分があれば `fix(deps): パッケージ変更に伴う自動修正 (lint/format)` コミットを作成。
  13. `npm run build` / `npm test` 等による静的検証を実行。

---

### 2. 静的検証・ビルド結果の確認と追加修正
- スクリプト実行ログのビルド結果（`npm run build`、`tsc`、`npm test` 等）を確認します。
- もしコンパイルエラーや重大な警告、テスト失敗が残っている場合：
  - AIがコードを修正し、`git commit -m "fix(deps): パッケージ変更に伴う手動移行対応"` の別コミットを作成して追加します。
  - 設計上の大幅な変更や判断に迷う破壊的変更については、無理に修正せず PR 本文の「⚠️ 手動対応・要確認が必要な点」に記録します。

---

### 3. CHANGELOG 差分データの読み込み
- `<path_to_project>/.npm_upgrade/changelog_diffs.json` の内容を読み込みます。

---

### 4. 🚀 マージタイミングでのCloud Functionsデプロイ設定の点検・担保
対象プロジェクトが Cloud Functions（Firebase Functions や GCP Cloud Functions）を含む場合、PRマージ時に自動デプロイが確実に行われる状態になっているかを点検します。

1. **ワークフローファイルの探索**:
   - リポジトリの `.github/workflows/` ディレクトリ内を走査し、`main`（または default branch）へのマージ・push で発火するデプロイワークフロー（`firebase deploy --only functions` や `google-github-actions/deploy-cloud-functions` 等）が存在するか確認します。
2. **ワークフローが未設定、または不完全な場合**:
   - プロジェクトに `firebase.json` が存在し `functions` が定義されているにもかかわらずデプロイ用ワークフローが存在しない場合、[references/deploy-functions.md](references/deploy-functions.md) を参照して `.github/workflows/deploy-functions.yaml` の生成を提案・作成します。
   - 認証方式には Workload Identity Federation (OIDC) を採用し、長期サービスアカウントキーの Secrets 保存を回避します（必要に応じて `github-actions-oidc` スキルを活用）。
3. **PR本文への記録**:
   - マージ後にどのワークフローによってどの Functions がデプロイされるか、またはデプロイ設定の追加内容を PR 本文の「🚀 マージ時デプロイ (Cloud Functions等)」セクションに明記します。

---

### 5. AIによる要約・分析およびPR本文の生成

- **【重要：手抜き・省略の絶対禁止】**
  件数が多くても「※ 詳細は package-lock.json の差分をご参照ください」や「以下省略」といった記述で省略することは厳禁です。必ずすべてのパッケージを漏れなくPR本文に記録してください。
- **直接依存と間接依存の分類**:
  JSON データ内の `"isDirect"` フラグ（`true` または `false`）に基づいて正確に分類してください。
  - **直接依存 (`isDirect: true`)**:
    各パッケージのリンク（npm / GitHub Releases）を付与し、メジャーアップデートや破壊的変更、新機能を個別に分析・要約して記載します。
  - **間接依存 (`isDirect: false`)**:
    詳細な要約は省略して構いませんが、「パッケージ名 (旧バージョン ➔ 新バージョン) とリンク」のリスト自体は100%すべて書き出してください。
- **リンクのフォーマット**:
  - npmパッケージURL: `https://www.npmjs.com/package/<package_name>`
  - GitHub Releases（判明している場合）: `<repo_url>/releases`

---

### 6. PR の起票

生成する PR の本文は、以下の**標準テンプレート**に従って組み立ててください。

#### 📄 PR本文の標準テンプレート

```markdown
## 概要

<アップグレード全体の概要や目的の簡潔な説明>

## 🚨 特に注目すべき重要な変更点

<!-- 破壊的変更、メジャーアップデート、利便性が向上する重要な機能追加や主要な仕様変更などをハイライト。特になければ「特になし」と記述 -->

- **[<package_name>](<changelog_or_releases_url>)** (<old_version> ➔ <new_version>): <注目すべき破壊的変更・新機能・主要変更の要約>

## 🛠️ 自動修復・ビルド検証結果

- <lint fix / format による自動修正内容、ビルド・テスト検証結果等>

## 🔒 セキュリティ診断 (npm audit)

- <解決された脆弱性や現在の脆弱性サマリー（critical, high, moderate, low件数など）>

## 🚀 マージ時デプロイ (Cloud Functions等)

<!-- mainマージ時に自動デプロイされるワークフロー情報や反映先。特に対象外なら「対象外」と記述 -->

- **自動デプロイ**: <稼働中ワークフロー名（例: .github/workflows/deploy-functions.yaml） / 新規追加内容>
- **デプロイ対象**: <Cloud Functions (functions/**) / Firebase プロジェクト情報等>
- **特記事項**: <デプロイ時の注意点や環境変数・シークレット要件等>

## ⚠️ 手動対応・要確認が必要な点

<!-- AIで確信を持って修正できず残した懸念点や、ユーザー側での手動確認・動作テストが必要な事項。なければ「なし」と記述 -->

- <要確認項目>

## 📦 アップグレードされたパッケージ詳細

### 直接依存 (Direct dependencies)

- **[<package_name>](https://www.npmjs.com/package/<package_name>)** (<old_version> ➔ <new_version>)
  - <変更点・更新内容1>
  - <変更点・更新内容2>

### 間接依存 (Transitive dependencies)

- [<package_name>](https://www.npmjs.com/package/<package_name>) (<old_version> ➔ <new_version>)
- ...
```

- トピックブランチを remote に push し、`gh` コマンドで PR を起票します。
  - **「⚠️ 手動対応・要確認が必要な点」に項目・注意事項がある場合**: `--draft` オプションを付与して Draft PR として起票します。
    - 実行コマンド:
      ```bash
      env -u GITHUB_TOKEN -u GH_TOKEN gh pr create --draft --title "chore(deps): npm パッケージの一括アップグレード (YYYY/MM/DD)" --body "<生成したテンプレート本文>"
      ```
  - **「⚠️ 手動対応・要確認が必要な点」が「なし」の場合**: `--draft` オプションを外して Ready for review（通常のPR）として起票します。
    - 実行コマンド:
      ```bash
      env -u GITHUB_TOKEN -u GH_TOKEN gh pr create --title "chore(deps): npm パッケージの一括アップグレード (YYYY/MM/DD)" --body "<生成したテンプレート本文>"
      ```

---

### 7. クリーンアップ
- `<path_to_project>/.npm_upgrade` ディレクトリなどの一時生成物を削除します。

---

### 8. 最終出力フォーマット
- 処理の最後（応答の最終行）に、作成されたプルリクエストの URL を以下の固定フォーマットで必ず出力してください。
  `PULL_REQUEST_URL: <作成されたPRのURL>`
- パッケージの更新がなかった場合や PR が起票されなかった場合は、以下のように出力してください。
  `PULL_REQUEST_URL: none`
