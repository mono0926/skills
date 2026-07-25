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
4. AIによる要約・分析およびPR本文の生成を行います。
   - **【重要：手抜き・省略の絶対禁止】**
     アップグレードされたパッケージの件数がどれほど多くても（例：50件以上の場合など）、**「※ 詳細は pubspec.lock の差分をご参照ください」や「以下省略」といった記述でリストや詳細の出力をサボる行為は厳禁**とします。必ずアップグレードされたすべてのパッケージを漏れなくPR本文に記録してください。
   - **直接依存と間接依存の分類**:
     出力トークン数を効率化しつつ全網羅するため、パッケージを以下のように分類してPR本文を作成してください。
      - **直接依存 (Direct dependencies)**: `pubspec.yaml` に直接記述されているパッケージ。これらについては、元のバージョンから新しいバージョンまでの CHANGELOG の変更内容（特に「破壊的変更」「APIの変更」「重要な機能追加」）を個別に分析・要約し、各パッケージの CHANGELOG リンクを付与して詳細に記載してください。
      - **間接依存 (Transitive dependencies)**: 間接的に引き込まれたパッケージ。これらについては詳細な CHANGELOG 要約は省略して構いませんが、**「パッケージ名 (旧バージョン ➔ 新バージョン) と CHANGELOG リンク」のリスト自体は、絶対に省略せず100%すべて書き出してください**。
   - **【リンクのフォーマット：必須ルール】**
     各パッケージの CHANGELOG リンクは、必ず以下の固定URLパターンで組み立ててください。パッケージ名がわかれば、外部APIへの問い合わせや検索なしに確実に生成できます。
     ```
     https://pub.dev/packages/<package_name>/changelog
     ```
     例：`flutter_riverpod` なら `https://pub.dev/packages/flutter_riverpod/changelog`
     **リンクが「わからない」「取得できない」という理由でリンクを省略することは一切認めません。** このURLパターンは常に有効です。

5. **PR本文の生成と起票**:
   - 生成する Draft PR の本文は、出力を高品質かつ一貫させるため、以下の**標準テンプレート**に従って組み立ててください。

   ### 📄 PR本文の標準テンプレート

   ```markdown
   ## 概要
   <アップグレードの全体の概要や目的の簡潔な説明>

   ## 🚨 特に注目すべき重要な変更点
   <!-- 破壊的変更、メジャーアップデート、非推奨の警告だけでなく、利便性が向上する重要な機能追加（New Features）や主要な仕様変更なども含めてハイライトします。特に該当がない場合は「特になし」と記述してください。 -->
   - **[<package_name>](https://pub.dev/packages/<package_name>/changelog)**: <注目すべき破壊的変更・新機能・主要変更の要約>

   ## 🛠️ 移行・対応内容
   - <dart fix による自動修正内容、手動で行ったコード修正ログ等>

   ## ⚠️ 手動対応・要確認が必要な点
   <!-- AIで確信を持って修正できず残した懸念点や、ユーザー側での手動確認・動作テストが必要な事項。なければ「なし」と記述してください。 -->
   - <要確認項目>

   ## 📦 アップグレードされたパッケージ詳細

   ### 直接依存 (Direct dependencies)

   * **[<package_name>](https://pub.dev/packages/<package_name>/changelog)** (<old_version> ➔ <new_version>)
     - <CHANGELOG要約・変更点1>
     - <CHANGELOG要約・変更点2>

   ### 間接依存 (Transitive dependencies)

   - [<package_name>](https://pub.dev/packages/<package_name>/changelog) (<old_version> ➔ <new_version>)
   - ...
   ```

   - トピックブランチを push し、`gh` コマンドを使用して、上記テンプレートで生成した内容を body に指定した Draft PR を作成します。
     - 実行コマンド: `env -u GITHUB_TOKEN -u GH_TOKEN gh pr create --draft --title "chore(deps): パッケージの一括アップグレード (YYYY/MM/DD)" --body "<生成したテンプレート本文>"`
6. `<path_to_project>/.dart_tool/dart_pub_upgrade` ディレクトリなどの一時生成物をクリーンアップします。

