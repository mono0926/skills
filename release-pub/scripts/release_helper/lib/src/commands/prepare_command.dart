import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:release_helper/src/logger.dart';
import 'package:yaml_edit/yaml_edit.dart';

class PrepareCommand extends Command<int> {
  PrepareCommand() {
    argParser
      ..addOption(
        'pubspec',
        help: 'The path to pubspec.yaml',
        defaultsTo: 'pubspec.yaml',
      )
      ..addOption(
        'changelog',
        help: 'The path to CHANGELOG.md',
        defaultsTo: 'CHANGELOG.md',
      )
      ..addOption(
        'notes',
        abbr: 'n',
        help: 'The markdown notes to add to CHANGELOG.md',
        mandatory: true,
      )
      ..addFlag(
        'dry-run',
        help: 'Show what would be changed without writing to files.',
        negatable: false,
      );
  }

  @override
  String get description =>
      'Bumps version and updates CHANGELOG.md in one command.';

  @override
  String get name => 'prepare';

  @override
  Future<int> run() async {
    final args = argResults?.rest ?? [];
    if (args.isEmpty) {
      logger.err(
        'Please specify a bump type (major | minor | patch) '
        'or an exact version.',
      );
      return 1;
    }

    final bumpTypeOrVersion = args.first;
    final pubspecPath = argResults?['pubspec'] as String;
    final changelogPath = argResults?['changelog'] as String;
    final notes = argResults?['notes'] as String;
    final isDryRun = argResults?['dry-run'] as bool;

    final pubspecFile = File(pubspecPath);
    if (!pubspecFile.existsSync()) {
      logger.err('pubspec.yaml not found at $pubspecPath');
      return 1;
    }

    // 1. Calculate next version
    final pubspecContent = pubspecFile.readAsStringSync();
    final editor = YamlEditor(pubspecContent);
    final currentVersionNode = editor.parseAt(['version']);
    final currentVersion = Version.parse(currentVersionNode.value as String);

    Version nextVersion;
    try {
      if (bumpTypeOrVersion == 'major') {
        nextVersion = currentVersion.nextMajor;
      } else if (bumpTypeOrVersion == 'minor') {
        nextVersion = currentVersion.nextMinor;
      } else if (bumpTypeOrVersion == 'patch') {
        nextVersion = currentVersion.nextPatch;
      } else {
        nextVersion = Version.parse(bumpTypeOrVersion);
      }
    } on FormatException catch (e) {
      logger.err('Invalid version or bump type: $bumpTypeOrVersion ($e)');
      return 1;
    }

    // 2. Prepare Changelog content
    final changelogFile = File(changelogPath);
    var originalChangelog = '';
    if (changelogFile.existsSync()) {
      originalChangelog = changelogFile.readAsStringSync();
    }

    final today = DateTime.now();
    final dateStr =
        '${today.year}-${today.month.toString().padLeft(2, '0')}-'
        '${today.day.toString().padLeft(2, '0')}';

    final header = '## $nextVersion - $dateStr\n\n';
    final formattedNotes = notes.trim().isEmpty ? '' : '${notes.trim()}\n\n';
    final newChangelogContent = header + formattedNotes + originalChangelog;

    // 3. Execution
    if (isDryRun) {
      logger
        ..info('--- Dry Run ---')
        ..info('Pubspec: $currentVersion -> $nextVersion')
        ..info('Changelog: Adding entry for $nextVersion')
        ..info('Notes:\n$formattedNotes');
    } else {
      // Update pubspec
      editor.update(['version'], nextVersion.toString());
      pubspecFile.writeAsStringSync(editor.toString());

      // Update changelog
      changelogFile.writeAsStringSync(newChangelogContent);

      logger
        ..success('Successfully prepared release $nextVersion')
        ..info('- Updated $pubspecPath')
        ..info('- Updated $changelogPath');
    }

    return 0;
  }
}
