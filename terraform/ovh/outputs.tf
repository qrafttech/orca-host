output "name" {
  value = var.name
}

output "ipv4" {
  description = "The public address: SSH until `make lockdown`, for the first `make secret`."
  value       = one([for ip in data.ovh_vps.vps.ips : ip if !strcontains(ip, ":")])
}

output "ssh" {
  description = "Over the tailnet, once the VM has joined it."
  value       = "ssh core@${var.name}"
}
