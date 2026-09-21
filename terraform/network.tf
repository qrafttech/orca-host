# Own VPC, no firewall rule: nothing reaches the VM from the internet (GCP denies ingress by default). The
# default VPC would open SSH to the world. Tailscale needs no inbound port; the VM's SSH answers on its tailnet
# address only, because that is the only address anything can reach.
resource "google_compute_network" "vpc" {
  name                    = var.name
  auto_create_subnetworks = false
  depends_on              = [google_project_service.api]
}

resource "google_compute_subnetwork" "subnet" {
  name          = var.name
  network       = google_compute_network.vpc.id
  region        = local.region
  ip_cidr_range = "10.0.0.0/24"
}
