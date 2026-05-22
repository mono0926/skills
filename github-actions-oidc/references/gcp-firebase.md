# Google Cloud / Firebase OIDC Setup Guide

このガイドは、Google Cloud (GCP) および Firebase に対して、GitHub ActionsからWorkload Identity連携を用いたセキュアなキーレスデプロイを設定するための具体的な手順を定義します。

---

## 1. 必要な環境変数の整理
セットアップをスムーズに行うために、以下の値を事前に用意・決定します。

| 変数名 | 説明 | 例 |
| :--- | :--- | :--- |
| `PROJECT_ID` | GCPプロジェクトID | `dog-prod` |
| `PROJECT_NUMBER` | GCPプロジェクト番号（数字） | `123456789012` |
| `GITHUB_REPO` | GitHubリポジトリ名 (`owner/repo`) | `mono0926/dog` |
| `POOL_NAME` | Workload Identity Pool名 | `github-pool` |
| `PROVIDER_NAME` | Workload Identity Provider名 | `github-provider` |
| `SA_NAME` | 作成するサービスアカウント名 | `github-actions-deployer` |

> [!TIP]
> プロジェクト番号は `gcloud projects describe $PROJECT_ID --format="value(projectNumber)"` で取得可能です。

---

## 2. Google Cloud / Firebase 側の設定コマンド
エージェント、またはユーザーがターミナルで実行するコマンド群です。

### 2.1. 必要なAPIの有効化
```bash
gcloud services enable iamcredentials.googleapis.com \
  --project="${PROJECT_ID}"
```

### 2.2. Workload Identity Pool の作成
```bash
gcloud iam workload-identity-pools create "${POOL_NAME}" \
  --project="${PROJECT_ID}" \
  --location="global" \
  --display-name="GitHub Actions Pool"
```

### 2.3. Workload Identity Provider の作成
GitHub OIDC用の認証プロバイダを設定します。アトリビュートマッピングで、GitHubから送られてくるOIDCトークンの情報をGoogle Cloud側のアトリビュートにマッピングします。
```bash
gcloud iam workload-identity-pools providers create-oidc "${PROVIDER_NAME}" \
  --project="${PROJECT_ID}" \
  --location="global" \
  --workload-identity-pool="${POOL_NAME}" \
  --display-name="GitHub Actions Provider" \
  --issuer-uri="https://token.actions.githubusercontent.com" \
  --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.actor=assertion.actor,attribute.repository_owner=assertion.repository_owner"
```

### 2.4. 専用サービスアカウントの作成
デプロイ処理を実行するための専用サービスアカウントを作成します。
```bash
gcloud iam service-accounts create "${SA_NAME}" \
  --project="${PROJECT_ID}" \
  --display-name="GitHub Actions Deployer"
```

### 2.5. OIDC経由の偽装（Impersonation）権限の付与
**最も重要なセキュリティ設定です。** 特定のGitHubリポジトリ（`$GITHUB_REPO`）からのみ、作成したサービスアカウントのトークンを発行できるように制限をかけます。
```bash
gcloud iam service-accounts add-iam-policy-binding \
  "${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com" \
  --project="${PROJECT_ID}" \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL_NAME}/attribute.repository/${GITHUB_REPO}"
```

### 2.6. デプロイに必要なロールの付与
デプロイする対象（Firebase Hosting / Cloud Functions / Cloud Run など）に応じて、サービスアカウントに必要な権限を付与します。

**Firebase Hosting にデプロイする場合:**
```bash
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com" \
  --role="roles/firebasehosting.admin"
```

**Cloud Functions (v2) や Cloud Run をデプロイする場合:**
```bash
# Cloud Functions 管理者
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com" \
  --role="roles/cloudfunctions.developer"

# Cloud Run 管理者 (Functions v2 は裏側で Cloud Run を使用するため必要)
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com" \
  --role="roles/run.developer"

# 展開時のサービスアカウント偽装権限
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com" \
  --role="roles/iam.serviceAccountUser"

# アーティファクト書き込み権限 (Artifact Registry)
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com" \
  --role="roles/artifactregistry.writer"
```

---

## 3. GitHub Actions ワークフロー設定例

認証用アクション `google-github-actions/auth` を使用します。これによって、以降のステップで自動的にGoogle Cloud CLIやFirebase CLIが認証済みの状態になります。

### Firebase Hosting へのデプロイワークフロー例 (`.github/workflows/deploy-firebase.yml`)

```yaml
name: Deploy to Firebase Hosting

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

      # OIDCを用いたGoogle Cloud認証
      - name: Authenticate to Google Cloud
        uses: google-github-actions/auth@v2
        with:
          # プロバイダのフルパス: projects/<PROJECT_NUMBER>/locations/global/workloadIdentityPools/<POOL_NAME>/providers/<PROVIDER_NAME>
          workload_identity_provider: 'projects/123456789012/locations/global/workloadIdentityPools/github-pool/providers/github-provider'
          service_account: 'github-actions-deployer@dog-prod.iam.gserviceaccount.com'

      # Firebase CLIのセットアップとデプロイ
      # （注: Firebase CLIは、google-github-actions/authによって生成された資格情報を自動的に認識します）
      - name: Deploy to Firebase Hosting
        uses: w9jds/firebase-action@v2.2.0
        with:
          args: deploy --only hosting
        env:
          # google-github-actions/authがエクスポートした環境変数を利用してFirebaseにプロジェクトを通知
          GCP_PROJECT: 'dog-prod'
```

> [!WARNING]
> Firebase CLIのバージョンやアクションによっては、`FIREBASE_TOKEN` が不要になり、上記のように `GCP_PROJECT` 環境変数を設定するだけで Workload Identity の認証情報を使ってデプロイできるようになります。
