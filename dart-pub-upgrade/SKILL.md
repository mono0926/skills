---
name: dart-pub-upgrade
description: Upgrade Dart/Flutter packages, extract CHANGELOGs, summarize with AI, and create a Draft PR.
---

# dart-pub-upgrade

このスキルは、Dart/Flutterパッケージのメジャーバージョンを含む一括アップグレードを行い、変更点のCHANGELOGを pub.dev からインメモリ並行抽出してAIが重要度の高い変更を要約した上で、Draft PR を自動起票するスキルです。

## フロー

1. `dart-pub-upgrade` の CLI スクリプトを実行して、パッケージのアップグレードと差分データの抽出を行います。
   - 実行コマンド: `dart run <path_to_skill>/scripts/bin/dart_pub_upgrade.dart` (作業ディレクトリはプロジェクトルート。`<path_to_skill>` は本 `SKILL.md` が配置されている絶対パスに置き換えて実行すること)
   - スクリプト実行により、`pubspec.lock` の差分からアップグレードされたパッケージが検出され、pub.dev の tarball からインメモリで `CHANGELOG.md` が抽出されます。
   - 抽出された差分CHANGELOGは、`.dart_pub_upgrade_temp/changelog_diffs.json` にJSON形式で保存されます。
2. 保存された `changelog_diffs.json` の内容を読み込みます。
3. AIによる要約・分析を行います。
   - 変更があったパッケージごとに、**「破壊的変更」「APIの変更」「重要な機能追加」** などの重要度の高い変更を抽出・要約します。
   - すべてのパッケージについて、元のバージョンから新しいバージョンまでの変更ログ（pub.dev への個別リンク付き）を一覧化します。
4. トピックブランチ（スクリプト側で作成・コミット済み）にて、`gh` コマンドを使用して、作成した要約・詳細を body に記載した Draft PR を作成します。
   - 実行コマンド: `env -u GITHUB_TOKEN -u GH_TOKEN gh pr create --draft --title "chore(deps): パッケージの一括アップグレード (YYYY/MM/DD)" --body "<生成した要約と詳細内容>"`
5. `.dart_pub_upgrade_temp` ディレクトリなどの一時生成物をクリーンアップします。
