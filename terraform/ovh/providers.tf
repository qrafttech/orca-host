terraform {
  required_version = ">= 1.9"
  required_providers {
    ovh = {
      source  = "ovh/ovh"
      version = "~> 2.22"
    }
  }
}

# Credentials from the environment, put there by the Makefile from 1Password (`op run`): OVH_ENDPOINT,
# OVH_APPLICATION_KEY, OVH_APPLICATION_SECRET, OVH_CONSUMER_KEY. The `ovhcloud` CLI below reads the same.
provider "ovh" {}
