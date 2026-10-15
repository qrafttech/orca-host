variable "name" {
  description = "Host name: its name on the tailnet, and the state's prefix."
  type        = string
}

variable "service_name" {
  description = "A VPS already ordered, as OVH names it: vps-xxxxxxxx.vps.ovh.net, imported. Empty: Terraform orders one."
  type        = string
  default     = ""
}

variable "plan_code" {
  description = "The VPS model ordered when `service_name` is empty, by its plan code in OVH's catalog (/order/catalog/public/vps)."
  type        = string
  default     = "vps-2027-model2"
}

variable "datacenter" {
  description = "Where the VPS ordered runs: a `vps_datacenter` value of OVH's catalog (GRA, SBG, EU-WEST-RBX, EU-SOUTH-MIL...)."
  type        = string
  default     = "GRA"
}

variable "ovh_subsidiary" {
  description = "The OVH entity the order is billed by."
  type        = string
  default     = "FR"
}

variable "state_bucket" {
  description = "The GCS bucket holding the state. Read by the Makefile, for `make init`."
  type        = string
}

variable "op_vault" {
  description = "The 1Password vault the host reads: a technical vault, holding the tokens agents read and no password data. Read by the Makefile, for `make secret`; the VM only ever sees the token."
  type        = string
}

variable "env_tpls" {
  description = "The local templates, by their name on the host (env.tpl, env.<name>.tpl) to their path; empty for none. Their content goes into the first-boot script, read by the host after the image's /etc/orca-host/env*.tpl, so a variable set in both takes the local value. References, not values: the OVH reinstall request and the state may carry them. The Makefile sets it from ENV_TPL and the files next to it."
  type        = map(string)
  default     = {}
  validation {
    condition     = alltrue([for k in keys(var.env_tpls) : can(regex("^env(\\.[a-z0-9_]+)?\\.tpl$", k))])
    error_message = "env_tpls keys are env.tpl or env.<name>.tpl, <name> in lowercase letters, digits and _."
  }
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
