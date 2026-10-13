# The VM: Debian, configured by host/first-boot.sh.tftpl, its `startup-script`, throwaway.
# Rebuild: `make rebuild` (apply -replace=google_compute_instance.vm) — the data disk (home, Tailscale identity, Docker's
# images and volumes) and the pairing survive; only Debian is new.
data "google_compute_image" "debian" {
  family  = "debian-13"
  project = "debian-cloud"
}

locals {
  first_boot = templatefile("${path.module}/../host/first-boot.sh.tftpl", {
    name        = var.name
    orca_image  = var.orca_image
    ssh_key     = var.ssh_public_key
    data_device = "/dev/disk/by-id/scsi-0Google_PersistentDisk_${google_compute_region_disk.data.name}"
    compose     = trimsuffix(file("${path.module}/../compose.yaml"), "\n")
    env_tpl     = var.env_tpl == "" ? "" : trimsuffix(file(var.env_tpl), "\n")
    scripts = {
      for f in ["render-env", "up", "firewall"] : f => trimsuffix(file("${path.module}/../host/${f}"), "\n")
    }
    units = {
      for f in ["orca-env.service", "orca.service", "orca-update.service", "orca-update.timer"] :
      f => trimsuffix(file("${path.module}/../host/${f}"), "\n")
    }
  })
}

resource "google_compute_instance" "vm" {
  name         = var.name
  machine_type = var.machine_type
  zone         = var.zone

  boot_disk {
    initialize_params {
      image = data.google_compute_image.debian.self_link
      size  = var.boot_disk_gb
      type  = "pd-balanced"
    }
  }

  attached_disk {
    source      = google_compute_region_disk.data.self_link
    device_name = google_compute_region_disk.data.name
  }

  network_interface {
    subnetwork = google_compute_subnetwork.subnet.id
    access_config {} # an ephemeral public IP, for egress only: no firewall rule lets anything in
  }

  # Run at every boot by the guest agent; the script stops at once when it applied itself already. A change of it
  # is stored in place and runs at the next boot: `make rebuild` for a clean one.
  metadata = {
    startup-script     = local.first_boot
    enable-oslogin     = "TRUE" # IAP SSH with the project's IAM identities, no key pushed into metadata
    serial-port-enable = "TRUE" # break-glass: `gcloud compute connect-to-serial-port`, read-only without a password
  }

  allow_stopping_for_update = true
}
