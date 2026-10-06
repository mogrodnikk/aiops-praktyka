terraform {
  required_version = ">= 1.5.0"

  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.35"
    }
  }

  # Stan lokalny (bez backendu zdalnego). Plik jest w .gitignore.
  backend "local" {
    path = "terraform.tfstate"
  }
}
