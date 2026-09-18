import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:release_helper/src/logger.dart';
import 'package:yaml_edit/yaml_edit.dart';

typedef JsonFetcher = Future<Map<String, dynamic>?> Function(Uri uri);

class CheckScoreCommand extends Command<int> {
  CheckScoreCommand({JsonFetcher? fetcher, Duration? pollIntervalOverride})
    : _fetcher = fetcher ?? _defaultFetcher,
      _pollIntervalOverride = pollIntervalOverride {
    argParser
      ..addOption(
        'package',
        abbr: 'p',
        help: 'The name of the package. If omitted, read from pubspec.yaml.',
      )
      ..addOption(
        'version',
        abbr: 'v',
        help:
            'The target version to wait for. '
            'If omitted, read from command arguments or pubspec.yaml.',
      )
      ..addOption(
        'pubspec',
        help: 'The path to pubspec.yaml',
        defaultsTo: 'pubspec.yaml',
      )
      ..addOption(
        'timeout',
        help: 'Timeout in seconds to wait for pub.dev analysis.',
        defaultsTo: '300',
      )
      ..addOption(
        'poll-interval',
        help: 'Polling interval in seconds.',
        defaultsTo: '10',
      )
      ..addOption(
        'min-score',
        help: 'The minimum acceptable score. Defaults to max possible points.',
      );
  }

  final JsonFetcher _fetcher;
  final Duration? _pollIntervalOverride;

  @override
  String get description =>
      'Checks pub.dev pana score and waits for analysis of a newly released '
      'version.';

  @override
  String get name => 'check-score';

