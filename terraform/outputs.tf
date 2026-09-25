output "name" {
  value = google_compute_instance.vm.name
}

output "secret" {
  description = "Where the 1Password service-account token goes: `make secret`."
  value       = google_secret_manager_secret.op_token.secret_id
}

output "ssh" {
  description = "Over the tailnet, once the VM has joined it."
  value       = "ssh core@${var.name}"
}
