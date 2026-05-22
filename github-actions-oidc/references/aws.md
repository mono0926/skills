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
> [!IMPORTANT]
> `<AWS_ACCOUNT_ID>` と `<GITHUB_REPO>` は実際の値に置き換えてください（例: `arn:aws:iam::123456789012:oidc-provider/...`, `repo:mono0926/dog:*`）。`*` を末尾につけることで、特定リポジトリのすべてのブランチやプルリクエストからの接続を許可します。特定のブランチ（例: `main`）に絞る場合は、`repo:owner/repo:ref:refs/heads/main` のように指定します。

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
