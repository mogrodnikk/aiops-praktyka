# Odpowiednik k8s/netpol-postgres.yaml, zapisany jako zasób Terraform.
# Ten sam zakres: Ingress do Postgresa tylko od orders-api na TCP 5432.
resource "kubernetes_network_policy_v1" "kantyna_postgres" {
  metadata {
    name      = "kantyna-postgres"
    namespace = var.namespace
    labels = {
      "app.kubernetes.io/name"       = "postgres"
      "app.kubernetes.io/instance"   = "kantyna"
      "app.kubernetes.io/component"  = "postgres"
      "app.kubernetes.io/part-of"    = "kantyna"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  spec {
    pod_selector {
      match_labels = {
        "app.kubernetes.io/name"      = "postgres"
        "app.kubernetes.io/instance"  = "kantyna"
        "app.kubernetes.io/component" = "postgres"
      }
    }

    policy_types = ["Ingress"]

    ingress {
      from {
        pod_selector {
          match_labels = {
            "app.kubernetes.io/name"      = "orders-api"
            "app.kubernetes.io/instance"  = "kantyna"
            "app.kubernetes.io/component" = "orders-api"
          }
        }
      }

      ports {
        port     = "5432"
        protocol = "TCP"
      }
    }
  }
}
