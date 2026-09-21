terraform {
  required_version = ">= 1.9"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 8.3"
    }
    ct = {
      source  = "poseidon/ct"
      version = "~> 0.14"
    }
  }
}

provider "google" {
  project = var.project
  zone    = var.zone
}
