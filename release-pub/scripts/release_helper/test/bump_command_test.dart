import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:release_helper/src/commands/bump_command.dart';
import 'package:test/test.dart';

void main() {
  group('BumpCommand', () {
    late Directory tempDir;
    late CommandRunner<int> runner;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('bump_test_');
      runner = CommandRunner<int>('test', 'test')..addCommand(BumpCommand());
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    test('bumps version from 1.0.0 to 1.1.0 (minor)', () async {
      final pubspecFile = File('${tempDir.path}/pubspec.yaml');
      await pubspecFile.writeAsString('''
name: test_pkg
version: 1.0.0
''');

      final result = await runner.run([
        'bump',
        'minor',
        '-f',
        pubspecFile.path,
      ]);

      expect(result, equals(0));
      final content = await pubspecFile.readAsString();
      expect(content, contains('version: 1.1.0'));
    });

    test('bumps version from 1.0.0 to 2.0.0 (major)', () async {
      final pubspecFile = File('${tempDir.path}/pubspec.yaml');
      await pubspecFile.writeAsString('''
name: test_pkg
version: 1.0.0
''');

      final result = await runner.run([
        'bump',
        'major',
        '-f',
        pubspecFile.path,
      ]);

      expect(result, equals(0));
      final content = await pubspecFile.readAsString();
      expect(content, contains('version: 2.0.0'));
    });

    test('sets version to 1.2.3 exactly', () async {
      final pubspecFile = File('${tempDir.path}/pubspec.yaml');
      await pubspecFile.writeAsString('''
name: test_pkg
version: 1.0.0
''');

      final result = await runner.run([
        'bump',
        '1.2.3',
        '-f',
        pubspecFile.path,
      ]);

      expect(result, equals(0));
      final content = await pubspecFile.readAsString();
      expect(content, contains('version: 1.2.3'));
    });

    test('dry-run does not write to file', () async {
      final pubspecFile = File('${tempDir.path}/pubspec.yaml');
      await pubspecFile.writeAsString('''
name: test_pkg
version: 1.0.0
''');

      final result = await runner.run([
        'bump',
        'minor',
        '-f',
        pubspecFile.path,
        '--dry-run',
      ]);

      expect(result, equals(0));
      final content = await pubspecFile.readAsString();
      expect(content, contains('version: 1.0.0'));
    });

    test('preserves comments in pubspec.yaml', () async {
      final pubspecFile = File('${tempDir.path}/pubspec.yaml');
      await pubspecFile.writeAsString('''
name: test_pkg # package name
version: 1.0.0 # current version
''');

      await runner.run([
        'bump',
        'minor',
        '-f',
        pubspecFile.path,
      ]);

      final content = await pubspecFile.readAsString();
      expect(content, contains('name: test_pkg # package name'));
      expect(content, contains('version: 1.1.0 # current version'));
    });
  });
}
