# The VM: Flatcar Container Linux, configured by Ignition on first boot, throwaway.
# Rebuild: terraform apply -replace=google_compute_instance.vm — the data disk (home, Tailscale identity, Docker's
# images and volumes) and the pairing survive; only Flatcar is new.
data "google_compute_image" "flatcar" {
  family  = "flatcar-stable"
  project = "kinvolk-public"
}

data "ct_config" "ignition" {
  strict = true
  content = templatefile("${path.module}/ignition.yaml.tftpl", {
    name        = var.name
    project     = var.project
    image_tag   = var.image_tag
    ssh_key     = var.ssh_public_key
    compose     = file("${path.module}/../compose.yaml")
    data_device = "/dev/disk/by-id/scsi-0Google_PersistentDisk_${google_compute_disk.data.name}"
  })
}

resource "google_compute_instance" "vm" {
  name         = var.name
  machine_type = var.machine_type
  zone         = var.zone

  boot_disk {
    initialize_params {
      image = data.google_compute_image.flatcar.self_link
      size  = var.boot_disk_gb
      type  = "pd-balanced"
    }
  }

  attached_disk {
    source      = google_compute_disk.data.id
    device_name = google_compute_disk.data.name
  }

  network_interface {
    subnetwork = google_compute_subnetwork.subnet.id
    access_config {} # an ephemeral public IP, for egress only: no firewall rule lets anything in
  }

  service_account {
    email  = google_service_account.vm.email
    scopes = ["cloud-platform"]
  }

  metadata = {
    user-data          = data.ct_config.ignition.rendered
    serial-port-enable = "TRUE" # break-glass: `gcloud compute connect-to-serial-port`, read-only without a password
  }

  allow_stopping_for_update = true
}
