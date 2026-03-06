import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:release_helper/src/commands/prepare_command.dart';
import 'package:test/test.dart';

void main() {
  group('PrepareCommand', () {
    late Directory tempDir;
    late CommandRunner<int> runner;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('prepare_test_');
      runner = CommandRunner<int>('test', 'test')..addCommand(PrepareCommand());
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    test('updates pubspec and changelog simultaneously', () async {
      final pubspecFile = File('${tempDir.path}/pubspec.yaml');
      await pubspecFile.writeAsString('''
name: test_pkg
version: 1.0.0
''');

      final changelogFile = File('${tempDir.path}/CHANGELOG.md');
      await changelogFile.writeAsString('''
## 0.9.0 - 2024-01-01

- Initial release
''');

      final result = await runner.run([
        'prepare',
        'minor',
        '--pubspec',
        pubspecFile.path,
        '--changelog',
        changelogFile.path,
        '--notes',
        '- New feature A\n- Fix B',
      ]);

      expect(result, equals(0));

      final pubspecContent = await pubspecFile.readAsString();
      expect(pubspecContent, contains('version: 1.1.0'));

      final changelogContent = await changelogFile.readAsString();
      expect(changelogContent, contains('## 1.1.0 -'));
      expect(changelogContent, contains('- New feature A'));
      expect(changelogContent, contains('- Fix B'));
      expect(changelogContent, contains('## 0.9.0 -'));
    });

    test('dry-run does not write to files', () async {
      final pubspecFile = File('${tempDir.path}/pubspec.yaml');
      await pubspecFile.writeAsString('''
name: test_pkg
version: 1.0.0
''');

      final changelogFile = File('${tempDir.path}/CHANGELOG.md');
      await changelogFile.writeAsString('''
## 0.9.0 - 2024-01-01
''');

      final result = await runner.run([
        'prepare',
        'minor',
        '--pubspec',
        pubspecFile.path,
        '--changelog',
        changelogFile.path,
        '--notes',
        '- Some notes',
        '--dry-run',
      ]);

      expect(result, equals(0));

      final pubspecContent = await pubspecFile.readAsString();
      expect(pubspecContent, contains('version: 1.0.0'));

      final changelogContent = await changelogFile.readAsString();
      expect(changelogContent, isNot(contains('## 1.1.0 -')));
    });

    test('works when changelog does not exist', () async {
      final pubspecFile = File('${tempDir.path}/pubspec.yaml');
      await pubspecFile.writeAsString('''
name: test_pkg
version: 1.0.0
''');

      final changelogFile = File('${tempDir.path}/CHANGELOG.md');

      final result = await runner.run([
        'prepare',
        'patch',
        '--pubspec',
        pubspecFile.path,
        '--changelog',
        changelogFile.path,
        '--notes',
        '- Patch note',
      ]);

      expect(result, equals(0));
      expect(changelogFile.existsSync(), isTrue);
      final changelogContent = await changelogFile.readAsString();
      expect(changelogContent, contains('## 1.0.1 -'));
      expect(changelogContent, contains('- Patch note'));
    });
  });
}
