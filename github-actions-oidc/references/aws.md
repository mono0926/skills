# AWS OIDC Setup Guide

このガイドは、AWS（Amazon Web Services）に対して、GitHub ActionsからOIDC（OpenID Connect）認証を用いてセキュアに接続・デプロイするための具体的な手順を定義します。

---

## 1. 必要な環境変数の整理
セットアップを行う前に、以下の値を整理しておきます。

| 変数名 | 説明 | 例 |
| :--- | :--- | :--- |
| `AWS_ACCOUNT_ID` | AWSアカウントID（12桁の数字） | `123456789012` |
| `GITHUB_REPO` | GitHubリポジトリ名 (`owner/repo`) | `mono0926/dog` |
| `ROLE_NAME` | 作成するIAMロール名 | `github-actions-deploy-role` |
| `AWS_REGION` | デプロイ先のAWSリージョン | `ap-northeast-1` |

---

## 2. AWS 側の設定手順とコマンド

### 2.1. IAM OIDC ID プロバイダの作成
すでにAWSアカウント内にGitHub用のOIDCプロバイダが存在する場合はこの手順をスキップできます。存在しない場合は、以下のコマンドで作成します。

```bash
# GitHubのOIDCプロバイダ用サムプリント（Thumbprint）。通常は以下の値が使われますが、
# AWS CLI v2以降では自動取得されるため、コマンド実行時に指定を省略、または代表的な値を渡します。
THUMBPRINT="6938fd4d98bab03faadb97b34396831e3780aea1"

aws iam create-open-id-connect-provider \
    --url "https://token.actions.githubusercontent.com" \
    --client-id-list "sts.amazonaws.com" \
    --thumbprint-list "${THUMBPRINT}"
```

### 2.2. 信頼関係ポリシー（Trust Policy）の作成
GitHub Actionsからのアクセスのみを許可する信頼関係ポリシーをJSONファイルとして作成します。

**`trust-policy.json`** を作成：
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::<AWS_ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": "repo:<GITHUB_REPO>:*"
        }
      }
    }
  ]
}
```
> [!WARNING]
> 条件式で `repo:<GITHUB_REPO>:*` のように末尾にワイルドカード（`*`）を使用すると、**対象リポジトリのすべてのブランチ、タグ、およびプルリクエスト（フォーク元からのPR含む）からの接続**が許可されてしまいます。これは、検証されていないコードや第三者のプルリクエストから本番リソースへのアクセスを許してしまう重大なセキュリティリスクを伴います。
> 
> **セキュリティのベストプラクティス:**
> 原則として、デプロイや書き込み権限を持つIAMロールは、以下のように特定の保護されたブランチ（例: `main`）や環境（Environment）に制限してください。
> 
> - **mainブランチのみに制限する場合**:
>   `"token.actions.githubusercontent.com:sub": "repo:<GITHUB_REPO>:ref:refs/heads/main"`
> - **特定のGitHub環境（例: production）に制限する場合**:
>   `"token.actions.githubusercontent.com:sub": "repo:<GITHUB_REPO>:environment:production"`

### 2.3. IAM ロールの作成
上記で作成した信頼関係ポリシーを指定して、GitHub Actions専用のIAMロールを作成します。

```bash
aws iam create-role \
    --role-name "${ROLE_NAME}" \
    --assume-role-policy-document file://trust-policy.json
```

### 2.4. デプロイ用ポリシーの付与
ロールに対して、実行したい処理に必要な権限（S3へのファイルアップロード、ECSの更新など）を付与します。

**例: S3へのデプロイ権限を与える場合（インラインポリシーの追加）**
`s3-deploy-policy.json` を作成：
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:GetObject",
        "s3:ListBucket",
        "s3:DeleteObject"
      ],
      "Resource": [
        "arn:aws:s3:::<YOUR-BUCKET-NAME>",
        "arn:aws:s3:::<YOUR-BUCKET-NAME>/*"
      ]
    }
  ]
}
```

ポリシーをロールに付与：
```bash
aws iam put-role-policy \
    --role-name "${ROLE_NAME}" \
    --policy-name "S3DeployPolicy" \
    --policy-document file://s3-deploy-policy.json
```

---

## 3. GitHub Actions ワークフロー設定例

AWS公式の `aws-actions/configure-aws-credentials` アクションを使用します。

### ワークフロー作成における重要セキュリティルール

1. **`permissions` ブロックの明示的な一括定義**:
   GitHub ActionsでOIDCトークンを発行するためには、ジョブまたはワークフロー全体に `permissions` ブロックを定義し、`id-token: write` と `contents: read` を**同時に**指定する必要があります。
   > [!IMPORTANT]
   > `id-token: write` のみを指定すると、デフォルトで `contents` の権限が `none` になり、コードのチェックアウト（`actions/checkout`）等が失敗します。必ず両方をセットで記述してください。

2. **サードパーティ製 Action のバージョン固定**:
   ワークフローで使用するサードパーティ製 Action（`aws-actions/configure-aws-credentials` など）は、検証済みの信頼できるバージョンを使用するため、原則として最新のメジャーバージョン（例: `@v4`）を明記してください。さらにセキュリティを厳格に管理する場合は、コミットSHAによる固定を推奨します。

### S3 静的サイトデプロイワークフロー例 (`.github/workflows/deploy-aws.yml`)

```yaml
name: Deploy to AWS S3

on:
  push:
    branches:
      - main

permissions:
  id-token: write # OIDCトークンの要求に必須
  contents: read  # リポジトリ読み取りに必須

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      # OIDCを用いたAWS認証
      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::123456789012:role/github-actions-deploy-role
          aws-region: ap-northeast-1
          # session-name は監査ログでアクションを特定しやすくするために推奨
          role-session-name: GitHubActionsWorkflowDeployment

      # S3へのデプロイ実行
      - name: Deploy to S3
        run: |
          aws s3 sync ./build s3://my-static-website-bucket --delete
```
