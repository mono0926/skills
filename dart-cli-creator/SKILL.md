---
name: dart-cli-creator
description: Dartを用いた堅牢で保守性の高いCLIツールを作成・改善するためのスキル。ベストプラクティスを網羅しています。
---

# Dart CLI Creator Skill

このスキルは、Dartを用いて最高品質のCommand-Line Interface (CLI) ツールを作成・改善するためのガイドラインと手順です。
あなた(エージェント)は、ユーザーからDart CLIの作成・改修を依頼された際、常にこのベストプラクティスに従って作業を進めてください。

## 🎯 コア・ベストプラクティス

### 1. プロジェクト構造・設計

- **`bin/`ディレクトリ**: CLIのエントリポイントとなる実行ファイル（例: `bin/my_cli.dart`）を配置します。ここには複雑なロジックは書かず、`lib/`または`src/`のトップレベル関数やクラスを呼び出すだけの薄いラッパーにします。
- **`lib/`ディレクトリ**: ビジネスロジック、コマンドの実装、再利用可能なユーティリティを配置します（例: `lib/src/commands/`、`lib/src/utils/`）。
- **責務の分離**: CLIの入出力部分（引数のパースやUI描画）とコアなビジネスロジックは必ず分離し、テスタビリティを高めます。

### 2. コマンドライン引数とコマンドルーティング

- **`args`パッケージを活用**: 標準の`args`パッケージにある`CommandRunner`と`Command`クラスを使用して、Gitライクなサブコマンド対応のCLIを構築します。
- **自己文書化**: 各コマンドやフラグ・オプションには`description`や`help`を丁寧に記述し、`--help`で十分な使い方が表示されるようにします。

### 3. リッチなUX (ユーザー体験) とロギング

- **`mason_logger`の積極利用**: 標準の`print`は避け、`mason_logger`パッケージを利用します。
  - `logger.info()`, `logger.success()`, `logger.err()`, `logger.warn()` で色分けされた出力。
  - 時間のかかる処理には `logger.progress('Doing something...')` を用いてスピナーを表示。
  - ユーザーの確認（y/n）や文字入力には `logger.confirm()` や `logger.prompt()` を活用。また、より高度なメニュー選択やスピナー等が必要な場合は `interact` パッケージを併用します。
  - **Tip:** 実用的な構成として、`lib/logger.dart` にトップレベルで `final logger = Logger();` と定義し、プロジェクト全体でimportして使うとボイラープレートが減り非常に便利です（DIを必須としない小〜中規模のCLIツールに最適）。
- **`cli_completion`**: シェル補完機能を提供するために、`cli_completion` パッケージの利用を検討し、`CompletionCommandRunner` を継承して実装します。

### 4. 正しいエラーハンドリングと終了の手法

- **終了コード(Exit Code)**: 処理結果は必ず適切な終了コードとして扱います（成功時は `0`、エラー時は `1` または `sysexits` 準拠のエラーコード等）。
- **直接の `exit()` は避ける**: `exit()`を直接呼ぶと、Dart VMが即座に強制終了し、リソースのクリーンアップ(`finally`ブロックなど)が実行されない可能性があります。`CommandRunner.run()`の戻り値として`int`を返し、`main`関数に伝播させ、`exitCode`プロパティにセットして自然終了(`Process.stdout.close()`等の待機後)させます。
- **カスタム例外クラスの定義とハンドリング**: 独自ドメインの例外クラス（例: `AppException`）を定義し、深い階層でスローします。
- **グローバルな例外捕捉**: `CommandRunner`の実行全体を`try-catch`で囲み、`AppException`, `UsageException` や未補足例外をハンドリングします。スタックトレースをユーザーに直接見せるのではなく、`logger.err(e.message)` のように丁寧にエラー出力し、適切な終了コードを返します。

### 5. 静的解析とコードフォーマット

- **`pedantic_mono`の適用**: `analysis_options.yaml`に`pedantic_mono`を設定し、厳格な静的解析ルールに従います。
- コード変更後は必ずエラー・警告をゼロにします。

### 6. 配布・実行のための設定

- **Shebang**: `bin/`直下の実行ファイルの1行目には、必ず `#!/usr/bin/env dart` を記述します。
- **Pubspecの設定**: `pubspec.yaml`の`executables:`セクションでCLIコマンド名を定義し、`dart pub global activate`で簡単にインストールできるようにします。

### 7. アップデート通知機能 (Auto-update check)

- **`pub_updater` を活用**: コマンド実行の都度または定期的に `pub_updater` を用いて、`pub.dev` 等に新しいバージョンがリリースされていないかチェックします。
- 新バージョンがある場合は、`logger.warn('Update available!')` や、`interact` ベースのプロンプトで更新を促すインタラクティブなUIを提供します。

---

## 🛠️ プロジェクトのスケルトン(基本実装例)

CLIを作成する際は、以下のような構造と実装をベースにします。

### `pubspec.yaml` の一部

