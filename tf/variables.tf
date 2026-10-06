variable "kubeconfig_path" {
  description = "Ścieżka do kubeconfig używanego przez kubectl."
  type        = string
  default     = "~/.kube/config"
}

variable "kube_context" {
  description = "Kontekst kubectl (kubectl config current-context)."
  type        = string
  default     = "aiops"
}

variable "namespace" {
  description = "Namespace uczestnika, w którym działa Kantyna."
  type        = string
  default     = "mateusz"
}
