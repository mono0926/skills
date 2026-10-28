---
name: dart-pub-upgrade
description: Upgrade Dart/Flutter packages, resolve warnings/errors, extract CHANGELOGs, summarize with AI, and create a Pull Request.
---

# dart-pub-upgrade

このスキルは、Dart/Flutterパッケージのメジャーバージョンを含む一括アップグレードを行い、コードの自動修復・静的解析による検証を行い、変更点のCHANGELOGを pub.dev から抽出してAIが要約した上で、プルリクエスト（PR）を自動起票するスキルです。


## フロー

1. **既存のピン留め・理由コメントの確認と妥当性調査**:
   - アップグレード対象プロジェクト内の全 `pubspec.yaml`（および `.github/dependabot.yml` 等）を確認し、バージョンがピン留めされているパッケージとその直上の理由コメント（または Issue URL）を把握します。
   - **理由コメントの妥当性・解除可否の検証**:
     - 記載されているピン留め理由やリンク先 Issue の内容（例：「他パッケージの対応待ち」「ネイティブ SDK / SPM の依存競合回避」「特定バージョンの不具合回避」等）が**現時点でも妥当か、すでに解消されておりピン留めを解除して良いか**を、`pub.dev` の最新リリース状況・CHANGELOG・依存解決結果などから調査します。
     - **解除可能な場合**: ピン留め（および不要になった理由コメントや `.github/dependabot.yml` の `ignore` 設定）を解除して最新バージョンへアップグレードし、関連 Issue があれば PR に `Closes #<Issue番号>` を紐づけます。
     - **まだ解除できない（理由が継続している）場合**: 後続のスクリプト実行（`--major-versions`）で制約が書き換えられた場合は元のピン留め制約に復元した上で `pub upgrade` を再実行し、ピン留めを継続します。
     - **意味なくピン留めされているパッケージの整理**: 理由コメントがなく、特段の制約理由もないまま古いバージョンや不要な制約でピン留めされているパッケージがないか確認し、プロジェクトの方針に合わせて適切に解除・更新します。

2. **`dart-pub-upgrade` CLI スクリプトの実行**:
   - 実行コマンド: `(cd <path_to_skill>/scripts && dart pub get && dart run bin/dart_pub_upgrade.dart --path "$PWD/<path_to_project>")`
     - `<path_to_skill>`: 本 `SKILL.md` が配置されているディレクトリへの相対/絶対パス（例: `.skills/dart-pub-upgrade`）
     - `<path_to_project>`: アップグレード対象の Dart プロジェクトが存在するディレクトリへの相対パス（ルート直下なら `.`、サブディレクトリなら `monoca_flutter` 等のパス）
   - **スクリプトの全自動動作**:
     - `pubspec.lock` の差分からアップグレードされたパッケージを特定。
     - 対象プロジェクト内の全 `pubspec.yaml` を解析し、各パッケージが**直接依存 (`isDirect: true`)** か**間接依存 (`isDirect: false`)** かを自動判定。
     - pub.dev の tarball からインメモリで `CHANGELOG.md` を抽出し、`<path_to_project>/.dart_tool/dart_pub_upgrade/changelog_diffs.json` に保存。
     - 自動的にトピックブランチ（`chore/deps/upgrade-packages-YYYYMMDD`）を作成・コミット。
     - デフォルトで `dart fix --apply`（または `melos` 連携修復）を自動実行し、修正があれば追記コミットを作成。
     - `dart analyze` / `melos run analyze` による静的解析を実行。

3. **静的解析結果の確認・追加修正・新規ピン留め時のルール**:
   - スクリプト実行ログの静的解析結果を確認します。
   - 自動修復で解消しなかったコンパイルエラーや警告が残っている場合、AIが手動でコードを修正し、`git commit -m "fix(deps): パッケージ変更に伴う手動移行対応"` の別コミットを作成して追加します。
   - **【重要：バージョンをピン留めする際の必須ルール】**
     - 破壊的変更や他パッケージとの依存競合などにより、特定パッケージのアップグレードを見送ってバージョンをピン留め（固定）する場合は、以下の手順を必ず実施してください：
       1. `pubspec.yaml` の該当パッケージの直上に、**必ずピン留めの理由コメントを記載**する。
       2. 将来そのピン留めを解除するための**追跡用 Issue の起票をユーザーへ提案**する（または指示に応じて起票する）。
       3. **Issue を起票した場合は、`pubspec.yaml` の理由コメントをその Issue の URL（例: `# <理由の概要> (https://github.com/<owner>/<repo>/issues/<number>)`）に差し替える**（`.github/dependabot.yml` がある場合は `ignore` 設定もあわせて更新する）。
   - 設計上の大きな変更や判断に迷う破壊的変更については、無理に修正せず PR 本文の「手動対応・要確認が必要な点」に記録します。

