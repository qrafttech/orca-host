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
  description = "The data disk: /home/orca (checkouts, worktrees, ~/.claude), the Tailscale identity, Docker's data root (images, build cache, the volumes of project stacks). Grows live, never shrinks."
  type        = number
  default     = 50
}

variable "boot_disk_gb" {
  description = "The boot disk: Flatcar, nothing else. Replaced with the VM."
  type        = number
  default     = 20
}

variable "ssh_public_key" {
  description = "Your SSH public key, for `ssh core@<name>` over the tailnet."
  type        = string
}

variable "orca_image" {
  description = "The image this host runs, a full reference: the published base, or your own image built FROM it to add your tools. A tag moves; `sha-<sha>` or a digest pins."
  type        = string
  default     = "ghcr.io/qrafttech/orca-host:main"
}
