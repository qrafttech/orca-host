output "name" {
  value = google_compute_instance.vm.name
}

output "secret" {
  description = "Where the env file goes: `make secret`."
  value       = google_secret_manager_secret.env.secret_id
}

output "ssh" {
  description = "Over the tailnet, once the VM has joined it."
  value       = "ssh core@${var.name}"
}
