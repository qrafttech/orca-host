# The 1Password service-account token of this host: one line, read-only on one vault, the credential the VM
# renders its env file with (see `render-env` in ignition.yaml.tftpl). Terraform creates the secret empty;
# versions are added by `make secret`, so no secret ever passes through Terraform or its state.
resource "google_secret_manager_secret" "op_token" {
  secret_id = "orca-host-${var.name}-op-token"
  replication {
    auto {}
  }
  depends_on = [google_project_service.api]
}
