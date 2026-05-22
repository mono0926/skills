---
name: github-actions-oidc
description: GitHub Actionsから各クラウド（Google Cloud, Firebase, AWS, Azure）へOIDC（OpenID Connect）およびWorkload Identity経由でセキュアにキーレス接続・デプロイするための設定を自動または半自動で完遂します。ユーザーから「GitHub ActionsでOIDCを設定して」「Firebase/GCPのOIDC連携を組んで」などの指示があった場合にこのスキルを使用し、設定コマンドの実行からGitHubワークフローYAMLの作成までを行います。
---

# GitHub Actions OIDC Setup Skill

このスキルは、GitHub Actionsから各クラウドプロバイダ（Google Cloud, Firebase, AWS, Azure）へ、一時的な認証情報を用いてセキュアに接続するためのOIDC（OpenID Connect） / Workload Identity連携設定をサポート・自動実行します。
従来の長期的なサービスアカウントキーやIAMアクセスキーをGitHubのSecretsに登録する運用を廃止し、より安全なキーレス認証へ移行させます。

## トリガー条件
ユーザーが以下のような要望を出した時に発動します：
- 「GitHub ActionsでOIDC対応の設定をして」
- 「GitHub ActionsでFirebase Hostingにデプロイする処理のOIDC認証で組んで」
- 「GCP/AWS/AzureのWorkload Identity連携を設定して」
- 「GitHubからクラウドへのデプロイをキーレスにしたい」

---

## ワークフロー手順

### ステップ 1: 要件の把握とパラメータの収集
処理を開始する前に、ユーザーの環境から以下の情報を自動取得、またはユーザーに確認します。

1. **対象のクラウドプロバイダ**: Google Cloud (GCP) / Firebase, AWS, Azure のいずれか。
2. **GitHubリポジトリ情報**: `owner/repo` 名（例: `mono0926/dog`）。ローカルのgit設定（`git remote -v` 等）から自動取得を試みてください。
3. **クラウド側の識別子**:
   - **Google Cloud / Firebase**: GCPプロジェクトID、プロジェクト番号、使用するサービスアカウント名。
   - **AWS**: AWSアカウントID、作成するIAMロール名。
   - **Azure**: テナントID、サブスクリプションID、アプリ（クライアント）ID。
4. **必要な権限・用途**: デプロイ対象（Firebase Hosting, Cloud Functions, Cloud Run, AWS S3, ECRなど）に応じて付与すべきロール/ポリシー。

### ステップ 2: クラウド別詳細リファレンスの読み込み
収集した情報に基づいて、以下の対応するリファレンスドキュメントを読み込み、具体的なセットアップ手順を実行します。

- **Google Cloud / Firebase の場合**:
  [gcp-firebase.md](references/gcp-firebase.md) を読み込んで実行してください。
- **AWS の場合**:
  [aws.md](references/aws.md) を読み込んで実行してください。
- **Azure の場合**:
  [azure.md](references/azure.md) を読み込んで実行してください。

### ステップ 3: ローカル環境のCLIツール有無の確認
設定コマンドをエージェントが代理実行できるか確認するため、必要なCLIツールがインストールされ、ログイン状態にあるかを検査します。
- GCP: `gcloud --version` および認証状態の確認
- AWS: `aws --version` および認証状態の確認
- Azure: `az --version` および認証状態の確認

エージェント自身でCLI操作ができる場合、コマンドを提示してユーザーの承認を得た上で、自動実行します。
CLIが使えない、または権限不足の場合は、ユーザー自身が実行するための「そのままコピーしてターミナルで実行できるgcloud/awsコマンドスクリプト」を提示して、実行を促してください。

### ステップ 4: GitHub Actions ワークフローYAMLの作成・修正
認証設定が完了したら、GitHub ActionsからOIDC連携を利用するためのYAMLファイルを `.github/workflows/` 以下に作成または修正します。

#### 共通の重要事項
1. **permissions ブロックの明示的な一括定義（必須）**
   GitHub ActionsでOIDCトークンを発行するためには、以下の `permissions` 設定を必ずセットで（一括定義で）YAMLに含めてください。片方だけ（例: `id-token: write` のみ）を指定すると、もう片方（`contents: read`）が自動で `none` になり、コードのチェックアウト（`actions/checkout`）等が失敗する原因となります。
   ```yaml
   permissions:
     id-token: write  # OIDCトークンの要求に必須
     contents: read   # リポジトリ内容の読み取り（checkout等）に必須
   ```

2. **サードパーティ製 Action のメジャーバージョン固定**
   ワークフロー内で外部のGitHub Actionsを使用する際は、原則として最新のメジャーバージョンを明記して使用してください。
   * 例: `actions/checkout@v4`, `google-github-actions/auth@v2`, `aws-actions/configure-aws-credentials@v4`

3. **本番環境等のアクセス制限（セキュリティの堅牢化）**
   本番（prod）やステージング（stg）環境用の接続設定を行う場合は、GCPのWorkload IdentityポリシーやAWSのIAM信頼ポリシー（Trust Policy）において、リポジトリ制限にワイルドカード（`*`）を安易に使用せず、特定のブランチ（例: `refs/heads/main`）や環境（例: `environment:production`）に厳格に絞り込んだ条件式を生成してください。
   * 悪い例: `repo:owner/repo:*` （すべてのブランチやPRから接続可能になってしまう）
   * 良い例: `repo:owner/repo:ref:refs/heads/main` （本番ブランチのみに制限）

---

## トラブルシューティングと注意点
1. **GitHubのOrganization制限**: 企業や一部のOrganizationでは、Workload Identityのプロバイダポリシーで特定のアトリビュート（例: `repository_owner`）が制限されている場合があります。ポリシーエラーが発生した場合は、アトリビュートマッピングを見直してください。
2. **ロールの反映遅延**: IAMロールやWorkload Identityの設定は、作成後実際に反映されるまでに数十秒〜数分かかる場合があります。Actionsが一時的に認証エラー（403等）になった場合は、少し時間をおいてから再試行するよう案内してください。
