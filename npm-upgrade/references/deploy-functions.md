# Cloud Functions デプロイワークフロー設定ガイド

このドキュメントは、Node.js プロジェクト（特に Cloud Functions for Firebase または Google Cloud Functions）において、`main` ブランチマージ時に自動デプロイを行うための GitHub Actions ワークフロー設定リファレンスです。
サービスアカウントキーの JSON ファイルを GitHub Secrets に保存するレガシーな運用を避け、**Workload Identity 連携 (OIDC)** を用いたセキュアなキーレス認証を採用します。

---

## 1. Firebase Cloud Functions 向け設定

Firebase CLI (`firebase deploy --only functions`) を使用してデプロイする場合の標準ワークフローです。

### ワークフローファイル: `.github/workflows/deploy-functions.yaml`

```yaml
name: Deploy Cloud Functions

on:
  push:
    branches:
      - main
    paths:
      - 'functions/**'
      - 'firebase.json'
      - '.firebaserc'
      - '.github/workflows/deploy-functions.yaml'

permissions:
  id-token: write  # OIDC認証に必須
  contents: read   # チェックアウトに必須

jobs:
  deploy:
    name: Deploy to Firebase Functions
    runs-on: ubuntu-latest
    steps:
      - name: Checkout repository
        uses: actions/checkout@v4

      - name: Setup Node.js
        uses: actions/setup-node@v4
        with:
          node-version: 20
          cache: 'npm'
          cache-dependency-path: 'functions/package-lock.json'

      - name: Install dependencies
        working-directory: functions
        run: npm ci

      - name: Build functions
        working-directory: functions
        run: npm run build --if-present

      - name: Authenticate to Google Cloud (OIDC)
        uses: google-github-actions/auth@v2
        with:
          project_id: ${{ secrets.GCP_PROJECT_ID }}
          workload_identity_provider: ${{ secrets.GCP_WORKLOAD_IDENTITY_PROVIDER }}
          service_account: ${{ secrets.GCP_SERVICE_ACCOUNT }}

      - name: Deploy to Firebase Functions
        run: npx firebase-tools deploy --only functions --project ${{ secrets.GCP_PROJECT_ID }}
```

### 必要なシークレット・環境変数
- `GCP_PROJECT_ID`: 対象の Google Cloud / Firebase プロジェクトID
- `GCP_WORKLOAD_IDENTITY_PROVIDER`: `projects/<PROJECT_NUMBER>/locations/global/workloadIdentityPools/<POOL_NAME>/providers/<PROVIDER_NAME>`
- `GCP_SERVICE_ACCOUNT`: デプロイ用サービスアカウントのメールアドレス（例: `github-deployer@<PROJECT_ID>.iam.gserviceaccount.com`）

※ Workload Identity の未設定時は、リポジトリ内の `github-actions-oidc` スキルを活用して GCP / Firebase の OIDC 連携設定を完了させてください。

---

## 2. Google Cloud Functions (第2世代 / Cloud Run functions) 向け設定

Firebase CLI を使わず、Google Cloud 公式の Action (`google-github-actions/deploy-cloud-functions`) を直接利用する場合の設定です。

### ワークフローファイル: `.github/workflows/deploy-cloud-functions.yaml`

```yaml
name: Deploy Cloud Functions (Gen2)

on:
  push:
    branches:
      - main
    paths:
      - 'src/**'
      - 'package.json'
      - 'package-lock.json'
      - '.github/workflows/deploy-cloud-functions.yaml'

permissions:
  id-token: write
  contents: read

jobs:
  deploy:
    name: Deploy Function
    runs-on: ubuntu-latest
    steps:
      - name: Checkout repository
        uses: actions/checkout@v4

      - name: Setup Node.js
        uses: actions/setup-node@v4
        with:
          node-version: 20
          cache: 'npm'

      - name: Install dependencies
        run: npm ci

      - name: Build
        run: npm run build --if-present

      - name: Authenticate to Google Cloud
        uses: google-github-actions/auth@v2
        with:
          project_id: ${{ secrets.GCP_PROJECT_ID }}
          workload_identity_provider: ${{ secrets.GCP_WORKLOAD_IDENTITY_PROVIDER }}
          service_account: ${{ secrets.GCP_SERVICE_ACCOUNT }}

      - name: Deploy to Cloud Functions
        uses: google-github-actions/deploy-cloud-functions@v3
        with:
          name: my-function
          runtime: nodejs20
          region: asia-northeast1
          entry_point: myEntryPoint
```

---

## 3. プロジェクト内点検チェックリスト

`npm-upgrade` 実行時、エージェントは以下の項目を確認します：

1. **ワークフローファイルの存在確認**:
   - `.github/workflows/` ディレクトリ内に `firebase-tools deploy` または `deploy-cloud-functions` を含む YAML が存在するか。
2. **トリガー条件の確認**:
   - `on.push.branches` に `main`（または default branch）が含まれているか。
   - `paths` 指定がある場合、アップグレード対象のディレクトリ（例: `functions/**`）が含まれているか。
3. **未設定時の対応方針**:
   - プロジェクト内に `firebase.json` があり `functions` 設定が存在するがデプロイワークフローがない場合、上記の `.github/workflows/deploy-functions.yaml` の生成を提案し、`github-actions-oidc` スキルと連携してセットアップを実施する。
   - PR 本文の「🚀 マージ時デプロイ」セクションに、自動デプロイの稼働状況や反映先を明記する。
