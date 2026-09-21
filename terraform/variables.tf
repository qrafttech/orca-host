variable "name" {
  description = "Host name: the VM, its disk, its secret, its name on the tailnet."
  type        = string
}

variable "project" {
  description = "GCP project id."
  type        = string
}

variable "zone" {
  description = "GCP zone."
  type        = string
  default     = "europe-west9-b"
}

variable "machine_type" {
  description = "About 4 GB RAM per Compose stack: e2-standard-4 = 3 stacks and Orca."
  type        = string
  default     = "e2-standard-4"
}

variable "data_disk_gb" {
  description = "The data disk (/home/orca, tailscale identity). About 12 GB per stack. Can only grow."
  type        = number
  default     = 100
}

variable "boot_disk_gb" {
  description = "The boot disk: the OS and the docker images. Replaced with the VM."
  type        = number
  default     = 50
}

variable "ssh_public_key" {
  description = "Your SSH public key, for `ssh core@<name>` over the tailnet."
  type        = string
}

variable "image_tag" {
  description = "Tag of ghcr.io/qrafttech/orca-host to run."
  type        = string
  default     = "main"
}