4. **CHANGELOG 差分データの読み込み**:
   - `<path_to_project>/.dart_tool/dart_pub_upgrade/changelog_diffs.json` の内容を読み込みます（ピン留め復元等により実際にアップグレードされたパッケージ集合が変化した場合は、`git diff main -- pubspec.lock` と照合して実際に更新されたパッケージのみを対象とします）。

5. **AIによる要約・分析およびPR本文の生成**:
   - **【重要：手抜き・省略の絶対禁止】**
     件数が多くても「※ 詳細は pubspec.lock の差分をご参照ください」や「以下省略」といった記述で省略することは厳禁です。必ずすべてのアップグレード対象パッケージを漏れなくPR本文に記録してください。
   - **直接依存と間接依存の分類**:
     JSON データ内の `"isDirect"` フラグ（`true` または `false`）に基づいて正確に分類してください。
     - **直接依存 (`isDirect: true`)**: CHANGELOG の変更内容（特に「破壊的変更」「APIの変更」「重要な機能追加」）を個別に分析・要約し、各パッケージの CHANGELOG リンクを付与して詳細に記載します。
     - **間接依存 (`isDirect: false`)**: 詳細な CHANGELOG 要約は省略して構いませんが、「パッケージ名 (旧バージョン ➔ 新バージョン) と CHANGELOG リンク」のリスト自体は100%すべて書き出してください（ただしセキュリティ修正等の重大な変更が含まれる場合は「🚨 特に注目すべき重要な変更点」でハイライトしてください）。
   - **【リンクのフォーマット：必須ルール】**
     各パッケージの CHANGELOG リンクは、必ず以下の固定URLパターンで組み立ててください。
     ```
     https://pub.dev/packages/<package_name>/changelog
     ```
     例：`flutter_riverpod` ➔ `https://pub.dev/packages/flutter_riverpod/changelog`

6. **PR の起票**:
   - 生成する PR の本文は、以下の**標準テンプレート**に従って組み立ててください。

   ### 📄 PR本文の標準テンプレート

   ```markdown
   ## 概要

   <アップグレードの全体の概要や目的の簡潔な説明>

   ## 🚨 特に注目すべき重要な変更点

   <!-- 破壊的変更、メジャーアップデート、セキュリティ修正、利便性が向上する重要な機能追加や主要な仕様変更などをハイライトします。特になければ「特になし」と記述 -->

   - **[<package_name>](https://pub.dev/packages/<package_name>/changelog)**: <注目すべき破壊的変更・新機能・主要変更の要約>

   ## 🛠️ 移行・対応内容

   - <dart fix による自動修正内容、手動で行ったコード修正ログ、既存ピン留めの解除可否検証結果や継続・解除の対応内容等>

   ## ⚠️ 手動対応・要確認が必要な点

   <!-- AIで確信を持って修正できず残した懸念点や、ユーザー側での手動確認・動作テストが必要な事項、新規ピン留めに対する解除用Issue起票提案など。なければ「なし」と記述 -->

   - <要確認項目>

   ## 📦 アップグレードされたパッケージ詳細

   ### 直接依存 (Direct dependencies)

   - **[<package_name>](https://pub.dev/packages/<package_name>/changelog)** (<old_version> ➔ <new_version>)
     - <CHANGELOG要約・変更点1>
     - <CHANGELOG要約・変更点2>

   ### 間接依存 (Transitive dependencies)

   - [<package_name>](https://pub.dev/packages/<package_name>/changelog) (<old_version> ➔ <new_version>)
   - ...
   ```

   - トピックブランチを remote に push し、`gh` コマンドで PR を起票します。
     - **「手動対応・要確認が必要な点」に項目・注意事項がある場合**: `--draft` オプションを付与して Draft PR として起票します。
       - 実行コマンド: `env -u GITHUB_TOKEN -u GH_TOKEN gh pr create --draft --title "chore(deps): パッケージの一括アップグレード (YYYY/MM/DD)" --body "<生成したテンプレート本文>"`
     - **「手動対応・要確認が必要な点」が「なし」の場合**: `--draft` オプションを外して Ready for review（通常のPR）として起票します。
       - 実行コマンド: `env -u GITHUB_TOKEN -u GH_TOKEN gh pr create --title "chore(deps): パッケージの一括アップグレード (YYYY/MM/DD)" --body "<生成したテンプレート本文>"`

7. **クリーンアップ**:
   - `<path_to_project>/.dart_tool/dart_pub_upgrade` ディレクトリなどの一時生成物を削除します。

8. **最終出力フォーマット**:
   - 処理の最後（応答の最終行）に、作成されたプルリクエストの URL を以下の固定フォーマットで必ず出力してください。
     `PULL_REQUEST_URL: <作成されたPRのURL>`
   - パッケージの更新がなかった場合や PR が起票されなかった場合は、以下のように出力してください。
     `PULL_REQUEST_URL: none`
