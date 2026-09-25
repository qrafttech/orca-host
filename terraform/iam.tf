locals {
  region = join("-", slice(split("-", var.zone), 0, 2))
}

resource "google_project_service" "api" {
  for_each           = toset(["compute.googleapis.com", "iam.googleapis.com", "secretmanager.googleapis.com"])
  service            = each.key
  disable_on_destroy = false
}

# The VM's identity: reads its own secret, nothing else.
resource "google_service_account" "vm" {
  account_id   = var.name
  display_name = "orca-host ${var.name}"
  depends_on   = [google_project_service.api]
}

resource "google_secret_manager_secret_iam_member" "vm" {
  secret_id = google_secret_manager_secret.op_token.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.vm.email}"
}
