---
name: flutter-upgrade-creator
description: Generate a dedicated Flutter upgrade skill (e.g. flutter-upgrade-3-47) for a specific Flutter stable release by fetching and analyzing release notes, breaking changes, and migration guides. Use when the user asks to create an upgrade skill for a new Flutter stable release, or asks to generate 'flutter-upgrade-X-YY'.
---

# flutter-upgrade-creator

このスキルは、Flutterの新しい stable バージョン（例: `3.47` など）がリリースされた際に、その特定バージョンにプロジェクトを追従・アップグレードするための専用Skill（例: `flutter-upgrade-3-47`）を自動生成（調査・構築）するメタスキルです。

---

## 🎯 目的と役割

ユーザーから「Flutter 3.47 へのアップグレードSkillを作って」のように特定バージョンを指定された場合、公式ドキュメントやリリース情報を網羅的に調査し、`/Users/mono/Git/skills/flutter-upgrade-<major>-<minor>` ディレクトリに高品質な追従Skillを出力します。

---

## 🧭 生成・調査のフロー

指定されたバージョン（例: `VERSION = 3.47` または `3.47.0`）を受け取ったら、以下の順序で情報を調査・抽出し、専用Skillを作成します。

### Step 1: 公式リリース情報・ドキュメントの網羅的リサーチ

以下のURLおよび関連ページを `read_url_content` や `search_web` で読み込み・解析します。

1. **Flutter Release Blog**:
   - `https://flutter.dev/blog?category=release`
   - 指定バージョン（例: Flutter 3.47）の公式発表記事を探して全文確認。
2. **Dart Release Blog**:
   - `https://dart.dev/blog`
   - Flutterの該当バージョンに同梱されている Dart（例: Dart 3.7 / 3.8 など）の更新情報・ブログ記事を確認。
3. **Breaking Changes**:
   - `https://docs.flutter.dev/release/breaking-changes`
   - 指定バージョンで追加された破壊的変更（非互換なAPI変更、減衰/非推奨 API、削除された機能など）を抽出。
4. **Specific Release Notes**:
   - `https://docs.flutter.dev/release/release-notes/release-notes-<VERSION>` (例: `release-notes-3.47.0` や `release-notes-3.47.0.md` など)
   - 詳細なチェンジログ、機能変更、マイグレーションコードを収集。

---

### Step 2: 収集情報の分析・分類

リサーチした情報を以下の4つのカテゴリに整理します。

1. **`flutter create .` テンプレート差分・標準構成**:
   - 当該バージョンで推奨される設定ファイル記述 (`pubspec.yaml` の sdk 範囲、`analysis_options.yaml`, Android Gradle Plugin / Kotlin / Gradle バージョン, iOS Xcode / Podfile 設定, Web構成など)。
2. **自動修正コマンド & オプトイン/ベータ機能 (Migration code)**:
   - 例: `dart fix --apply --code=migrate_design_widgets`
   - 各オプトイン/ベータ機能について以下を整理：
     - **概要・何が変わるか**
     - **メリット**
     - **デメリット・リスク**
     - **推奨度**（「推奨 (Recommended)」「任意 (Optional)」「慎重・確認推奨 (Caution)」）
3. **動作変化の懸念点・不安要素（ランタイム影響の警告）**:
   - **コンパイルエラーにならないが挙動が変わる変更点**（UIのデフォルトスタイル変更、イベント伝播の変更、レンダリング/アニメーション仕様変更、廃止予定フラグの変更など）。
   - コンパイルエラーになる明確な Breaking Changes と手動修復パターン。
4. **PR作成ノウハウ**:
   - 変更理由、テンプレート追従、適用したオプトイン機能、確認が必要な懸念事項を網羅するPRテンプレート。

---

### Step 3: 特定バージョン用Skill (`flutter-upgrade-X-YY/SKILL.md`) の作成

`/Users/mono/Git/skills/flutter-upgrade-<major>-<minor>` ディレクトリを作成し、以下の構造で `SKILL.md` を書き出します。

#### 生成される `flutter-upgrade-X-YY/SKILL.md` の標準構造

