provider "kubernetes" {}
provider "grafana" {}

terraform {
  required_providers {
    grafana = {
      source  = "grafana/grafana"
    }
  }
}
