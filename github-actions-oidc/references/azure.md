# Azure OIDC Setup Guide

このガイドは、Microsoft Azureに対して、GitHub ActionsからOIDC（Entra ID Federated Credentials）を用いてセキュアに認証・デプロイするための具体的な手順を定義します。

---

## 1. 必要な環境変数の整理
セットアップを行う前に、以下の値を整理しておきます。

| 変数名 | 説明 | 例 |
| :--- | :--- | :--- |
| `TENANT_ID` | Microsoft Entra ID (Azure AD) のテナントID | `00000000-0000-0000-0000-000000000000` |
| `SUBSCRIPTION_ID` | 対象のAzureサブスクリプションID | `00000000-0000-0000-0000-000000000000` |
| `APP_NAME` | 作成するAzure ADアプリ（サービスプリンシパル）名 | `github-actions-app` |
| `GITHUB_REPO` | GitHubリポジトリ名 (`owner/repo`) | `mono0926/dog` |

---

## 2. Azure 側の設定手順とコマンド

### 2.1. Entra ID アプリの登録とサービスプリンシパルの作成
Azure CLI を使用して、認証対象となるアプリ（サービスプリンシパル）を登録します。

```bash
# アプリの作成
APP_ID=$(az ad app create --display-name "${APP_NAME}" --query appId --output tsv)

# サービスプリンシパルの作成
az ad sp create --id "${APP_ID}"
```

### 2.2. ロールの割り当て（サブスクリプション等の権限付与）
リソースへのデプロイ権限を与えるため、作成したサービスプリンシパルに対して、サブスクリプションまたはリソースグループスコープでの「共同作成者 (Contributor)」などのロールを付与します。

```bash
# サブスクリプションレベルで共同作成者権限を付与する場合
az role assignment create \
    --role "Contributor" \
    --assignee "${APP_ID}" \
    --scope "/subscriptions/${SUBSCRIPTION_ID}"
```

### 2.3. Federated Credential（フェデレーション資格情報）の追加
GitHub Actions からのアクセス要求を信頼するように Federated Credential を構成します。

`credential-params.json` を作成：
```json
{
  "name": "github-actions-credential",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "repo:<GITHUB_REPO>:ref:refs/heads/main",
  "description": "GitHub Actions OIDC Authentication for main branch",
  "audiences": [
    "api://AzureADTokenExchange"
  ]
}
```
> [!IMPORTANT]
> `<GITHUB_REPO>` は実際の値に置き換えてください（例: `repo:mono0926/dog:ref:refs/heads/main`）。
> `subject` フィールドで許可するブランチや環境を指定します。
> - mainブランチに限定: `repo:owner/repo:ref:refs/heads/main`
> - 特定の環境 (Environment) に限定: `repo:owner/repo:environment:production`
> - プルリクエストに限定: `repo:owner/repo:pull_request`

資格情報をアプリに登録：
```bash
az ad app federated-credential create \
    --id "${APP_ID}" \
    --parameters @credential-params.json
```

---

## 3. GitHub Actions ワークフロー設定例

Azure公式の `azure/login` アクションを使用します。

### Azure Web App へのデプロイワークフロー例 (`.github/workflows/deploy-azure.yml`)

```yaml
name: Deploy to Azure Web App

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

      # OIDCを用いたAzure認証
      - name: Log in to Azure
        uses: azure/login@v2
        with:
          client-id: '00000000-0000-0000-0000-000000000000' # Azure AD アプリの Client ID (Application ID)
          tenant-id: '00000000-0000-0000-0000-000000000000' # Azure AD テナントID
          subscription-id: '00000000-0000-0000-0000-000000000000' # サブスクリプションID

      # Azure CLIを用いたリソースの操作やデプロイ
      - name: Run Azure CLI commands
        run: |
          az account show
          # ここにWeb Appやその他のデプロイコマンドを記述
```