```markdown
---
name: flutter-upgrade-<major>-<minor>
description: Upgrade a Flutter project to Flutter <VERSION> (e.g. 3.47). Handles cases whether Flutter SDK is already upgraded to <VERSION> or not. Follows latest flutter create template defaults, applies dart fixes, prompts for opt-in migration tools, warns about runtime breaking changes, and creates a detailed Pull Request.
---

# flutter-upgrade-<major>-<minor>

このスキルは、Flutterプロジェクトを **Flutter <VERSION>** へ安全かつスムーズに追従・アップグレードするための専用スキルです。すでにローカル環境/FVMが <VERSION> に更新済みの場合でも、未更新の場合でもスムーズに対応します。

## 🚀 実行フロー

### 1. 環境確認・Flutter SDK 昇格 / FVM 切り替え & Draft PR作成
- **現在の SDK バージョンおよび FVM 設定を確認**:
  - `flutter --version` および `.fvmrc` の有無を確認。
- **バージョン昇格 / スキップ分岐**:
  - **ケース A: すでに <VERSION> に更新済みの場合**:
    - 「Flutter SDK はすでに <VERSION> に達しています」と出力し、昇格処理をスキップ。
  - **ケース B: まだ旧バージョンの場合**:
    - **FVM利用時**: `.fvmrc` を `<VERSION>.0` に更新し `fvm use <VERSION>.0` を実行。
    - **グローバル Flutter 利用時**: ユーザー案内後に `flutter upgrade` を実行（または FVM 提案）。
- **Gitブランチの作成**: (`feature/mono/<VERSION_KEBAB>-upgrade`)
- **Draft PR起票**: `env -u GITHUB_TOKEN -u GH_TOKEN gh pr create --draft ...` または空コミット起票による Draft PR 作成。

### 2. `flutter create` 最新テンプレートへの追従
- 一時ディレクトリにて `flutter create --org com.example temp_app` を実行。
- 既存プロジェクトとの設定ファイルの差分を抽出し、以下を最新標準へ更新：
  - `pubspec.yaml` の `sdk: "^<DART_VERSION>"` / `flutter: ">=<VERSION>"`
  - `analysis_options.yaml`
  - `android/` (Gradle, Android Gradle Plugin, Kotlin バージョン, build.gradle / settings.gradle 構成)
  - `ios/` (Podfile, Xcode プロジェクト設定)
  - モノレポ (`Melos`) プロジェクトの場合は `melos exec` / `melos run` を活用。

### 3. 自動修復とパッケージ依存関係
- `flutter pub get` の実行
- `dart fix --apply` による機械的修正の適用

### 4. オプトイン / ベータ機能 / Migration Fix の対話選択
ユーザーへ `ask_question` または明確な対話により、以下の移行コード/機能の適用可否をヒアリングする。

[バージョン固有のオプトイン機能一覧]
- **機能/コード**: 例: `dart fix --apply --code=...`
  - **メリット**: ...
  - **デメリット**: ...
  - **推奨度**: (推奨 / 任意 / 慎重)

### 5. 動作変化の懸念点・不安要素（注意が必要な変更点）のチェック＆報告
コンパイルエラーにならなくても動作が変わる可能性がある事項をリストアップし、必要に応じて手動修正またはユーザーへの警告・確認を実施する。

[バージョン固有の動作変化注意点一覧]

### 6. 静的解析 & テスト検証
- `dart analyze` (または `melos run analyze`) を実行し、警告・エラーが0件であることを確認。
- `flutter test` を実行し、既存テストがパスすることを確認。

### 7. コミット & PR本文の更新
- `git-commit-formatter` を活用して Conventional Commits に従ったコミットを作成。
- テンプレート追従内容、適用したオプトイン機能、手動確認が必要な動作変更懸念事項を明記した詳細な PR 本文を作成し、PRを更新。
```

---

## 🛠 スキル生成の完了条件

1. `/Users/mono/Git/skills/flutter-upgrade-<major>-<minor>/SKILL.md` が正常に生成されていること。
2. 対象バージョンのリリースノート・Breaking Changes・`flutter create` テンプレート更新点・オプトイン機能のメリット/デメリット・動作変化注意点が網羅されていること。
