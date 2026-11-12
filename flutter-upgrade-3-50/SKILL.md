---
name: flutter-upgrade-3-50
description: Upgrade a Flutter project to Flutter 3.50 (paired with Dart 3.14). Includes official reference URLs (What's new blog, Dart 3.14 blog, release notes, breaking changes). Handles cases whether Flutter SDK is already upgraded to 3.50 or not. Follows latest flutter create 3.50 template defaults (AGP 9.3.1, Gradle 9.5.0, Kotlin 2.4.20, Swift Package Manager enforcement), updates pubspec.yaml environment SDK & Flutter bounds with caret notation (^3.14.0 & ^3.50.0) via dart migrate or melos.bootstrap.environment, applies dart fixes, prompts for opt-in migrations (migrate_design_widgets / MaterialUiCompatibilityBridge vs deferred ignore strategy, AGP 9 Built-in Kotlin, macOS arm64-only, Web Wasm & content hashing), warns about runtime breaking changes (Android Intent hardening, soft hyphens, Web SafeArea, RTL WidgetSpan), and creates a detailed Pull Request.
---

# flutter-upgrade-3-50

このスキルは、Flutterプロジェクトを **Flutter 3.50**（同梱 **Dart 3.14**）へ安全かつスムーズに追従・アップグレードするための専用スキルです。すでにローカル環境 / FVM が 3.50 に更新済みの場合でも、未更新の場合でもスムーズに対応します。

---

## 📚 一次情報・公式リファレンス (Reference Links)

アップグレード作業時に参照すべき公式の重要情報源一覧です：

- 📢 **What's New in Flutter 3.50 (Official Blog)**: [https://flutter.dev/blog/whats-new-in-flutter-3-50](https://flutter.dev/blog/whats-new-in-flutter-3-50)
- 🎯 **Announcing Dart 3.14 (Official Blog)**: [https://dart.dev/blog/announcing-dart-3-14](https://dart.dev/blog/announcing-dart-3-14)
- 📝 **Flutter 3.50.0 Release Notes**: [https://docs.flutter.dev/release/release-notes/release-notes-3.50.0](https://docs.flutter.dev/release/release-notes/release-notes-3.50.0)
- ⚠️ **Flutter Breaking Changes**: [https://docs.flutter.dev/release/breaking-changes](https://docs.flutter.dev/release/breaking-changes)
  - [Migrate to standalone `material_ui` and `cupertino_ui` packages](https://docs.flutter.dev/release/breaking-changes/material-ui-and-cupertino-ui)
  - [Stricter Android `Intent` verification for app entrypoints](https://docs.flutter.dev/release/breaking-changes/stricter-android-entrypoint-intent-verification)
  - [Restrict Android engine flags in release mode](https://docs.flutter.dev/release/breaking-changes/restrict-android-engine-flags-release-mode)
  - [Added `enabled` to `DropdownButtonFormField` and made `onChanged` optional (`material_ui` 1.8.0)](https://docs.flutter.dev/release/breaking-changes/dropdownbuttonformfield-enabled-parameter)
  - [Soft hyphens render at line breaks](https://docs.flutter.dev/release/breaking-changes/soft-hyphen-rendering)
  - [Web `viewport-fit=cover` `SafeArea` support](https://docs.flutter.dev/release/breaking-changes/viewport-fit-cover-safe-area)
  - [WidgetSpan order in right-to-left text](https://docs.flutter.dev/release/breaking-changes/widgetspan-rtl-bidi-order)
- 📰 **Flutter Release Category**: [https://flutter.dev/blog?category=release](https://flutter.dev/blog?category=release)

---

## 🎯 目的と概要

Flutter 3.50 / Dart 3.14（2026年11月リリース）へのプロジェクト追従を以下のステップで自動化・サポートします。

1. **環境確認 & Flutter SDK バージョンの昇格/確認**:
   - すでに 3.50.x の場合: SDK更新処理をスキップ。
   - 未更新の場合: FVM (`.fvmrc` 更新 + `fvm use 3.50.0`) または `flutter upgrade` で 3.50.0 へ昇格。
2. **`pubspec.yaml` / `melos` の `environment` バージョン下限引き上げ (caret指定)**:
   - 通常プロジェクト / Pub Workspace: `dart migrate --apply --target-sdk=3.14.0` および `pubspec.yaml` の `environment:` (`sdk: "^3.14.0"`, `flutter: "^3.50.0"`) を更新。
   - Melos モノレポ: ルート `pubspec.yaml`（または `melos.yaml`）の `melos.command.bootstrap.environment`（または `melos.bootstrap.environment`）を更新し、`melos bs` で配下全パッケージへ一括自動適用。
   - **重要**: `flutter pub get` / `melos bs` を先に実行して `.dart_tool/package_config.json` を再生成すること（未更新のままだと SDK 側が Dart 3.13 の private named parameters `this._builders` 等を使用している箇所で `undefined_named_parameter` 誤検知が起きるため）。
3. **`flutter create .` の 3.50 最新テンプレート・設定追従**:
   - `analysis_options.yaml`: Dart 3.13+ で安定化された `enable-experiment: [primary-constructors]` 等の不要指定の整理、および Dart 3.14 アナライザ改善に伴う `unnecessary_ignore` の解消。
   - Android: AGP `9.3.1` / Gradle `9.5.0` / Kotlin `2.4.20`（Java 17、デフォルト `compileSdk`/`targetSdk` API 36、`minSdk` API 24）。Firebase プラグイン利用時は `firebase-perf` `2.0.2+` / `crashlytics` `3.0.x` / `google-services` `4.4.x` への更新および `android.enableJetifier` 廃止に注意。
   - iOS / macOS: Xcode 27 / iOS 27 対応、Swift Package Manager 無効化時の CLI 警告化（2026年12月の CocoaPods trunk read-only 化に向けた移行確認）。
   - Web: `web/index.html` の `viewport-fit=cover` コメント仕様および Wasm / キャッシュバスティング対応。
4. **自動修復 (`dart migrate` / `dart fix --apply`)**: 機械的なコード修正の適用。
5. **オプトイン移行・設計判断の対話的提案**:
   - `package:flutter/material.dart` / `cupertino.dart` の正式 `@Deprecated` 化に伴う移行 (`migrate_design_widgets` + `MaterialUiCompatibilityBridge`) vs サードパーティ未対応時の限定抑制戦略。
   - Android AGP 9.3.1 / Gradle 9.5.0 / Built-in Kotlin への追従範囲。
   - Web (`--web-content-hash`, `--no-deprecated-js-interop`, Safari/Firefox Wasm) や macOS (`--enable-macos-arm64-only`) の活用。
6. **動作変化・ランタイム注意点のチェック報告**: Android リリースビルドの `Intent` 検証厳格化、ソフトハイフン描画、Web `SafeArea` 等の確認。
7. **Draft PR起票・コミットフォーマット遵守**: `git-commit-formatter` および `gh` CLIを用いた安全な起票。

---

## 🚀 実行手順ワークフロー

### Step 1: 環境確認・Flutter SDK 昇格 / FVM 切り替え & Draft PR作成

1. **現在の Flutter SDK バージョンおよび FVM 設定の確認**:
   - プロジェクトルートの `.fvmrc` や `.fvm/fvm_config.json` の有無を確認。
   - `flutter --version` (FVM使用時は `fvm flutter --version`) を実行。

2. **バージョン昇格 / スキップの分岐処理**:
   - **ケース A: すでに Flutter 3.50.x に更新済みの場合**:
     - 「Flutter SDK はすでに 3.50.x に達しています」と報告し、SDK更新処理はスキップ（`.fvmrc` が `"stable"` 指定の場合も `fvm install stable` / シンボリックリンク先が 3.50.0 であることを確認）。
   - **ケース B: まだ旧バージョン（例: 3.47 等）の場合**:
     - **FVM利用時**: `.fvmrc` が固定バージョン指定なら `"3.50.0"` に書き換え `fvm use 3.50.0` を実行（`"stable"` 指定なら `fvm flutter upgrade`）。
     - **グローバル Flutter 利用時**: ユーザー案内のうえ `flutter upgrade` を実行。

3. **Gitブランチの作成 & Draft PR の起票**:
   - 対応 Issue がある場合は `feature/mono/<Issue番号>-flutter-3-50-upgrade`（ない場合は Issue 起票または `feature/mono/3-50-flutter-upgrade`）を作成して切替。
   - 空コミット `git commit --allow-empty -m "chore: start Flutter 3.50 upgrade"` を作成して push。
   - `env -u GITHUB_TOKEN -u GH_TOKEN gh pr create --draft ...` で Draft PR を起票。

---

### Step 2: `environment` バージョン更新 & `flutter create .` 最新テンプレート追従

1. **Dart 3.14 新ツール `dart migrate` の事前確認**:
   - ワークスペースルート（またはパッケージルート）で `dart migrate --dry-run --target-sdk=3.14.0` を実行し、必要な事前修正（preparatory fixes）やクリーンアップ候補を確認する（Pub Workspace の場合は個別サブパッケージではなくワークスペースルートで実行する）。

2. **通常プロジェクトの場合**:
   - `pubspec.yaml` の `environment` 指定を caret (`^`) 形式で更新：
     ```yaml
     environment:
       sdk: "^3.14.0"
       flutter: "^3.50.0"
     ```

3. **モノレポ (`Melos` / Pub Workspace) プロジェクトの場合**:
   - ルート `pubspec.yaml` の `environment` および `melos.command.bootstrap.environment`（Melos 7/8 系）または `melos.bootstrap.environment`、ならびに各サブパッケージの `pubspec.yaml` を更新：
     ```yaml
     environment:
       sdk: "^3.14.0"
       flutter: "^3.50.0"
     # ...
     melos:
       command:
         bootstrap:
           environment:
             sdk: "^3.14.0"
             flutter: "^3.50.0"
     ```
   - `melos bs`（または `flutter pub get`）を実行し、`pubspec.lock` と `.dart_tool/package_config.json` を 3.50 / 3.14 向けに更新する。

4. **`flutter create` 3.50 テンプレートとの差分比較**:
   - 必要に応じて安全な一時領域（`~/.agents/tmp/temp_app` 等、完了後即時削除）で `flutter create --org com.example temp_app` を実行し、設定を比較：
   - **`analysis_options.yaml`**:
     - `enable-experiment: [primary-constructors]` が残っている場合は、Dart 3.13+ で安定化済みのため削除可能。
   - **Android (`android/`)**:
     - 3.50 新規テンプレート標準:
       - `gradle-wrapper.properties`: `gradle-9.5.0-all.zip`
       - `settings.gradle(.kts)`: `com.android.application` `9.3.1`, `org.jetbrains.kotlin.android` `2.4.20`
       - `app/build.gradle(.kts)`: Java 17 / `JvmTarget.JVM_17`、`id("kotlin-android")` 不要（テンプレートの `gradle.properties` では互換性のため `android.builtInKotlin=false`, `android.newDsl=false` が既定付与されるが、全プラグインが Built-in Kotlin 対応済みなら削除または `true` で AGP 9 新 DSL にオプトイン可能）。
       - **Firebase 利用時の注意**: AGP 9 / Gradle 9 へ上げる場合、`android.enableJetifier=true` は廃止エラーとなるため削除し、`com.google.firebase.firebase-perf` は `2.0.2` 以上、`com.google.firebase.crashlytics` は `3.0.x` 以上、`com.google.gms.google-services` は `4.4.x` 以上へ更新する必要がある。
   - **iOS / macOS (`ios/`, `macos/`)**:
     - Swift Package Manager (`enable-swift-package-manager: true`) が有効であることを確認（Flutter 3.50 から SPM 無効化時は全 CLI コマンドで警告が出る）。
   - **Web (`web/`)**:
     - `<meta name="viewport" content="width=device-width, initial-scale=1.0, viewport-fit=cover">` を有効にしている場合、モバイルブラウザでノッチ・ホームインジケータ領域まで描画され `SafeArea` にパディングが渡る新挙動を確認。

---

### Step 3: 自動修復 & 依存関係の更新

1. `flutter pub get`（Melos の場合は `melos bs`）を実行。
2. `dart fix --apply`（Melos の場合は `melos run fix`）を実行して機械的修正（`unnecessary_ignore` の除去等を含む）を適用。

---

### Step 4: オプトイン / 移行方針の対話選択

ユーザーへ `ask_question` 等を用いて、プロジェクトの状況に応じた以下の移行方針をヒアリングします。

#### 📌 1. `material_ui` / `cupertino_ui` 移行 (`dart fix --apply --code=migrate_design_widgets`)
- **概要**:
  - Flutter 3.50 で SDK 同梱の `package:flutter/material.dart`、`package:flutter/cupertino.dart`、および `flutter_localizations` の Material/Cupertino デリゲートに正式に `@Deprecated` が付与され、新規プロジェクトのデフォルトが `package:material_ui` になりました。
  - 3.50 では未移行のサードパーティ Widget 向けに `MaterialUiCompatibilityBridge` / `CupertinoUiCompatibilityBridge`（`InheritedWidget` のテーマ・ローカライズ橋渡し）も提供されています。
- **メリット**:
  - 週次リリースされる独立デザインパッケージの最新修正・改善（`DropdownButtonFormField.enabled` 等）を SDK 更新と独立して享受でき、将来の SDK からの完全削除（3.53+ 予定）に先回りできる。
- **デメリット・制約（重要）**:
  - `MaterialUiCompatibilityBridge` はツリー上の `Theme` / `MaterialLocalizations` 等の参照は橋渡しできるが、**サードパーティパッケージが公開 API シグネチャの引数・戻り値で `flutter/material.dart` の型（`ThemeData`, `TabController`, `ColorScheme` 等）を受け渡ししている場合の静的な型不一致は解決できない**（例: `flutter_hooks`, `alchemist`, `marionette_flutter` 等が未移行の場合）。
- **推奨判断**:
  - **依存パッケージが対応済み / 小規模構成の場合**: **【推奨】** `dart fix --apply --code=migrate_design_widgets` を適用。
  - **未対応の主要パッケージに依存しており移行を別 Issue で待機する場合**:
    - `--fatal-infos` 環境では `import 'package:flutter/material.dart';` 等が `deprecated_member_use` となるため、**① 該当 import 行のみに `// ignore: deprecated_member_use` を付与する（他の非推奨検知を殺さず、将来の移行時に `unnecessary_ignore` で自動一掃できる正攻法）**、または **② `analysis_options.yaml` で一時的に抑制する** 方針をユーザーに確認して適用する。

#### 📌 2. Android Gradle Plugin 9.3.1 / Gradle 9.5.0 / Built-in Kotlin 追従
- **概要**: 既存プロジェクトの AGP / Gradle / Kotlin バージョンを 3.50 テンプレート水準（AGP `9.3.1` / Gradle `9.5.0` / Kotlin `2.4.20`）へ引き上げるか、影響切り分けのため別 PR とするかを選択。
- **推奨度**: **【確認推奨 (Caution / Recommended with build check)】**（引き上げる場合は必ず `./gradlew assembleDebug` または `flutter build apk --debug` 等でプラグイン互換性を検証する）。

#### 📌 3. Web / Desktop 向け新規ビルドオプション（該当プロジェクトのみ提案）
- **Web コンテンツハッシュ**: `flutter build web --web-content-hash`（長期キャッシュバスティングと `precache_manifest.json` 生成）— **【推奨（Web本番配信時）】**
- **レガシー JS Interop 検査**: `flutter build web --no-deprecated-js-interop`（`dart:html`, `dart:js` 等の混入をビルド時に検出して Wasm 対応を担保）— **【任意・CI検査推奨】**
- **Safari 26.2+ / Firefox 147+ Wasm 有効化**: `web/flutter_bootstrap.js` の `wasmAllowList: { blink: true, webkit: true, gecko: true }` — **【任意】**
- **Apple Silicon 専用 macOS ビルド**: `flutter config --enable-macos-arm64-only` — **【任意】**

---

### Step 5: 動作変化の懸念点・不安要素（ランタイム破壊的変更）のチェックと提示

コンパイルエラーにならなくてもランタイム挙動・セキュリティ・UIが変わる以下の項目をチェックし、該当箇所があれば修正または PR 本文・完了報告でユーザーへ明示します。

| 対象領域 | 変更点 (Flutter 3.50) | 影響・確認すべきポイント |
| :--- | :--- | :--- |
| **Android `Intent` 検証厳格化** | リリースビルドで外部 `Intent` extra の `route`, `dart_entrypoint`, `cached_engine_id` を無視 | 標準の Deep Link (`ACTION_VIEW` + URI) は影響なし。外部アプリ連携やカスタム Intent extra で初期ルート・エントリポイントを渡している箇所がないか確認 |
| **Android リリース時エンジンフラグ制限** | リリースビルドで `Intent` extra や `--use-application-binary` 経由の `--dart-flags` 等を拒否 | リリースバイナリに対するカスタムエンジンフラグ指定テストは profile モードへ移行 |
| **ソフトハイフン (`\u00AD`) 描画** | ソフトハイフンを含む文字列が行折り返し位置に来た際、自動的にハイフン記号が表示される（新 `Hyphens` enum で制御可能） | 多言語テキストや改行位置制御に `\u00AD` を使っている箇所の表示確認 |
| **Web `viewport-fit=cover` と `SafeArea`** | `web/index.html` に `viewport-fit=cover` がある場合、Web エンジンが上書きせずノッチ下まで描画し `SafeArea` にパディングを伝播 | モバイルブラウザ向け Web 版で画面端のレイアウト・SafeArea が意図通りか確認 |
| **RTL テキスト内の `WidgetSpan` 順序** | アラビア語・ヘブライ語等の双方向テキスト内の `WidgetSpan` が Unicode 双方向アルゴリズムの視覚順に配置される | 以前の逆順バグを回避するワークアラウンドを入れていた場合は削除 |
| **`IgnorePointer` 等の `ignoringSemantics` 削除** | 非推奨だった `IgnorePointer` / `AbsorbPointer` / `SliverIgnorePointer` の `ignoringSemantics` プロパティが完全削除 | 使用箇所があれば `ExcludeSemantics` 等へ置換（コンパイル時に検出可能） |
| **`DropdownButtonFormField.enabled`** | `material_ui` 1.8.0+ で明示的な `enabled` プロパティ追加・`onChanged` が optional 化 | `material_ui` 利用時は無効化表現に `enabled: false` を活用可能 |

---

### Step 6: 静的解析 & テスト検証

1. `dart analyze`（Melos の場合は `melos run analyze`）を実行し、エラー・警告・info（`--fatal-infos` 時）が **0 件** であることを確認。
2. `flutter test`（Melos の場合は `melos run test`）を実行し、全テストがパスすることを確認。
3. Android Gradle 設定を変更した場合は `flutter build apk --debug`（Flavor がある場合は該当 Flavor 指定）等でビルドが通ることを検証。

---

### Step 7: コミット & PR 本文の更新

1. **コミット作成**:
   - `git-commit-formatter` に従い Conventional Commits 仕様（プロジェクト規約が日本語なら日本語）でコミット。
2. **PR 本文の更新**:
   - 以下のテンプレートに基づき、`env -u GITHUB_TOKEN -u GH_TOKEN gh pr edit` で PR 本文を更新し、CI / レビュー監視運用があるプロジェクトでは所定の手順を実行する。

```markdown
## 🚀 Flutter 3.50 / Dart 3.14 アップグレード対応

### 📚 参考リンク (Reference Links)
- [What's New in Flutter 3.50](https://flutter.dev/blog/whats-new-in-flutter-3-50)
- [Announcing Dart 3.14](https://dart.dev/blog/announcing-dart-3-14)
- [Flutter 3.50.0 Release Notes](https://docs.flutter.dev/release/release-notes/release-notes-3.50.0)
- [Flutter Breaking Changes](https://docs.flutter.dev/release/breaking-changes)

### 📋 対応内容
- [x] Flutter SDK 3.50.0 / Dart 3.14.0 への追従
- [x] `environment` (`sdk: "^3.14.0"`, `flutter: "^3.50.0"`) の更新
- [x] `flutter create` 3.50 テンプレート差分・解析設定の確認と反映
- [x] `dart fix --apply` による機械的修正および不要 ignore の整理
- [x] デザインパッケージ (`material_ui` / `cupertino_ui`) 対応: [移行適用済 / 依存パッケージ対応待ちのため限定 ignore 対応]
- [x] 静的解析 (`analyze`) & 全自動テスト (`test`) パス確認

### ⚠️ ランタイム動作確認・注意事項 (Flutter 3.50)
- **Android `Intent` 検証厳格化 & エンジンフラグ制限**: リリースビルドで外部 `Intent` extra の `route` / `dart_entrypoint` / `cached_engine_id` およびデバッグ用エンジンフラグが無視される仕様変更（通常の URI Deep Link は影響なし）
- **iOS タッチレスポンス改善**: フレームスケジューリング刷新によりタッチ入力遅延が 1 フレーム短縮（60Hz で 16ms、120Hz ProMotion で 8ms 高速化）
- **ソフトハイフン / RTL `WidgetSpan` / Web `SafeArea`**: テキスト折り返し時のソフトハイフン可視化、モバイル Web `viewport-fit=cover` 時の SafeArea パディング反映
```
