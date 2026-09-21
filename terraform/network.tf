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

# Break-glass when Tailscale is down: SSH from Google's IAP range only, i.e. `gcloud compute ssh --tunnel-through-iap`,
# which needs an IAM identity of the project and OS Login (enabled by Flatcar's GCE image). Not reachable from
# the internet: the IAP range is Google's.
resource "google_compute_firewall" "iap_ssh" {
  name          = "${var.name}-iap-ssh"
  network       = google_compute_network.vpc.id
  source_ranges = ["35.235.240.0/20"]
  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}
