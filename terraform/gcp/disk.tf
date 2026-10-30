# The data disk outlives the VM: /home/orca, the Tailscale identity, Docker's data root. Daily snapshots, seven kept.
# Regional: replicated in two zones, the VM runs in either. A zone out of stock (or down) is a new `zone` and an apply.
resource "google_compute_region_disk" "data" {
  name          = "${var.name}-data"
  region        = local.region
  replica_zones = var.data_disk_zones
  type          = "pd-balanced"
  size          = var.data_disk_gb

  lifecycle {
    # `make destroy` takes it out of the state first, then deletes it with gcloud.
    prevent_destroy = true
    # A disk restored from a snapshot (a recovery, a migration) is imported as it is: where it came from is history.
    ignore_changes = [snapshot]
  }
  depends_on = [google_project_service.api]
}

resource "google_compute_resource_policy" "snapshots" {
  name   = "${var.name}-daily"
  region = local.region
  snapshot_schedule_policy {
    schedule {
      daily_schedule {
        days_in_cycle = 1
        start_time    = "03:00"
      }
    }
    retention_policy {
      max_retention_days    = 7
      on_source_disk_delete = "KEEP_AUTO_SNAPSHOTS"
    }
  }
}

resource "google_compute_region_disk_resource_policy_attachment" "snapshots" {
  name   = google_compute_resource_policy.snapshots.name
  disk   = google_compute_region_disk.data.name
  region = local.region
}
