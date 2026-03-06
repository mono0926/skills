import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:release_helper/src/logger.dart';
import 'package:yaml_edit/yaml_edit.dart';

class BumpCommand extends Command<int> {
  BumpCommand() {
    argParser
      ..addOption(
        'file',
        abbr: 'f',
        help: 'The path to pubspec.yaml',
        defaultsTo: 'pubspec.yaml',
      )
      ..addFlag(
        'dry-run',
        abbr: 'n',
        help: 'Show what would be changed without writing to the file.',
        negatable: false,
      );
  }

  @override
  String get description => 'Bumps the version in pubspec.yaml';

  @override
  String get name => 'bump';

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
    final filePath = argResults?['file'] as String;
    final file = File(filePath);

    if (!file.existsSync()) {
      logger.err('pubspec.yaml not found at $filePath');
      return 1;
    }

    final content = file.readAsStringSync();
    final editor = YamlEditor(content);

    final currentVersionNode = editor.parseAt(['version']);
    final currentVersion = Version.parse(currentVersionNode.value as String);

    Version nextVersion;
    if (bumpTypeOrVersion == 'major') {
      nextVersion = currentVersion.nextMajor;
    } else if (bumpTypeOrVersion == 'minor') {
      nextVersion = currentVersion.nextMinor;
    } else if (bumpTypeOrVersion == 'patch') {
      nextVersion = currentVersion.nextPatch;
    } else {
      nextVersion = Version.parse(bumpTypeOrVersion);
    }

    final isDryRun = argResults?['dry-run'] as bool;
    if (isDryRun) {
      logger.info(
        'Dry run: bumped version from $currentVersion to $nextVersion',
      );
    } else {
      editor.update(['version'], nextVersion.toString());
      file.writeAsStringSync(editor.toString());
      logger.success('Bumped version from $currentVersion to $nextVersion');
    }
    return 0;
  }
}
