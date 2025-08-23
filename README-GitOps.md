# GitOps on EKS with Argo CD + GitHub Actions + Harbor

本文件說明如何在本專案上以 GitOps 方式部署。

## 先決條件
- 已以 Terraform 建好 EKS（本 repo 內 `infra/`）。
- 已安裝 AWS CLI、kubectl、helm，且可登入 AWS 帳號。

## 1. 取得 kubeconfig 並驗證叢集
```bash
terraform -chdir=infra output kubeconfig_command -raw | bash
kubectl get nodes
```

## 2. 安裝/驗證 Argo CD 與 ALB Controller（Terraform 自動安裝）
- 確認 `argocd-server` Service 有 External IP 或 ALB Hostname：
```bash
kubectl -n argocd get svc argocd-server
```
- 取得 Argo CD 初始密碼：
```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
```

## 3. 建立 Harbor 拉取密碼（imagePullSecrets）
將以下指令中的變數替換為你的 Harbor 資訊：
```bash
kubectl -n demo create secret docker-registry harbor-regcred \
  --docker-server=$HARBOR_REGISTRY \
  --docker-username=$HARBOR_USER \
  --docker-password=$HARBOR_PASSWORD \
  --docker-email=$YOUR_EMAIL
```

## 4. 設定 GitOps Root 應用
將 `gitops/argocd-root-app.yaml` 與 `gitops/applications/demo-app.yaml` 的 repoURL 改為你的 GitHub 倉庫 URL，並提交。
然後將 root 應用套用：
```bash
kubectl apply -f gitops/argocd-root-app.yaml
```

## 5. GitHub Actions（範例）
- 已提供 `.github/workflows/harbor-ci.yml`，請在 GitHub Repo Secrets 設定：
  - `HARBOR_HOST`, `HARBOR_PROJECT`, `HARBOR_USERNAME`, `HARBOR_PASSWORD`
  - Optional：若用 ECR/GHCR 可自行調整 workflow
- 調整 `IMAGE_NAME` 為你的 Harbor 倉庫路徑。
- 調整 `docker/Dockerfile` 與應用程式內容。

## 6. DNS/Ingress
- 若使用 Ingress（`k8s/ingress.yaml`），需確認 AWS Load Balancer Controller 正常，並在 Route53 綁定網域到 ALB DNS。

## 7. 常見問題
- ALB Controller 權限：本 Terraform 會自動以 IRSA 綁定 IAM。若升級版本請同步更新 `aws_iam_policy` 的來源。
- Argo CD UI：建議改用 Ingress 並設定 OIDC/SSO。
