---
name: dart-pub-upgrade
description: Upgrade Dart/Flutter packages, resolve warnings/errors, extract CHANGELOGs, summarize with AI, and create a Draft PR.
---

# dart-pub-upgrade

このスキルは、Dart/Flutterパッケージのメジャーバージョンを含む一括アップグレードを行い、変更に伴うコードの警告・コンパイルエラーを自動/手動で解決し、変更点のCHANGELOGを pub.dev からインメモリ並行抽出してAIが要約した上で、Draft PR を自動起票するスキルです。

## フロー

1. `dart-pub-upgrade` の CLI スクリプトを実行して、パッケージのアップグレードと差分データの抽出を行います。
   - 実行コマンド: `dart run <path_to_skill>/scripts/bin/dart_pub_upgrade.dart --path <path_to_project>` (作業ディレクトリは Git リポジトリのルート。`<path_to_skill>` は本 `SKILL.md` が配置されている絶対パス、`<path_to_project>` はアップグレード対象の Dart プロジェクトが存在するサブディレクトリへの相対パスに置き換えて実行すること)
   - スクリプト実行により、`pubspec.lock` の差分からアップグレードされたパッケージが検出され、pub.dev の tarball からインメモリで `CHANGELOG.md` が抽出されます。
   - 抽出された差分CHANGELOGは、`<path_to_project>/.dart_tool/dart_pub_upgrade/changelog_diffs.json` にJSON形式で保存されます。
   - スクリプトが自動的にトピックブランチ（`chore/deps/upgrade-packages-YYYYMMDD`）を作成し、パッケージ更新内容をコミットします。
2. **アップグレードに伴うコード修正と検証**:
   - `<path_to_project>` ディレクトリ内で `fvm flutter pub get` などの必要な依存解決コマンドを実行します（Melosモノレポの場合は `melos bootstrap`）。
   - 機械的に修正可能な静的解析の警告や非推奨の警告を解消するため、`dart fix --apply` や `melos run fix` を実行します。
   - `dart analyze` や `melos run analyze` を実行して、アップグレードによるコンパイルエラーや静的解析の警告・エラーを検出します。
   - AIが確信を持って対応できる問題（例: パッケージ名やプロパティの微細な変更等）については、手動でコードを修正し、`git commit -m "fix(deps): パッケージ変更に伴う移行対応"` などの別コミットを作成して追加します。
   - AIが判断に迷うような設計上の変更や、要相談の破壊的変更については、無理に修正せずそのまま残し、チャットおよびPRの本文でユーザーに相談できるように控えておきます。
3. 保存された `<path_to_project>/.dart_tool/dart_pub_upgrade/changelog_diffs.json` の内容を読み込みます。
4. AIによる要約・分析を行います。
   - 変更があったパッケージごとに、**「破壊的変更」「APIの変更」「重要な機能追加」** などの重要度の高い変更を抽出・要約します。
   - すべてのパッケージについて、元のバージョンから新しいバージョンまでの変更ログ（pub.dev への個別リンク付き）を一覧化します。
5. **移行・対応内容のPR記載と起票**:
   - 行った修正内容（「dart fix による修正」「手動で修正した移行対応」など）を漏れなくプルリクエストの本文に記載します。
   - AIが修正できずに残した懸念点や、ユーザー側の手動確認が必要な箇所（要相談の内容）がある場合は、PRの本文に「⚠️ 手動対応・要確認が必要な点」として目立つように記載します。
   - トピックブランチを push し、`gh` コマンドを使用して、作成した要約・詳細・移行対応ログを body に記載した Draft PR を作成します。
     - 実行コマンド: `env -u GITHUB_TOKEN -u GH_TOKEN gh pr create --draft --title "chore(deps): パッケージの一括アップグレード (YYYY/MM/DD)" --body "<生成した要約、移行ログ、要相談リスト等>"`
6. `<path_to_project>/.dart_tool/dart_pub_upgrade` ディレクトリなどの一時生成物をクリーンアップします。
