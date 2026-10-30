# State in a bucket of your own project, one prefix per host. Bucket and prefix are given at init time by the
# Makefile (`make init`), since a backend block cannot read variables.
terraform {
  backend "gcs" {}
}
