variable "name" {
  description = "Host name: its name on the tailnet, and the state's prefix."
  type        = string
}

variable "service_name" {
  description = "The VPS, as OVH names it: vps-xxxxxxxx.vps.ovh.net. Ordered beforehand, imported here."
  type        = string
}

variable "state_bucket" {
  description = "The GCS bucket holding the state. Read by the Makefile, for `make init`."
  type        = string
}

variable "op_vault" {
  description = "The 1Password vault the host reads: a technical vault, holding the tokens agents read and no password data. Read by the Makefile, for `make secret`; the VM only ever sees the token."
  type        = string
}

variable "env_tpl" {
  description = "Path to the local .env.tpl, empty for none. Its content goes into the install script, read by the host after the image's /etc/orca-host/env.tpl. References, not values. The Makefile sets it when the file exists."
  type        = string
  default     = ""
}

variable "ssh_public_key" {
  description = "Your SSH public key, for `ssh core@<name>`."
  type        = string
}

variable "orca_image" {
  description = "The image this host runs, a full reference: the published base, or your own image built FROM it to add your tools. A tag moves; `sha-<sha>` or a digest pins."
  type        = string
  default     = "ghcr.io/qrafttech/orca-host:main"
}

variable "image_name" {
  description = "The OS image installed, by its name in `ovhcloud vps image list <service_name>`. Debian only: the install script is."
  type        = string
  default     = "Debian 13"
}

variable "data_device" {
  description = "The VPS's additional disk, for /var/lib/orca: it survives a reinstall. Empty: /var/lib/orca on the root disk, wiped by every reinstall."
  type        = string
  default     = ""
}
