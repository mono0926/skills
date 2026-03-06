---
name: release-pub
description: A specialized workflow for releasing Dart CLI packages to pub.dev. Use when the user asks to "release", "publish to pub.dev", or "create a release" for a Dart project.
---

# `release-pub` Skill

This skill is a specialized release workflow for Dart CLI packages published to pub.dev. It relies on a local helper script (`release_helper`) to safely manipulate `pubspec.yaml` and `CHANGELOG.md`.

## Workflow Overview

Follow these steps precisely:

### 1. Pre-release Checks

- Check if there are any uncommitted changes: `git status -s`. If there are, tell the user to commit or stash them before proceeding.
- Run `dart format .` and `dart analyze`. If there are errors, report them and ask the user to fix them.
- **CRITICAL**: Run `dart pub publish --dry-run`. If warnings or errors appear (other than expected ones that can be ignored), report them and ask for user confirmation to proceed.

### 2. Analyze Changes & Plan Release

- Find the last tag: `LAST_TAG=$(git tag --sort=-v:refname | head -1)`
- Analyze the commits since the last tag: `git log ${LAST_TAG}..HEAD --oneline`
- Determine the bump type (`major`, `minor`, `patch`) based on Conventional Commits:
  - `BREAKING CHANGE` or `!:` -> major (or minor if version is `< 1.0.0` but follow the user's lead on pre-1.0.0 breaking changes).
  - `feat:` -> minor
  - `fix:`, `docs:`, `chore:`, etc. -> patch
- Generate markdown for `CHANGELOG.md` notes describing the changes. Use Japanese for the notes (since the user likes Japanese communication, but keep the headers simple). _DO NOT include the `## [version] - [date]` title header in the notes as the script adds that automatically._

### 3. Execution using Helper Script

Use the bundled Dart CLI script to apply changes safely. The script is located at `.agents/skills/release-pub/scripts/release_helper`.

1. **Bump Version**:

   ```bash
   dart run .agents/skills/release-pub/scripts/release_helper/bin/release_helper.dart bump <type>
   ```

   (Replace `<type>` with `major`, `minor`, or `patch`).

2. **Extract New Version**:
   Read the `pubspec.yaml` to find the newly bumped version string (e.g. `1.2.3`). Let's call this `$NEW_VERSION`.

3. **Update Changelog**:

   ```bash
   dart run .agents/skills/release-pub/scripts/release_helper/bin/release_helper.dart changelog $NEW_VERSION --notes "
   ### Features
   - ...

   ### Bug Fixes
   - ...
   "
   ```

### 4. User Confirmation

Show the user the Git diff (`git diff`) and ask: "コミットしてリリース (v$NEW_VERSION) に進みますか？"
Wait for explicit confirmation.

### 5. Git & GitHub Operations

Once the user confirms:

1. Stage the files:
   ```bash
   git add pubspec.yaml CHANGELOG.md
   ```
2. Commit:
   ```bash
   git commit -m "chore: release v$NEW_VERSION"
   ```
3. Tag:
   ```bash
   git tag v$NEW_VERSION
   ```
4. Push:
   ```bash
   git push origin main
   git push origin v$NEW_VERSION
   ```
5. Create GitHub Release:
   Save the notes to a temporary file, e.g., `/tmp/release_notes.md`, then:
   ```bash
   gh release create v$NEW_VERSION --title "v$NEW_VERSION" --notes-file /tmp/release_notes.md
   rm /tmp/release_notes.md
   ```

Finally, report that the release is complete and that GitHub Actions will automatically handle pushing to `pub.dev`.
