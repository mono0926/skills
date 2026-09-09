---
name: flutter-golden-test
description: Flutterにおける決定論的なGolden UI Test（スクリーンショット回帰テスト）の導入・設定・実装ガイド。alchemistを用いたローカル（macOS）とCI（Linux）間のフォント・OSレンダリング差異の完全克服、テストハーネス設計、TaskfileおよびGitHub Actions連携を網羅。
---

# Flutter Golden UI Test ガイド (alchemist & CI決定論的テスト)

Flutterアプリにおいて、意図しないUI崩れ（RenderFlex overflow、パディング・マージンズレ、コンポーネント配置崩れ、ダークモード崩れ等）を検知・防止するためのGolden UI Test（スクリーンショット回帰テスト）基盤の導入・実装・運用ガイドラインです。

---

## 1. なぜ OS 間のレンダリング差異が起きるのか？

Flutter標準の `matchesGoldenFile` や通常のGolden testはピクセル単位でビットマップを比較します。
しかし、ローカル開発環境（macOS）とCIランナー（GitHub Actions の `ubuntu-latest` / Linux）の間では以下の理由から**同じコード・同じフォントであってもピクセルが一致しません**：

1. **フォントラスタライザの差**: macOSは `CoreText`、Linuxは `FreeType` を使用するため、アンチエイリアス処理、サブピクセルレンダリング、わずかな文字幅・字詰めが異なります。
2. **影 (BoxShadow) やグラデーションのブレンド計算**: OSごとのグラフィックスライブラリやアンチエイリアス処理により、境界線で微細な色差が生じます。

