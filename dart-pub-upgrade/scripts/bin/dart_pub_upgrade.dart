import 'dart:convert';
import 'dart:io';
import 'package:args/args.dart';
import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

class UpgradedPackage {
  final String name;
  final String oldVersion;
  final String newVersion;
  final bool isDirect;
  String? changelogDiff;

  UpgradedPackage({
    required this.name,
    required this.oldVersion,
    required this.newVersion,
    required this.isDirect,
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'oldVersion': oldVersion,
        'newVersion': newVersion,
        'isDirect': isDirect,
        'changelogDiff': changelogDiff,
      };
}

void main(List<String> args) async {
  final parser = ArgParser()
    ..addFlag(
      'help',
      abbr: 'h',
      negatable: false,
      help: 'Show usage information.',
    )
    ..addOption(
      'path',
      abbr: 'p',
      defaultsTo: '.',
      help: 'Path to the Dart/Flutter project directory containing pubspec.yaml/pubspec.lock.',
    )
    ..addFlag(
      'fix',
      defaultsTo: true,
      help: 'Automatically run dart fix after upgrading.',
    )
    ..addFlag(
      'analyze',
      defaultsTo: true,
      help: 'Automatically run dart analyze after upgrading.',
    );

  final argResults = parser.parse(args);
  if (argResults['help'] as bool) {
    print('Usage: dart_pub_upgrade [options]\n');
    print(parser.usage);
    exit(0);
  }

  final projectPath = argResults['path'] as String;
  final runFix = argResults['fix'] as bool;
  final runAnalyze = argResults['analyze'] as bool;

  final currentDir = Directory.current;
  final projectDir = Directory(p.canonicalize(p.join(currentDir.path, projectPath)));

  if (!projectDir.existsSync()) {
    stderr.writeln('Error: Project directory does not exist: ${projectDir.path}');
    exit(1);
  }

  final pubspecFile = File(p.join(projectDir.path, 'pubspec.yaml'));
  final lockFile = File(p.join(projectDir.path, 'pubspec.lock'));

  if (!pubspecFile.existsSync()) {
    stderr.writeln('Error: pubspec.yaml not found in project directory: ${projectDir.path}');
    exit(1);
  }

  // Gitルートの特定
  final gitRoot = findGitRoot(projectDir);
  if (gitRoot == null) {
    stderr.writeln('Error: Git repository root not found from: ${projectDir.path}');
    exit(1);
  }
  print('Git repository root identified: ${gitRoot.path}');
  print('Project directory: ${projectDir.path}');

  // 1. 未コミット変更のチェック
  print('Checking for uncommitted changes in Git repository...');
  final statusResult = await Process.run('git', ['status', '--porcelain'], workingDirectory: gitRoot.path);
  final statusLines = statusResult.stdout.toString().split('\n').where((line) => line.isNotEmpty);
  if (statusLines.isNotEmpty) {
    stderr.writeln('Error: You have uncommitted changes. Please commit or stash them first.');
    exit(1);
  }

  // 直接依存パッケージの自動収集
  print('Collecting direct dependencies from project pubspec.yaml files...');
  final directDepsSet = collectDirectDependencies(projectDir);

  // 2. ブランチの作成とチェックアウト
  final dateStr = DateTime.now().toIso8601String().substring(0, 10).replaceAll('-', '');
  final branchName = 'chore/deps/upgrade-packages-$dateStr';
  print('Creating topic branch: $branchName...');
  await Process.run('git', ['checkout', '-b', branchName], workingDirectory: gitRoot.path);

  // 以前の pubspec.lock の内容を保持
  String oldLockContent = '';
  if (lockFile.existsSync()) {
    print('Reading current pubspec.lock...');
    oldLockContent = lockFile.readAsStringSync();
  }
  final oldLockMap = parseLockFile(oldLockContent);

  // 3. パッケージのアップグレード実行コマンドの決定と実行
  final upgradeCmd = detectUpgradeCommand(projectDir);
  print('Upgrading packages with command: ${upgradeCmd.join(' ')}...');
  final upgradeResult = await Process.start(
    upgradeCmd.first,
    upgradeCmd.sublist(1),
    workingDirectory: projectDir.path,
    runInShell: true,
  );
  await stdout.addStream(upgradeResult.stdout);
  await stderr.addStream(upgradeResult.stderr);
  final exitCode = await upgradeResult.exitCode;
  if (exitCode != 0) {
    stderr.writeln('Error: pub upgrade failed with exit code $exitCode');
    exit(1);
  }

  // 新しい pubspec.lock の読込
  if (!lockFile.existsSync()) {
    stderr.writeln('Error: pubspec.lock was not generated after upgrade.');
    exit(1);
  }
  print('Reading updated pubspec.lock...');
  final newLockContent = lockFile.readAsStringSync();
  final newLockMap = parseLockFile(newLockContent);

  // アップグレードされたパッケージの抽出
  final upgradedPackages = <UpgradedPackage>[];
  newLockMap.forEach((package, newVer) {
    final oldVer = oldLockMap[package];
    if (oldVer != null && oldVer != newVer) {
      final isDirect = directDepsSet.contains(package);
      upgradedPackages.add(UpgradedPackage(
        name: package,
        oldVersion: oldVer,
        newVersion: newVer,
        isDirect: isDirect,
      ));
    }
  });

  if (upgradedPackages.isEmpty) {
    print('No packages were upgraded.');
    // ブランチを元に戻して終了
    await Process.run('git', ['checkout', '-'], workingDirectory: gitRoot.path);
    await Process.run('git', ['branch', '-d', branchName], workingDirectory: gitRoot.path);
    return;
  }

  print('\nFound ${upgradedPackages.length} upgraded packages.');

  // 4. 並行処理で pub.dev から CHANGELOG.md を取得・解析
  print('Fetching CHANGELOGs from pub.dev concurrently...');
  final client = http.Client();
  try {
    await Future.wait(upgradedPackages.map((package) async {
      try {
        final changelog = await fetchChangelog(client, package.name, package.newVersion);
        if (changelog != null) {
          package.changelogDiff = extractDiff(changelog, package.oldVersion);
        }
      } catch (e, stack) {
        print('  Failed to fetch/parse changelog for ${package.name}: $e');
        print(stack);
      }
    }));
  } finally {
    client.close();
  }

  // 5. 結果を一時ファイルにJSON出力 (git ignore されている .dart_tool 配下に書き出す)
  final tempDir = Directory(p.join(projectDir.path, '.dart_tool', 'dart_pub_upgrade'));
  if (!tempDir.existsSync()) {
    tempDir.createSync(recursive: true);
  }
  final tempFile = File(p.join(tempDir.path, 'changelog_diffs.json'));
  tempFile.writeAsStringSync(jsonEncode(upgradedPackages.map((p) => p.toJson()).toList()));
  print('\nChangelog diffs written to ${tempFile.path}');

  // 6. アップグレード変更をコミット
  print('Committing package upgrade changes...');
  await Process.run('git', ['add', '--all'], workingDirectory: gitRoot.path);
  await Process.run('git', ['commit', '-m', 'chore(deps): パッケージの一括アップグレード'], workingDirectory: gitRoot.path);
  print('Package upgrade changes committed successfully to branch $branchName.');

  // 7. 自動修正 (dart fix) の実行
  final isMelos = File(p.join(projectDir.path, 'melos.yaml')).existsSync() ||
      File(p.join(gitRoot.path, 'melos.yaml')).existsSync();

  if (runFix) {
    print('\nRunning automatic code fixes (dart fix)...');
    if (isMelos) {
      print('Running melos bootstrap & dart fix...');
      await Process.run('melos', ['bootstrap'], workingDirectory: projectDir.path, runInShell: true);
      await Process.run('melos', ['exec', '--', 'dart fix --apply'], workingDirectory: projectDir.path, runInShell: true);
    } else {
      await Process.run('dart', ['fix', '--apply'], workingDirectory: projectDir.path, runInShell: true);
    }

    final postFixStatus = await Process.run('git', ['status', '--porcelain'], workingDirectory: gitRoot.path);
    if (postFixStatus.stdout.toString().trim().isNotEmpty) {
      print('Committing automatic fixes...');
      await Process.run('git', ['add', '--all'], workingDirectory: gitRoot.path);
      await Process.run('git', ['commit', '-m', 'fix(deps): パッケージ変更に伴う自動修正 (dart fix)'], workingDirectory: gitRoot.path);
      print('Automatic fixes committed.');
    } else {
      print('No automatic code fixes were required.');
    }
  }

  // 8. 静的解析 (dart analyze) の実行
  if (runAnalyze) {
    print('\nRunning static analysis...');
    final analyzeResult = isMelos
        ? await Process.run('melos', ['exec', '--', 'dart analyze'], workingDirectory: projectDir.path, runInShell: true)
        : await Process.run('dart', ['analyze'], workingDirectory: projectDir.path, runInShell: true);

    print(analyzeResult.stdout);
    if (analyzeResult.stderr.toString().isNotEmpty) {
      stderr.writeln(analyzeResult.stderr);
    }
  }
}

// Gitルートを探して遡る
Directory? findGitRoot(Directory startDir) {
  var dir = startDir;
  while (true) {
    final gitDir = Directory(p.join(dir.path, '.git'));
    if (gitDir.existsSync()) {
      return dir;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) {
      break;
    }
    dir = parent;
  }
  return null;
}

// プロジェクト内のすべての pubspec.yaml から直接依存しているパッケージ名を抽出
Set<String> collectDirectDependencies(Directory projectDir) {
  final directDeps = <String>{};
  final entities = projectDir.listSync(recursive: true, followLinks: false);
  for (final entity in entities) {
    if (entity is File && p.basename(entity.path) == 'pubspec.yaml') {
      final path = entity.path;
      if (path.contains('/.dart_tool/') ||
          path.contains('/.fvm/') ||
          path.contains('/build/') ||
          path.contains('/.git/')) {
        continue;
      }
      try {
        final content = entity.readAsStringSync();
        final yaml = loadYaml(content);
        if (yaml is Map) {
          final deps = yaml['dependencies'];
          if (deps is Map) {
            for (final key in deps.keys) {
              directDeps.add(key.toString());
            }
          }
          final devDeps = yaml['dev_dependencies'];
          if (devDeps is Map) {
            for (final key in devDeps.keys) {
              directDeps.add(key.toString());
            }
          }
        }
      } catch (_) {}
    }
  }
  return directDeps;
}

// 適切なアップグレードコマンドの自動判定
List<String> detectUpgradeCommand(Directory projectDir) {
  // 1. FVMの構成が存在するかチェック
  final fvmDir = Directory(p.join(projectDir.path, '.fvm'));
  if (fvmDir.existsSync()) {
    return ['fvm', 'flutter', 'pub', 'upgrade', '--major-versions'];
  }
  
  // 2. pubspec.yaml をチェックして Flutter の依存関係があるか判定
  final pubspecFile = File(p.join(projectDir.path, 'pubspec.yaml'));
  if (pubspecFile.existsSync()) {
    final content = pubspecFile.readAsStringSync();
    if (content.contains('sdk: flutter') || content.contains('flutter:')) {
      return ['flutter', 'pub', 'upgrade', '--major-versions'];
    }
  }
  
  // 3. 純粋な Dart プロジェクト
  return ['dart', 'pub', 'upgrade', '--major-versions'];
}

// 簡易 YAML parser (pubspec.lock からパッケージ名とバージョンを読み出す)
Map<String, String> parseLockFile(String content) {
  final map = <String, String>{};
  final lines = content.split('\n');
  String? currentPackage;
  for (final line in lines) {
    if (line.startsWith('  ') && !line.startsWith('    ')) {
      currentPackage = line.trim().replaceAll(':', '');
    } else if (line.startsWith('    version: ') && currentPackage != null) {
      final rawVersion = line.replaceAll('    version: ', '').trim();
      final version = rawVersion.replaceAll('"', '');
      map[currentPackage] = version;
    }
  }
  return map;
}

// pub.dev の tarball から CHANGELOG.md を抽出
Future<String?> fetchChangelog(http.Client client, String packageName, String version) async {
  final metadataUrl = 'https://pub.dev/api/packages/$packageName/versions/$version';
  final metadataResponse = await client.get(Uri.parse(metadataUrl));
  if (metadataResponse.statusCode != 200) return null;

  final metadata = jsonDecode(metadataResponse.body) as Map<String, dynamic>;
  final archiveUrl = metadata['archive_url'] as String?;
  if (archiveUrl == null) return null;

  final archiveResponse = await client.get(Uri.parse(archiveUrl));
  if (archiveResponse.statusCode != 200) return null;

  final tarBytes = GZipDecoder().decodeBytes(archiveResponse.bodyBytes);
  final archive = TarDecoder().decodeBytes(tarBytes);

  for (final file in archive) {
    if (file.isFile && file.name.toLowerCase() == 'changelog.md') {
      return utf8.decode(file.content as List<int>);
    }
  }
  return null;
}

// CHANGELOG.md のテキストから旧バージョン以前の記述を削除して差分を抽出
String extractDiff(String changelog, String oldVersion) {
  final lines = changelog.split('\n');
  final diffLines = <String>[];
  
  final escapedOldVersion = RegExp.escape(oldVersion);
  final oldVerRegexp = RegExp('(^|[^0-9.])$escapedOldVersion([^0-9.]|\$)');

  for (final line in lines) {
    if (oldVerRegexp.hasMatch(line) && 
        (line.startsWith('#') || line.startsWith('[') || line.trim().startsWith('-'))) {
      break;
    }
    diffLines.add(line);
  }
  return diffLines.join('\n').trim();
}

