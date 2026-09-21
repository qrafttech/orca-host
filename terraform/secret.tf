# The env file of this host (see compose.yaml for its contents). Terraform creates the secret, empty; versions
# are added by `make secret`, so no secret ever passes through Terraform or its state.
resource "google_secret_manager_secret" "env" {
  secret_id = "orca-host-${var.name}-env"
  replication {
    auto {}
  }
  depends_on = [google_project_service.api]
}
