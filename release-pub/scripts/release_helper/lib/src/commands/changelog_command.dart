import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:release_helper/src/logger.dart';

class ChangelogCommand extends Command<int> {
  ChangelogCommand() {
    argParser
      ..addOption(
        'file',
        abbr: 'f',
        help: 'The path to CHANGELOG.md',
        defaultsTo: 'CHANGELOG.md',
      )
      ..addOption(
        'notes',
        abbr: 'n',
        help: 'The markdown notes to add, without the title header',
        mandatory: true,
      )
      ..addFlag(
        'force',
        abbr: 'F',
        help: 'Force update even if the version header already exists.',
        negatable: false,
      );
  }

  @override
  String get description => 'Prepends release notes to the CHANGELOG.md file';

  @override
  String get name => 'changelog';

  @override
  Future<int> run() async {
    final args = argResults?.rest ?? [];
    if (args.isEmpty) {
      logger.err('Please specify the new version string (e.g. 1.2.3).');
      return 1;
    }

    final version = args.first;
    final notes = argResults?['notes'] as String;
    final filePath = argResults?['file'] as String;

    final file = File(filePath);
    var originalContent = '';

    if (file.existsSync()) {
      originalContent = file.readAsStringSync();
    } else {
      logger.warn('CHANGELOG.md not found, creating a new one.');
    }

    final today = DateTime.now();
    final dateStr =
        '${today.year}-${today.month.toString().padLeft(2, '0')}-'
        '${today.day.toString().padLeft(2, '0')}';

    final header = '## $version - $dateStr\n\n';

    final isForce = argResults?['force'] as bool;

    if (originalContent.contains('## $version -') && !isForce) {
      logger.warn('Version $version already exists in $filePath. Skipping.');
      return 0;
    }

    // Some basic formatting to ensure spacing
    final formattedNotes = notes.trim().isEmpty ? '' : '${notes.trim()}\n\n';

    final newContent = header + formattedNotes + originalContent;
    file.writeAsStringSync(newContent);

    logger.success('Prepended release notes for v$version to $filePath');
    return 0;
  }
}
