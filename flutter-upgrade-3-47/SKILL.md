---
name: flutter-upgrade-3-47
description: Upgrade a Flutter project to Flutter 3.47. Includes official reference URLs (What's new blog, release notes, breaking changes). Handles cases whether Flutter SDK is already upgraded to 3.47 or not. Follows latest flutter create 3.47 template defaults (AGP 9, Built-in Kotlin), applies dart fixes, offers optional design widget migration (migrate_design_widgets), warns about runtime breaking changes (OpenGL ES texture direction, Impeller Desktop text rendering, Semantics), and creates a detailed Pull Request.
---

# flutter-upgrade-3-47

このスキルは、Flutterプロジェクトを **Flutter 3.47** へ安全かつスムーズに追従・アップグレードするための専用スキルです。すでにローカル環境/FVMが 3.47 に更新済みの場合でも、未更新の場合でもスムーズに対応します。

---

## 📚 一次情報・公式リファレンス (Reference Links)

アップグレード作業時に参照すべき公式の重要情報源一覧です：

- 📢 **What's New in Flutter 3.47 (Official Blog)**: [https://flutter.dev/blog/whats-new-in-flutter-3-47](https://flutter.dev/blog/whats-new-in-flutter-3-47) (または [https://blog.flutter.dev/whats-new-in-flutter-3-47](https://blog.flutter.dev/whats-new-in-flutter-3-47))
- 📝 **Flutter 3.47.0 Release Notes**: [https://docs.flutter.dev/release/release-notes/release-notes-3.47.0](https://docs.flutter.dev/release/release-notes/release-notes-3.47.0)
- ⚠️ **Flutter Breaking Changes**: [https://docs.flutter.dev/release/breaking-changes](https://docs.flutter.dev/release/breaking-changes)
- 📰 **Flutter Release Announcements Category**: [https://flutter.dev/blog?category=release](https://flutter.dev/blog?category=release)
- 🎯 **Dart Blog**: [https://dart.dev/blog](https://dart.dev/blog)

---

## 🎯 目的と概要

Flutter 3.47（2026年8月リリース）へのプロジェクト追従を以下のステップで自動化・サポートします。

1. **環境確認 & Flutter SDK バージョンの昇格/確認**:
   - すでに 3.47.x の場合: SDK更新処理をスキップ。
   - 未更新の場合: FVM (`.fvmrc` 更新 + `fvm use 3.47.0`) または `flutter upgrade` で 3.47.0 へ昇格。
2. **`flutter create .` の 3.47 最新テンプレート追従**: AGP 9 / Built-in Kotlin, Android/iOS/Web 構成の更新。
3. **自動修復 (`dart fix --apply`)**: 機械的なコード修正の適用。
4. **オプトイン移行 (`migrate_design_widgets`) の対話的提案**: SDKから分離された `material_ui` / `cupertino_ui` パッケージ移行の選択。
5. **動作変化・ランタイム注意点のチェック報告**: コンパイルエラーにならなくても動作・描画・アクセシビリティが変わる懸念事項の提示。
6. **Draft PR起票・コミットフォーマット遵守**: `git-commit-formatter` および `gh` CLIを用いた安全な起票。

---

## 🚀 実行手順ワークフロー

### Step 1: 環境確認・Flutter SDK 昇格 / FVM 切り替え & Draft PR作成

1. **現在の Flutter SDK バージョンおよび FVM 設定の確認**:
   - プロジェクトルートの `.fvmrc` や `.fvm/fvm_config.json` の有無を確認。
   - `flutter --version` (FVM使用時は `fvm flutter --version`) を実行。

2. **バージョン昇格 / スキップの分岐処理**:
   - **ケース A: すでに Flutter 3.47.x に更新済みの場合**:
     - 「Flutter SDK はすでに 3.47.x に達しています」とログ・報告を出力し、SDK更新処理はスキップ。
   - **ケース B: まだ旧バージョン（例: 3.44 や 3.41 等）の場合**:
     - **FVM利用時**: `.fvmrc` のバージョン指定を `"3.47.0"` に書き換え、`fvm use 3.47.0` (または `fvm install 3.47.0`) を実行。
     - **グローバル Flutter 利用時**: ユーザーに状況を案内した上で `flutter upgrade` を実行して 3.47.0 へアップデート（または FVM 導入を提案）。

3. **Gitブランチの作成**:
   - `feature/mono/3-47-flutter-upgrade` ブランチを作成して切替。

4. **Draft PR の起票**:
   - 空コミット `git commit --allow-empty -m "chore: start Flutter 3.47 upgrade"` を作成し、push。
   - `env -u GITHUB_TOKEN -u GH_TOKEN gh pr create --draft --title "chore: upgrade Flutter to 3.47" --body "Draft PR for Flutter 3.47 upgrade"` で PR を起票。

---

### Step 2: `flutter create .` 最新テンプレート (3.47) へのキャッチアップ

1. **テンプレート生成と差分比較**:
   - 一時ディレクトリにて `flutter create --org com.example temp_app` を実行（FVM使用時は `fvm flutter create ...`）。
   - 既存プロジェクトの設定ファイルとテンプレートを比較し、以下の差分を反映：
2. **Android 構成**:
   - **AGP 9+ & Built-in Kotlin への移行**: `android/build.gradle` や `android/settings.gradle` の Gradle プラグイン定義、Kotlin 設定を Built-in Kotlin 仕様にアップグレード。
3. **iOS / macOS 構成**:
   - Xcode 26 / iOS 26 シミュレータ互換の設定、`Podfile` のプラットフォームバージョン指定の確認。
4. **Web 構成**:
   - HTML レンダラー参照の削除（CanvasKit / WebAssembly への完全移行）、フォントフォールバックサービスの更新。
5. **設定ファイル**:
   - `pubspec.yaml` の SDK 範囲 (`sdk: "^3.13.0"` または `sdk: ">=3.7.0 <4.0.0"`) の更新。
   - モノレポ (`Melos`) の場合は `melos exec -- flutter pub get` や `melos run analyze` を使用。

---

### Step 3: 自動修復 & 依存関係の更新

1. `flutter pub get` を実行。
2. `dart fix --apply` を実行して、機械的なコード修正を全適用。

---

### Step 4: オプトイン/ベータ機能移行 (`migrate_design_widgets`) の対話選択

ユーザーへ `ask_question` または対話にて、以下のオプトイン移行機能の適用可否をヒアリングします。

#### 📌 オプトインコード: `dart fix --apply --code=migrate_design_widgets`
- **概要**:
  - Flutter 3.47 より、`Material` / `Cupertino` デザインシステムが Flutter SDK コアから独立パッケージ (`material_ui`, `cupertino_ui`) へ切り離し開始。
  - コマンドを実行すると、`pubspec.yaml` に `material_ui` (および `cupertino_ui`) を自動追加し、`package:flutter/material.dart` 等の import を `package:material_ui/material_ui.dart` へ自動書き換えします。
- **メリット**:
  - 今後（2026年秋の次期リリースでコアSDK内デザインライブラリが非推奨化予定）のSDKアップデートへの先回り追従ができる。
  - デザインシステム単体での更新や最適化の恩恵を受けられる。
- **デメリット・リスク**:
  - 外部パッケージ依存が追加される。
  - まれに `pubspec.yaml` の自動書き換えに失敗する場合があり、その場合は手動で `flutter pub add material_ui` を行う必要がある。
- **推奨度**: **【推奨 (Recommended)】** （今期のPRで移行を完了しておくことが望ましい）

> **対話メッセージ例**:
> 「Flutter 3.47 では Material/Cupertino が独立パッケージ (`material_ui`/`cupertino_ui`) に分離されました。今期 PR で `dart fix --apply --code=migrate_design_widgets` を適用して切り替えを行いますか？」

---

### Step 5: 動作変化の懸念点・不安要素のチェックと提示

コンパイルエラーにならなくても、ランタイム挙動・描画・UIが変わる可能性があるため、以下の項目を重点的にチェックし、報告・手動調整を実施します。

#### ⚠️ 動作変化・注意が必要な箇所一覧 (Flutter 3.47)

| 対象領域 | 変更点 | 影響・確認すべきポイント |
| :--- | :--- | :--- |
| **OpenGL ES Textures** | OpenGL ES render-to-texture のテクスチャ格納が top-down 化 | プラットフォームビューやカスタムシェーダーで上下反転が起きないか確認 |
| **Impeller Desktop** | macOS / Windows / Linux で Impeller がデフォルト化 | SDF描画によるテキスト描画・ガンマ補正・文字シャドウの見え方の変化を確認 |
| **Semantics (a11y)** | Header / headingLevel の挙動変更 | iOS / Android のスクリーンリーダー（VoiceOver/TalkBack）での見出し読み上げ順を確認 |
| **IndexedStack** | 非表示子要素の `ExcludeFocus` 制御 | `IndexedStack` 内の非表示タブでキーボードフォーカスが当たらなくなった挙動の影響確認 |
| **SelectionArea** | Android でのコンテキストメニュー重なり修正 | 選択エリアでのポップアップメニュー位置の表示確認 |

---

### Step 6: 静的解析 & テスト検証

1. `dart analyze` (モノレポの場合は `melos run analyze`) を実行。
   - エラー・警告が 0 件であることを確認。手動修正が必要な場合はコードを修正。
2. `flutter test` を実行。
   - 既存のユニットテスト・ウィジェットテストが全てパスすることを確認。

---

### Step 7: コミット & PR 本文の更新

1. **コミット作成**:
   - `git-commit-formatter` に従い Conventional Commits 仕様でコミット。
   - 例: `feat(deps): upgrade flutter to 3.47 and apply migrate_design_widgets`
2. **PR 本文の更新**:
   - 以下のテンプレートに基づき、`env -u GITHUB_TOKEN -u GH_TOKEN gh pr edit` で PR 本文を更新。

```markdown
## 🚀 Flutter 3.47 アップグレード対応

### 📚 参考リンク (Reference Links)
- [What's New in Flutter 3.47](https://flutter.dev/blog/whats-new-in-flutter-3-47)
- [Flutter 3.47.0 Release Notes](https://docs.flutter.dev/release/release-notes/release-notes-3.47.0)
- [Flutter Breaking Changes](https://docs.flutter.dev/release/breaking-changes)

### 📋 対応内容
- [x] Flutter SDK 3.47 への追従 (事前に3.47昇格済 / またはFVM・flutter upgradeで昇格)
- [x] `flutter create .` 3.47 テンプレート追従 (AGP 9+, Built-in Kotlin, Android/iOS/Web設定)
- [x] `dart fix --apply` による自動修復
- [x] オプトイン機能 (`migrate_design_widgets`): [適用済 / 未適用]

### ⚠️ ランタイム動作確認・注意事項
- **OpenGL ES render-to-texture**: テクスチャ表示方向の確認
- **Impeller Desktop**: macOS/Windows/Linux でのフォント描画のビジュアル確認
- **Semantics / アクセシビリティ**: 見出し・スクリーンリーダー挙動の確認
- **IndexedStack**: 非表示タブのフォーカス外れ挙動の確認
```
