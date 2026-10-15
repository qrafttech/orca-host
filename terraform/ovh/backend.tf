# State in a GCS bucket, one prefix per host, as for a GCP host. Bucket and prefix are given at init time by the
# Makefile (`make init`), since a backend block cannot read variables.
terraform {
  backend "gcs" {}
}