  @override
  Future<int> run() async {
    final pubspecPath = argResults?['pubspec'] as String? ?? 'pubspec.yaml';
    final pubspecFile = File(pubspecPath);

    var packageName = argResults?['package'] as String?;
    var targetVersion = argResults?['version'] as String?;

    final restArgs = argResults?.rest ?? [];
    if (restArgs.isNotEmpty && targetVersion == null) {
      targetVersion = restArgs.first;
    }

    if (pubspecFile.existsSync()) {
      try {
        final content = pubspecFile.readAsStringSync();
        final editor = YamlEditor(content);
        if (packageName == null) {
          final nameNode = editor.parseAt(['name']);
          packageName = nameNode.value as String?;
        }
        if (targetVersion == null) {
          final versionNode = editor.parseAt(['version']);
          targetVersion = versionNode.value as String?;
        }
      } on Exception catch (e) {
        logger.detail('Failed to parse pubspec.yaml: $e');
      }
    }

    if (packageName == null || packageName.isEmpty) {
      logger.err(
        'Package name not specified and could not be determined '
        'from pubspec.yaml.',
      );
      return 1;
    }

    final timeoutSec =
        int.tryParse(argResults?['timeout'] as String? ?? '300') ?? 300;
    final pollIntervalSec =
        int.tryParse(argResults?['poll-interval'] as String? ?? '10') ?? 10;
    final pollInterval =
        _pollIntervalOverride ?? Duration(seconds: pollIntervalSec);

    final minScoreOpt = argResults?['min-score'] as String?;
    final minScore = minScoreOpt != null ? int.tryParse(minScoreOpt) : null;

    logger.info(
      'Checking pub.dev score for package: $packageName'
      '${targetVersion != null ? " (target version: $targetVersion)" : ""}',
    );

    final metricsUri = Uri.parse(
      'https://pub.dev/api/packages/$packageName/metrics',
    );

    final stopwatch = Stopwatch()..start();
    Map<String, dynamic>? metricsJson;

    while (true) {
      try {
        metricsJson = await _fetcher(metricsUri);
      } on Exception catch (e) {
        logger.detail('Error fetching metrics: $e');
      }

      if (metricsJson != null) {
        final scorecard = metricsJson['scorecard'] as Map<String, dynamic>?;
        final analyzedVersion = scorecard?['packageVersion'] as String?;
        final panaReport = scorecard?['panaReport'] as Map<String, dynamic>?;
        final result = panaReport?['result'] as Map<String, dynamic>?;
        final score = metricsJson['score'] as Map<String, dynamic>?;

        final isTargetVersion =
            targetVersion == null || analyzedVersion == targetVersion;
        final hasScore =
            (score?['maxPoints'] as int? ?? 0) > 0 ||
            (result?['maxPoints'] as int? ?? 0) > 0;

        if (isTargetVersion && hasScore) {
          logger.info(
            'Analysis retrieved for version: ${analyzedVersion ?? "unknown"}',
          );
          break;
        }

        logger.info(
          'Waiting for pub.dev to analyze v$targetVersion '
          '(currently analyzed: ${analyzedVersion ?? "none"}, '
          'elapsed: ${stopwatch.elapsed.inSeconds}s)...',
        );
      } else {
        logger.info(
          'Waiting for pub.dev metrics to be available '
          '(elapsed: ${stopwatch.elapsed.inSeconds}s)...',
        );
      }

      if (stopwatch.elapsed.inSeconds >= timeoutSec) {
        logger.err(
          'Timed out after ${timeoutSec}s waiting for pub.dev analysis of '
          '$packageName${targetVersion != null ? " v$targetVersion" : ""}.',
        );
        return 1;
      }

      await Future<void>.delayed(pollInterval);
    }

    // Process and display score results
    final score = metricsJson['score'] as Map<String, dynamic>?;
    final scorecard = metricsJson['scorecard'] as Map<String, dynamic>?;
    final panaReport = scorecard?['panaReport'] as Map<String, dynamic>?;
    final report = panaReport?['report'] as Map<String, dynamic>?;
    final result = panaReport?['result'] as Map<String, dynamic>?;
    final sections =
        (report?['sections'] as List<dynamic>?)?.cast<Map<String, dynamic>>() ??
        [];

    final scoreGranted = score?['grantedPoints'] as int? ?? 0;
    final scoreMax = score?['maxPoints'] as int? ?? 0;

    final resultGranted = result?['grantedPoints'] as int? ?? 0;
    final resultMax = result?['maxPoints'] as int? ?? 0;

    final grantedPoints = scoreMax > 0 ? scoreGranted : resultGranted;
    final maxPoints = scoreMax > 0 ? scoreMax : resultMax;

    final tags = (score?['tags'] as List<dynamic>?)?.cast<String>() ?? [];

    final wasmReady =
        tags.contains('is:wasm-ready') ||
        sections.any(
          (s) =>
              (s['summary'] as String? ?? '').contains('**WASM-ready:**') ||
              (s['summary'] as String? ?? '').contains(
                'compatible with runtime `wasm`',
              ),
        );

    final platforms =
        tags
            .where((t) => t.startsWith('platform:'))
            .map((t) => t.replaceFirst('platform:', ''))
            .toList();

    logger
      ..info('')
      ..info('=== pub.dev Scorecard ===')
      ..info('Package:      $packageName')
      ..info('Score:        $grantedPoints / $maxPoints')
      ..info('WASM ready:   ${wasmReady ? "✅ YES" : "❌ NO"}');

    if (platforms.isNotEmpty) {
      logger.info('Platforms:    ${platforms.join(", ")}');
    }
    logger.info('Score URL:    https://pub.dev/packages/$packageName/score');

    final deductedSections = sections.where((s) {
      final sGranted = s['grantedPoints'] as int? ?? 0;
      final sMax = s['maxPoints'] as int? ?? 0;
      return sGranted < sMax;
    }).toList();

    if (deductedSections.isNotEmpty) {
      logger
        ..info('')
        ..err('⚠️  Deductions found:');
      for (final s in deductedSections) {
        final title = s['title'] ?? 'Unknown section';
        final sGranted = s['grantedPoints'] ?? 0;
        final sMax = s['maxPoints'] ?? 0;
        logger.err('  • [$sGranted/$sMax] $title');

        final summary = (s['summary'] as String?)?.trim();
        if (summary != null && summary.isNotEmpty) {
          for (final line in summary.split('\n')) {
            if (line.trim().isNotEmpty) {
              logger.info('      $line');
            }
          }
        }
      }
    }

    final requiredScore = minScore ?? maxPoints;
    if (grantedPoints < requiredScore) {
      logger
        ..info('')
        ..err(
          '❌ Score check failed: $grantedPoints points granted, '
          'but $requiredScore required.',
        );
      return 1;
    }

    logger
      ..info('')
      ..success(
        '🎉 Perfect score or passed criteria: $grantedPoints / $maxPoints!',
      );
    return 0;
  }

  static Future<Map<String, dynamic>?> _defaultFetcher(Uri uri) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(uri);
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        return null;
      }
      final body = await response.transform(utf8.decoder).join();
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      return null;
    } finally {
      client.close();
    }
  }
}
