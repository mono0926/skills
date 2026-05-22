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
GitHub OIDC用の認証プロバイダを設定します。アトリビュートマッピングで、GitHubから送られてくるOIDCトークンの情報をGoogle Cloud側のアトリビュートにマッピングします。また、組織ポリシー等でアトリビュート条件が必須とされる場合やセキュリティ堅牢化のため、`--attribute-condition` でリポジトリオーナーの検証を追加することを強く推奨します。
```bash
gcloud iam workload-identity-pools providers create-oidc "${PROVIDER_NAME}" \
  --project="${PROJECT_ID}" \
  --location="global" \
  --workload-identity-pool="${POOL_NAME}" \
  --display-name="GitHub Actions Provider" \
  --issuer-uri="https://token.actions.githubusercontent.com" \
  --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.actor=assertion.actor,attribute.repository_owner=assertion.repository_owner" \
  --attribute-condition="assertion.repository_owner == 'YOUR_ORGANIZATION_OR_USER'"
```
> [!IMPORTANT]
> `--attribute-condition` には、必ず自身のリポジトリオーナー（GitHubユーザー名または組織名。例: `'mono0926'`）を指定してください。これを怠ると、他の誰かのリポジトリから認証要求が送られた場合にポリシーチェックをバイパスされる危険性があります。さらに厳格にする場合、`assertion.ref == 'refs/heads/main'` などのブランチ制限条件を追加することも可能です。

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

# 1. permissions は必ず id-token と contents の両方をセットで明示的に指定してください。
permissions:
  id-token: write # OIDCトークンの要求に必須
  contents: read  # actions/checkout等のリポジトリ読み取りに必須

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      # 2. サードパーティアクションは最新のメジャーバージョン（@v4等）で固定します
      - name: Checkout code
        uses: actions/checkout@v4

      # OIDCを用いたGoogle Cloud認証
      - name: Authenticate to Google Cloud
        uses: google-github-actions/auth@v2
        with:
          # プロバイダのフルパス: projects/<PROJECT_NUMBER>/locations/global/workloadIdentityPools/<POOL_NAME>/providers/<PROVIDER_NAME>
          workload_identity_provider: 'projects/123456789012/locations/global/workloadIdentityPools/github-pool/providers/github-provider'
          service_account: 'github-actions-deployer@dog-prod.iam.gserviceaccount.com'

      # 3. Firebase CLIを用いて直接デプロイ（推奨）
      # （注: Firebase CLIは、google-github-actions/authが生成した資格情報を自動検知してログインします）
      - name: Deploy to Firebase Hosting
        run: npx -y firebase-tools deploy --only hosting --project dog-prod
        working-directory: firebase
```

> [!WARNING]
> **重要: FirebaseExtended/action-hosting-deploy アクションについて**
> 従来よく使われていた `FirebaseExtended/action-hosting-deploy` アクションは、入力パラメータ `firebaseServiceAccount` が必須（Required）に指定されているため、OIDC化にあたってこれを削除すると **`Error: Input required and not supplied: firebaseServiceAccount`** というエラーでジョブが即時失敗します。
> OIDC認証を使用する場合は、上記テンプレートのように `npx -y firebase-tools` などのCLIコマンドを `run` ステップで直接実行するか、OIDCに対応したサードパーティ製アクション（例: `w9jds/firebase-action`）を最新バージョンで使用してください。
