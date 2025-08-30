############################################
# Prometheus (kube-prometheus-stack) via Helm
# - 綁定 IRSA：module.prometheus_amp_irsa.iam_role_arn
# - 可選 AMP RemoteWrite（以變數控制）
############################################

resource "helm_release" "prometheus" {
  name             = "kube-prometheus-stack"
  namespace        = "monitoring"
  create_namespace = true

  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  # 可視需要微調版本
  version    = "65.1.1"

  values = [yamlencode({
    # Prometheus 主體設定
    prometheus = {
      serviceAccount = {
        create = true
        # 與 IRSA 綁定的 SA 名稱，需與 IRSA module 中 namespace_service_accounts 對應
        name   = "kube-prometheus-stack-prometheus"
        annotations = {
          "eks.amazonaws.com/role-arn" = module.prometheus_amp_irsa.iam_role_arn
        }
      }

      prometheusSpec = {
        # 讓 ServiceMonitor/PodMonitor 預設就會被抓
        serviceMonitorSelectorNilUsesHelmValues = false
        podMonitorSelectorNilUsesHelmValues     = false

        # 可選：RemoteWrite 到 AMP（依變數決定）
        remoteWrite = var.enable_amp_remote_write ? [
          {
            url   = "https://aps-workspaces.${var.aws_region}.amazonaws.com/workspaces/${var.amp_workspace_id}/api/v1/remote_write"
            # AMP 需要 SigV4 簽名（IRSA 提供臨時憑證）
            sigv4 = { region = var.aws_region }
          }
        ] : []
      }
    }

    # 基本可見性：保留 Grafana/Alertmanager 預設開啟（需要可自行調整）
    grafana = {
      enabled = true
      service = { type = "ClusterIP" }
    }

    alertmanager = {
      enabled = true
      service = { type = "ClusterIP" }
    }
  })]

  depends_on = [
    module.eks,
    module.prometheus_amp_irsa
  ]
}
