import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:release_helper/src/commands/check_score_command.dart';
import 'package:test/test.dart';

void main() {
  group('CheckScoreCommand', () {
    late Directory tempDir;
    late CommandRunner<int> runner;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('check_score_test_');
    });

    tearDown(() {
      tempDir.deleteSync(recursive: true);
    });

    test('returns 0 when score is perfect (160/160)', () async {
      final mockMetrics = <String, dynamic>{
        'scorecard': <String, dynamic>{
          'packageVersion': '1.0.0',
          'panaReport': <String, dynamic>{
            'report': <String, dynamic>{
              'sections': <Map<String, dynamic>>[
                <String, dynamic>{
                  'title': 'Follow Dart file conventions',
                  'grantedPoints': 30,
                  'maxPoints': 30,
                  'status': 'passed',
                },
                <String, dynamic>{
                  'title': 'Provide documentation',
                  'grantedPoints': 20,
                  'maxPoints': 20,
                  'status': 'passed',
                },
              ],
            },
          },
        },
        'score': <String, dynamic>{
          'grantedPoints': 160,
          'maxPoints': 160,
          'tags': <String>['is:wasm-ready', 'platform:ios', 'platform:android'],
        },
      };

      final cmd = CheckScoreCommand(
        fetcher: (uri) async => mockMetrics,
      );
      runner = CommandRunner<int>('test', 'test')..addCommand(cmd);

      final exitCode = await runner.run([
        'check-score',
        '1.0.0',
        '--package',
        'my_pkg',
        '--pubspec',
        '${tempDir.path}/pubspec.yaml',
      ]);

      expect(exitCode, equals(0));
    });

    test('returns 1 when score is deducted and min-score is not met', () async {
      final mockMetrics = <String, dynamic>{
        'scorecard': <String, dynamic>{
          'packageVersion': '1.0.0',
          'panaReport': <String, dynamic>{
            'report': <String, dynamic>{
              'sections': <Map<String, dynamic>>[
                <String, dynamic>{
                  'title': 'Pass static analysis',
                  'grantedPoints': 40,
                  'maxPoints': 50,
                  'status': 'failed',
                  'summary': '### line 81: async_return_with_no_await',
                },
              ],
            },
          },
        },
        'score': <String, dynamic>{
          'grantedPoints': 150,
          'maxPoints': 160,
          'tags': <String>['platform:ios'],
        },
      };

      final cmd = CheckScoreCommand(
        fetcher: (uri) async => mockMetrics,
      );
      runner = CommandRunner<int>('test', 'test')..addCommand(cmd);

      final exitCode = await runner.run([
        'check-score',
        '1.0.0',
        '--package',
        'my_pkg',
        '--pubspec',
        '${tempDir.path}/pubspec.yaml',
      ]);

      expect(exitCode, equals(1));
    });

    test('returns 0 if min-score is specified and grantedPoints >= minScore',
        () async {
      final mockMetrics = <String, dynamic>{
        'scorecard': <String, dynamic>{
          'packageVersion': '1.0.0',
          'panaReport': <String, dynamic>{
            'report': <String, dynamic>{
              'sections': <Map<String, dynamic>>[],
            },
          },
        },
        'score': <String, dynamic>{
          'grantedPoints': 150,
          'maxPoints': 160,
          'tags': <String>[],
        },
      };

      final cmd = CheckScoreCommand(
        fetcher: (uri) async => mockMetrics,
      );
      runner = CommandRunner<int>('test', 'test')..addCommand(cmd);

      final exitCode = await runner.run([
        'check-score',
        '1.0.0',
        '--package',
        'my_pkg',
        '--min-score',
        '140',
        '--pubspec',
        '${tempDir.path}/pubspec.yaml',
      ]);

      expect(exitCode, equals(0));
    });

    test('waits for target version when initial response has older version',
        () async {
      var callCount = 0;
      final cmd = CheckScoreCommand(
        pollIntervalOverride: const Duration(milliseconds: 1),
        fetcher: (uri) async {
          callCount++;
          if (callCount == 1) {
            return <String, dynamic>{
              'scorecard': <String, dynamic>{'packageVersion': '0.9.0'},
              'score': <String, dynamic>{
                'grantedPoints': 100,
                'maxPoints': 160,
              },
            };
          }
          return <String, dynamic>{
            'scorecard': <String, dynamic>{
              'packageVersion': '1.0.0',
              'panaReport': <String, dynamic>{
                'report': <String, dynamic>{
                  'sections': <Map<String, dynamic>>[],
                },
              },
            },
            'score': <String, dynamic>{
              'grantedPoints': 160,
              'maxPoints': 160,
              'tags': <String>['is:wasm-ready'],
            },
          };
        },
      );
      runner = CommandRunner<int>('test', 'test')..addCommand(cmd);

      final exitCode = await runner.run([
        'check-score',
        '1.0.0',
        '--package',
        'my_pkg',
        '--pubspec',
        '${tempDir.path}/pubspec.yaml',
      ]);

      expect(exitCode, equals(0));
      expect(callCount, equals(2));
    });

    test('times out if target version is not analyzed within timeout',
        () async {
      final cmd = CheckScoreCommand(
        pollIntervalOverride: const Duration(milliseconds: 10),
        fetcher: (uri) async => <String, dynamic>{
          'scorecard': <String, dynamic>{'packageVersion': '0.9.0'},
          'score': <String, dynamic>{'grantedPoints': 100, 'maxPoints': 160},
        },
      );
      runner = CommandRunner<int>('test', 'test')..addCommand(cmd);

      final exitCode = await runner.run([
        'check-score',
        '1.0.0',
        '--package',
        'my_pkg',
        '--timeout',
        '0',
        '--pubspec',
        '${tempDir.path}/pubspec.yaml',
      ]);

      expect(exitCode, equals(1));
    });

    test('reads package and version from pubspec.yaml if omitted', () async {
      final pubspec = File('${tempDir.path}/pubspec.yaml')
        ..writeAsStringSync('''
name: auto_pkg
version: 2.5.0
''');

      final cmd = CheckScoreCommand(
        fetcher: (uri) async {
          expect(uri.toString(), contains('/packages/auto_pkg/metrics'));
          return <String, dynamic>{
            'scorecard': <String, dynamic>{
              'packageVersion': '2.5.0',
              'panaReport': <String, dynamic>{
                'report': <String, dynamic>{
                  'sections': <Map<String, dynamic>>[],
                },
              },
            },
            'score': <String, dynamic>{
              'grantedPoints': 160,
              'maxPoints': 160,
            },
          };
        },
      );
      runner = CommandRunner<int>('test', 'test')..addCommand(cmd);

      final exitCode = await runner.run([
        'check-score',
        '--pubspec',
        pubspec.path,
      ]);

      expect(exitCode, equals(0));
    });
  });
}
