# The data disk outlives the VM: /home/orca and the Tailscale identity. Daily snapshots, seven kept.
resource "google_compute_disk" "data" {
  name = "${var.name}-data"
  type = "pd-balanced"
  size = var.data_disk_gb

  lifecycle {
    prevent_destroy = true
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

resource "google_compute_disk_resource_policy_attachment" "snapshots" {
  name = google_compute_resource_policy.snapshots.name
  disk = google_compute_disk.data.name
}
