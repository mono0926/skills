import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:release_helper/src/commands/changelog_command.dart';
import 'package:test/test.dart';

void main() {
  group('ChangelogCommand', () {
    late Directory tempDir;
    late CommandRunner<int> runner;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('changelog_test_');
      runner = CommandRunner<int>('test', 'test')
        ..addCommand(ChangelogCommand());
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    test('prepends new version to CHANGELOG.md', () async {
      final changelogFile = File('${tempDir.path}/CHANGELOG.md');
      await changelogFile.writeAsString(
        '## 1.0.0 - 2026-03-01\n\nInitial release.\n',
      );

      final result = await runner.run([
        'changelog',
        '1.1.0',
        '-f',
        changelogFile.path,
        '-n',
        '- Feature A\n- Feature B',
      ]);

      expect(result, equals(0));
      final content = await changelogFile.readAsString();
      expect(content, startsWith('## 1.1.0 - '));
      expect(content, contains('- Feature A'));
      expect(content, contains('## 1.0.0 - 2026-03-01'));
    });

    test('creates CHANGELOG.md if it does not exist', () async {
      final changelogFile = File('${tempDir.path}/CHANGELOG.md');

      final result = await runner.run([
        'changelog',
        '1.0.0',
        '-f',
        changelogFile.path,
        '-n',
        'Initial release.',
      ]);

      expect(result, equals(0));
      expect(changelogFile.existsSync(), isTrue);
      final content = await changelogFile.readAsString();
      expect(content, contains('Initial release.'));
    });

    test('skips if version already exists without force', () async {
      final changelogFile = File('${tempDir.path}/CHANGELOG.md');
      await changelogFile.writeAsString(
        '## 1.0.0 - 2026-03-01\n\nInitial release.\n',
      );

      final result = await runner.run([
        'changelog',
        '1.0.0',
        '-f',
        changelogFile.path,
        '-n',
        'Should be skipped.',
      ]);

      expect(result, equals(0));
      final content = await changelogFile.readAsString();
      expect(content, isNot(contains('Should be skipped.')));
    });

    test('overwrites (prepends) with force if version already exists', () async {
      final changelogFile = File('${tempDir.path}/CHANGELOG.md');
      await changelogFile.writeAsString(
        '## 1.0.0 - 2026-03-01\n\nInitial release.\n',
      );

      final result = await runner.run([
        'changelog',
        '1.0.0',
        '-f',
        changelogFile.path,
        '--force',
        '-n',
        'Overwritten notes.',
      ]);

      expect(result, equals(0));
      final content = await changelogFile.readAsString();
      expect(content, contains('Overwritten notes.'));
      // Note: current implementation prepends anyway if forced, so you'll have two entries.
      // But the check is mainly to prevent accidental duplicates.
    });
  });
}
