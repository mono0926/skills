import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

class UpgradedPackage {
  final String name;
  final String oldVersion;
  final String newVersion;
  String? changelogDiff;

  UpgradedPackage({
    required this.name,
    required this.oldVersion,
    required this.newVersion,
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'oldVersion': oldVersion,
        'newVersion': newVersion,
        'changelogDiff': changelogDiff,
      };
}

void main(List<String> args) async {
  final repoRoot = Directory.current;
  
  // 1. 未コミット変更のチェック
  print('Checking for uncommitted changes...');
  final statusResult = await Process.run('git', ['status', '--porcelain'], workingDirectory: repoRoot.path);
  final diffs = statusResult.stdout.toString().split('\n').where((diff) => diff.isNotEmpty);
  if (diffs.isNotEmpty) {
    stderr.writeln('Error: You have uncommitted changes. Please commit or stash them first.');
    exit(1);
  }

  // 2. ブランチの作成とチェックアウト
  final dateStr = DateTime.now().toIso8601String().substring(0, 10).replaceAll('-', '');
  final branchName = 'chore/deps/upgrade-packages-$dateStr';
  print('Creating topic branch: $branchName...');
  await Process.run('git', ['checkout', '-b', branchName], workingDirectory: repoRoot.path);

  // 以前の pubspec.lock の内容を保持
  print('Reading current pubspec.lock...');
  final oldLockFile = File(p.join(repoRoot.path, 'monoca_flutter', 'pubspec.lock'));
  if (!oldLockFile.existsSync()) {
    stderr.writeln('Error: pubspec.lock not found at ${oldLockFile.path}');
    exit(1);
  }
  final oldLockContent = oldLockFile.readAsStringSync();
  final oldLockMap = parseLockFile(oldLockContent);

  // 3. パッケージのアップグレード実行
  print('Upgrading packages with --major-versions...');
  final upgradeResult = await Process.start(
    'fvm',
    ['flutter', 'pub', 'upgrade', '--major-versions'],
    workingDirectory: p.join(repoRoot.path, 'monoca_flutter'),
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
  print('Reading updated pubspec.lock...');
  final newLockContent = oldLockFile.readAsStringSync();
  final newLockMap = parseLockFile(newLockContent);

  // アップグレードされたパッケージの抽出
  final upgradedPackages = <UpgradedPackage>[];
  newLockMap.forEach((package, newVer) {
    final oldVer = oldLockMap[package];
    if (oldVer != null && oldVer != newVer) {
      upgradedPackages.add(UpgradedPackage(
        name: package,
        oldVersion: oldVer,
        newVersion: newVer,
      ));
    }
  });

  if (upgradedPackages.isEmpty) {
    print('No packages were upgraded.');
    // ブランチを元に戻して終了
    await Process.run('git', ['checkout', '-'], workingDirectory: repoRoot.path);
    await Process.run('git', ['branch', '-d', branchName], workingDirectory: repoRoot.path);
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

  // 5. 結果を一時ファイルにJSON出力
  final tempDir = Directory(p.join(repoRoot.path, '.dart_pub_upgrade_temp'));
  if (!tempDir.existsSync()) {
    tempDir.createSync(recursive: true);
  }
  final tempFile = File(p.join(tempDir.path, 'changelog_diffs.json'));
  tempFile.writeAsStringSync(jsonEncode(upgradedPackages.map((p) => p.toJson()).toList()));
  print('\nChangelog diffs written to ${tempFile.path}');

  // 6. 変更をコミット
  print('Committing changes...');
  await Process.run('git', ['add', '--all'], workingDirectory: repoRoot.path);
  await Process.run('git', ['commit', '-m', 'chore(deps): パッケージの一括アップグレード'], workingDirectory: repoRoot.path);
  print('Changes committed successfully to branch $branchName.');
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
      // "2.7.0" のようにダブルクォートで囲まれている場合とそうでない場合に対応
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
  
  // バージョン番号表記にマッチする正規表現（例: ## 1.2.0, [1.2.0], # 1.2.0-beta など）
  // バージョン番号のセパレータ（ピリオド）をエスケープしたパターンを作成
  final escapedOldVersion = RegExp.escape(oldVersion);
  final oldVerRegexp = RegExp('(^|[^0-9.])$escapedOldVersion([^0-9.]|\$)');

  for (final line in lines) {
    // 古いバージョンの見出し行が見つかったら、そこから下の行の解析を打ち切る
    if (oldVerRegexp.hasMatch(line) && 
        (line.startsWith('#') || line.startsWith('[') || line.trim().startsWith('-'))) {
      break;
    }
    diffLines.add(line);
  }
  return diffLines.join('\n').trim();
}
