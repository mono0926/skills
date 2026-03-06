---
name: release-pub
description: A specialized workflow for releasing Dart and Flutter packages to pub.dev. Use when the user asks to "release", "publish to pub.dev", or "create a release" for a Dart/Flutter project.
---

# `release-pub` Skill

This skill is a specialized release workflow for Dart and Flutter packages published to pub.dev (including Dart CLI tools). It relies on a local helper script (`release_helper`) to safely manipulate `pubspec.yaml` and `CHANGELOG.md`.

## Workflow Overview

Follow these steps precisely:

### 0. Initial Setup Verification (One-time only)

If this is the first time the package is being published via GitHub Actions, ensure the user has configured OIDC on pub.dev:

1. Advise the user to access `https://pub.dev/packages/<package_name>/admin`.
2. Find the **Automated publishing** section and click **Enable publishing from GitHub Actions**.
3. Recommend setting the **Repository** to the current repository (`owner/repo`) and the **Tag pattern** to `v{{version}}`.

Wait for the user to confirm this is done if it's a new setup.

### 1. Pre-release Checks

- Check if there are any uncommitted changes: `git status -s`. If there are, tell the user to commit or stash them before proceeding.
- **README / Docs Update Check**: Scan the recent changes. If there are new features or changed options, remind the user to check if `README.md` or other documentation needs updating before releasing.
- Run the appropriate formatter and analyzer based on the project type:
  - For Dart packages: `dart format .` and `dart analyze`
  - For Flutter packages: `flutter format .` (or `dart format .`) and `flutter analyze`
    If there are errors, report them and ask the user to fix them.
- **CRITICAL**: Run the pre-publish dry-run:
  - For Dart packages: `dart pub publish --dry-run`
  - For Flutter packages: `flutter pub publish --dry-run`
    If warnings or errors appear (other than expected ones that can be ignored), report them and ask for user confirmation to proceed.

### 2. Analyze Changes & Plan Release

- Find the last tag: `LAST_TAG=$(git tag --sort=-v:refname | head -1)`
- Analyze the commits since the last tag: `git log ${LAST_TAG}..HEAD --oneline`
- Determine the bump type (`major`, `minor`, `patch`) based on Conventional Commits:
  - `BREAKING CHANGE:` or `<type>!:` -> major (or minor if version is `< 1.0.0` but follow the user's lead on pre-1.0.0 breaking changes).
  - `feat:` -> minor
  - `fix:`, `docs:`, `chore:`, `refactor:`, `perf:` etc. -> patch
- Generate markdown for `CHANGELOG.md` notes describing the changes. Generate the notes entirely in **English**. _DO NOT include the `## [version] - [date]` title header in the notes as the script adds that automatically._
- **Generate Preview (Dry-Run)**: Present a clear preview of the upcoming release to the user before making any file changes.
  - Show the version bump recommendation (e.g., `1.2.3 -> 1.3.0 (Recommended: feat=minor)`) and offer other valid SemVer alternatives (e.g. `1.2.4`, `2.0.0`) in case they want a different bump.
  - List the categorized commits that will be included in the release.
  - Show the preview text of the upcoming `CHANGELOG.md` entry.

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

Ask the user to confirm the prepared release based on the generated preview in Step 2:

- First present the version change options (e.g., "1.3.0 (Recommended)", "1.2.4", "2.0.0").
- Once the user chooses the version, proceed to update the files locally via Step 3.
- After running the execution helpers, show the user the Git diff (`git diff`) and ask: "Ready to create release commit and tag (v$NEW_VERSION)?"
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
   _Note: Do NOT add a `Co-Authored-By` line. This is a release commit, not a code contribution._
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
