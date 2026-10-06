provider "kubernetes" {
  # Kubeconfig i kontekst z własnej konfiguracji kubectl (ten sam, którego używa `kubectl`).
  config_path    = var.kubeconfig_path
  config_context = var.kube_context
}