```yaml
dependencies:
  args: ^2.5.0
  cli_completion: ^0.4.0
  mason_logger: ^0.2.16
  pub_updater: ^0.4.0

dev_dependencies:
  pedantic_mono: any
  test: ^1.24.0

executables:
  my_cli:
```

### `bin/my_cli.dart`

```dart
#!/usr/bin/env dart
import 'dart:io';
import 'package:my_cli/command_runner.dart';

Future<void> main(List<String> arguments) async {
  final exitCode = await MyCliCommandRunner().run(arguments);
  await flushThenExit(exitCode ?? 0);
}

/// [status]をexitCodeに設定し、標準出力/標準エラーのフラッシュを待って終了するヘルパー
Future<void> flushThenExit(int status) async {
  exitCode = status;
  await Future.wait<void>([
    stdout.close(),
    stderr.close(),
  ]);
}
```

### `lib/logger.dart`

```dart
import 'package:mason_logger/mason_logger.dart';

/// アプリケーション共通の [Logger]。
final logger = Logger();
```

### `lib/command_runner.dart`

```dart
import 'package:args/args.dart';
import 'package:cli_completion/cli_completion.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:pub_updater/pub_updater.dart';
import 'package:my_cli/logger.dart';

class MyCliCommandRunner extends CompletionCommandRunner<int> {
  final PubUpdater _pubUpdater;

  MyCliCommandRunner({PubUpdater? pubUpdater})
      : _pubUpdater = pubUpdater ?? PubUpdater(),
        super('my_cli', 'A highly robust Dart CLI tool.') {
    argParser
      ..addFlag(
        'version',
        abbr: 'v',
        negatable: false,
        help: 'Print the current version.',
      )
      ..addFlag(
        'verbose',
        help: 'Enable verbose logging.',
      );
    // TODO: addCommand(MyCustomCommand());
  }

  Future<void> _checkForUpdates() async {
    try {
      final isUpToDate = await _pubUpdater.isUpToDate(
        packageName: 'my_cli',
        currentVersion: '1.0.0', // 本来は packageVersion
      );
      if (!isUpToDate) {
        final latestVersion = await _pubUpdater.getLatestVersion('my_cli');
        logger.info('\nUpdate available: $latestVersion');
      }
    } catch (_) {}
  }

  @override
  Future<int> run(Iterable<String> args) async {
    try {
      final argResults = parse(args);
      if (argResults['verbose'] == true) {
        logger.level = Level.verbose;
      }

      // バージョン更新チェック (非同期でバックグラウンド実行も検討)
      await _checkForUpdates();

      return await runCommand(argResults) ?? 0;
    } on FormatException catch (e) {
      logger
        ..err(e.message)
        ..info('')
        ..info(usage);
      return 64; // usage error
    } on UsageException catch (e) {
      logger
        ..err(e.message)
        ..info('')
        ..info(usage);
      return 64;
    } on AppException catch (e) {
      // カスタム例外はきれいにエラー出力
      logger.err(e.message);
      return 1;
    } catch (e, stackTrace) {
      logger
        ..err('An unexpected error occurred: $e')
        ..err('$stackTrace');
      return 1;
    }
  }

  @override
  Future<int?> runCommand(ArgResults topLevelResults) async {
    if (topLevelResults['version'] == true) {
      logger.info('my_cli version: 1.0.0');
      return 0;
    }
    return super.runCommand(topLevelResults);
  }
}

/// ドメイン固有のカスタム例外
class AppException implements Exception {
  const AppException(this.message);
  final String message;
  @override
  String toString() => message;
}
```

### `lib/src/commands/my_custom_command.dart`

```dart
import 'package:args/command_runner.dart';
import 'package:my_cli/logger.dart';

class MyCustomCommand extends Command<int> {
  MyCustomCommand() {
    argParser.addOption(
      'name',
      abbr: 'n',
      help: 'Your name.',
      mandatory: true,
    );
  }

  @override
  String get description => 'A custom command example.';

  @override
  String get name => 'hello';

  @override
  Future<int> run() async {
    final name = argResults?['name'] as String?;
    final progress = logger.progress('Saying hello to \$name...');

    // 時間のかかる処理のシミュレート
    await Future<void>.delayed(const Duration(seconds: 1));

    progress.complete('Hello, \$name!');
    return 0; // Success
  }
}
```

## 🤖 エージェントへの指示

ユーザーから「〇〇をするツールのCLIを作って」等と依頼された場合:

1. このスキルの内容に沿って、`args`と`mason_logger`を軸としたプロジェクトを構成してください。
2. ディレクトリ構成を決定し、要件定義に基づくコマンド群を整理・提案してください。
3. `pedantic_mono`を導入し、厳格な静的解析を前提とした高品質なコードを生成してください。
4. (必要なら) 開発完了後に、`README.md` にCLIの使い方( Usage )を記載し、`dart pub global activate --source path .`によるインストール手順などをユーザーに提示してください。
