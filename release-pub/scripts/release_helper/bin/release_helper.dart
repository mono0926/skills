#!/usr/bin/env dart

import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:release_helper/src/commands/bump_command.dart';
import 'package:release_helper/src/commands/changelog_command.dart';
import 'package:release_helper/src/commands/prepare_command.dart';
import 'package:release_helper/src/logger.dart';

Future<void> main(List<String> arguments) async {
  final runner =
      CommandRunner<int>(
          'release_helper',
          'A helper CLI tool for release-pub AI skill.',
        )
        ..addCommand(BumpCommand())
        ..addCommand(ChangelogCommand())
        ..addCommand(PrepareCommand());

  try {
    final exitCode = await runner.run(arguments);
    await flushThenExit(exitCode ?? 0);
  } on FormatException catch (e) {
    logger
      ..err(e.message)
      ..info('')
      ..info(runner.usage);
    await flushThenExit(64);
  } on UsageException catch (e) {
    logger
      ..err(e.message)
      ..info('')
      ..info(runner.usage);
    await flushThenExit(64);
  } on Exception catch (e, stackTrace) {
    logger
      ..err('An unexpected error occurred: $e')
      ..err('$stackTrace');
    await flushThenExit(1);
  }
}

Future<void> flushThenExit(int status) async {
  exitCode = status;
  await Future.wait<void>([stdout.close(), stderr.close()]);
}