### 解決策: `alchemist` の CI Goldens モード（Ahemフォント置換）
Betterment製の **[`alchemist`](https://pub.dev/packages/alchemist)** パッケージの **CI Goldens モード** を標準採用します。
CI Goldensモードでは、テキストが決定論的な `Ahem` フォント（四角い黒塗りブロック）に自動置換されます。
これにより、**OS間のフォント差異を100%排除**し、レイアウト、配置、余白、サイズ、配色、コントラスト判定の崩れを決定論的に検証できます。

---

## 2. 導入・設定手順

### 2-1. 依存関係の追加
テスト対象パッケージの `pubspec.yaml` の `dev_dependencies` に `alchemist` を追加します。

```yaml
dev_dependencies:
  alchemist: ^0.14.0
```

### 2-2. グローバル設定 (`test/flutter_test_config.dart`)
テスト実行時に Alchemist の CI Goldens モード（Ahemフォント）を一貫して強制します。

```dart
import 'dart:async';

import 'package:alchemist/alchemist.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) =>
    AlchemistConfig.runWithConfig(
      config: const AlchemistConfig(
        // プラットフォーム固有（実フォント）の比較は無効化し、OS差異を排除
        platformGoldensConfig: PlatformGoldensConfig(
          enabled: false,
        ),
        // CIモード（Ahemフォント）を常時有効化
        ciGoldensConfig: CiGoldensConfig(),
      ),
      // FutureOr<void> Function() を Future<void> Function() に適合させる
      run: () async => await testMain(),
    );
```

> **重要**: `run: () async => await testMain()` と記述してください。`AlchemistConfig.runWithConfig` の `run` 引数は `Future<void> Function()` を要求するため、`run: testMain` と直接渡すと Dart の静的解析エラー（`argument_type_not_assignable`）が発生します。

### 2-3. テストタグの定義 (`test/dart_test.yaml` または `dart_test.yaml`)
`alchemist` の `goldenTest` はデフォルトで `tags: ['golden']` を付与します。未定義タグ警告を防ぐため、パッケージルートの `dart_test.yaml` にタグを宣言します。

```yaml
tags:
  golden:
```

---

## 3. テストハーネス設計パターン

Riverpod、多言語対応（L10n）、Theme（Light / Dark）、およびアセットバンドル（`TestAssetBundle`）を1箇所で安全に統合するラッパーヘルパー（例: `appGoldenTest`）を用意します。

```dart
// test/util/golden_test_harness.dart
import 'package:alchemist/alchemist.dart' hide TestAssetBundle;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

export 'package:alchemist/alchemist.dart' hide TestAssetBundle;

Future<void> appGoldenTest(
  String description, {
  required String fileName,
  required Widget Function() builder,
  List<Override> overrides = const [],
  ThemeData? theme,
  List<String> tags = const ['golden'],
  BoxConstraints constraints = const BoxConstraints(),
  PumpAction pumpBeforeTest = onlyPumpAndSettle,
}) async {
  await goldenTest(
    description,
    fileName: fileName,
    tags: tags,
    constraints: constraints,
    pumpBeforeTest: pumpBeforeTest,
    builder: builder,
    pumpWidget: (tester, widget) async {
      final container = ProviderContainer(
        overrides: [
          ...defaultTestOverrides,
          ...overrides,
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: Localizations(
            locale: const Locale('ja'),
            delegates: AppLocalizations.localizationsDelegates,
            child: DefaultAssetBundle(
              bundle: TestAssetBundle(),
              child: Theme(
                data: theme ?? defaultAppTheme,
                child: widget,
              ),
            ),
          ),
        ),
      );
    },
  );
}
```

---

## 4. テストケースの記述方法

`GoldenTestGroup` と `GoldenTestScenario` を使用することで、複数シナリオ（通常状態、長文テキスト、低コントラスト、ダークモード等）を1枚のグリッド画像にまとめて出力できます。

```dart
// test/golden/widgets/empty_view_golden_test.dart
import 'package:flutter/material.dart';
import 'package:your_app/widgets/empty_view.dart';
import '../../util/golden_test_harness.dart';

void main() {
  appGoldenTest(
    'EmptyView scenarios',
    fileName: 'empty_view',
    builder: () => GoldenTestGroup(
      columns: 2,
      scenarioConstraints: const BoxConstraints(
        minWidth: 320,
        maxWidth: 320,
        minHeight: 180,
        maxHeight: 180,
      ),
      children: [
        GoldenTestScenario(
          name: 'Title only',
          child: const ColoredBox(
            color: Colors.white,
            child: EmptyView(title: 'データがありません'),
          ),
        ),
        GoldenTestScenario(
          name: 'Title and Message',
          child: const ColoredBox(
            color: Colors.white,
            child: EmptyView(
              title: 'アイテムがありません',
              message: '右下の＋ボタンから追加してください',
            ),
          ),
        ),
        GoldenTestScenario(
          name: 'Long text wrap',
          child: const ColoredBox(
            color: Colors.white,
            child: EmptyView(
              title: '非常に長いタイトルの表示検証テキストです',
              message: '説明文も複数行にわたって表示され、中央揃えと余白が正しく維持されることを検証します。',
            ),
          ),
        ),
        GoldenTestScenario(
          name: 'Dark Mode',
          child: Theme(
            data: appDarkTheme,
            child: ColoredBox(
              color: appDarkTheme.scaffoldBackgroundColor,
              child: const EmptyView(
                title: 'ダークモード表示',
                message: 'ダークモード時のテキストカラーと視認性を検証します',
              ),
            ),
          ),
        ),
      ],
    ),
  );
}
```

---

## 5. コマンド・CI連携と運用

### 5-1. ローカルでの実行と更新
- **検証のみ実行**:
  ```bash
  flutter test test/golden
  ```
- **ゴールデン画像の初回生成・更新**:
  ```bash
  flutter test test/golden --update-goldens
  ```
- 生成された画像（`test/**/goldens/ci/*.png`）は Git にコミットして管理します。

### 5-2. Taskfile (`Taskfile.yml`) の定義例
```yaml
  test-golden:
    desc: Goldenテストを実行します (更新する場合は -- --update-goldens)
    dir: packages/app
    cmds:
      - flutter test test/golden {{.CLI_ARGS}}
```

### 5-3. GitHub Actions CI での失敗差分保存 (`check.yml`)
Goldenテストが失敗した際、差分画像（`failures/`）をアーティファクトとして保存することで、GitHub Actions の Web UI から容易に視覚差分を確認できるようにします。

```yaml
      - name: Upload golden test failures
        uses: actions/upload-artifact@v4
        if: failure()
        with:
          name: golden-failures
          path: '**/failures/'
          if-no-files-found: ignore
```

### 5-4. FVM / Git Worktree 利用時の注意点
`.fvm` ディレクトリは一般に `.gitignore` されているため、新しい git worktree を作成・復元した直後は Flutter SDK へのシンボリックリンクが存在せず、`melos bootstrap` やテストが失敗する場合があります。
必ず worktree 内で `fvm use stable`（または該当バージョン）を実行して SDK パスを解決してから依存関係を更新してください。
