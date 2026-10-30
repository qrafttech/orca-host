terraform {
  required_version = ">= 1.9"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 8.3"
    }
  }
}

provider "google" {
  project = var.project
  zone    = var.zone
}

locals {
  region = join("-", slice(split("-", var.zone), 0, 2))
}

resource "google_project_service" "api" {
  for_each           = toset(["compute.googleapis.com"])
  service            = each.key
  disable_on_destroy = false
}
