output "name" {
  value = google_compute_instance.vm.name
}

output "ssh" {
  description = "Over the tailnet, once the VM has joined it."
  value       = "ssh core@${var.name}"
}
