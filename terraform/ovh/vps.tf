# The VM: an OVH VPS, ordered beforehand, Debian installed by OVH's API with our script run at first boot.
# Terraform does not order it (`import`) and never terminates it (`prevent_destroy`): what it manages is the install.
# Rebuild: `make rebuild` (apply -replace=terraform_data.install) — Debian is new, /var/lib/orca is kept on
# the additional disk.
import {
  to = ovh_vps.vps
  id = var.service_name
}

resource "ovh_vps" "vps" {
  display_name = var.name
  # Order arguments, required by the schema, empty on an imported VPS: never sent.
  ovh_subsidiary = "FR"
  plan           = []

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [ovh_subsidiary, plan, plan_option, image_id, public_ssh_key, do_not_send_password]
  }
}

data "ovh_vps" "vps" {
  service_name = ovh_vps.vps.service_name
}

locals {
  first_boot = templatefile("${path.module}/../../host/first-boot.sh.tftpl", {
    name        = var.name
    orca_image  = var.orca_image
    ssh_key     = var.ssh_public_key
    data_device = var.data_device
    compose     = trimsuffix(file("${path.module}/../../compose.yaml"), "\n")
    env_tpls    = { for k, f in var.env_tpls : k => trimsuffix(file(f), "\n") }
    scripts = merge(
      { for f in ["render-env", "up", "firewall"] : f => trimsuffix(file("${path.module}/../../host/${f}"), "\n") },
      { inject-env = trimsuffix(file("${path.module}/../../inject-env.sh"), "\n") },
    )
    units = {
      for f in ["orca-env.service", "orca.service", "orca-update.service", "orca-update.timer"] :
      f => trimsuffix(file("${path.module}/../../host/${f}"), "\n")
    }
  })
}

# The install. OVH's API takes the script (`postInstallScript` on /vps/{service}/rebuild), the provider does not:
# the CLI sends it. Created once; replaced, i.e. reinstalled, when the image or the key changes, or on
# `make rebuild`. A change of the script alone is stored, not applied: a reinstall stays a choice.
resource "terraform_data" "install" {
  triggers_replace = [ovh_vps.vps.service_name, var.image_name, var.ssh_public_key]
  input            = local.first_boot

  provisioner "local-exec" {
    interpreter = ["/bin/sh", "-ec"]
    command     = <<-EOT
      id=$(ovhcloud vps image list "$SERVICE" -o json | jq -r --arg n "$IMAGE" 'map(select(.name == $n))[0].id // empty')
      [ -n "$id" ] || { echo "no image named '$IMAGE' for $SERVICE: ovhcloud vps image list $SERVICE"; exit 1; }
      body=$(mktemp)
      printf '%s' "$BODY" | jq --arg id "$id" '.imageId = $id' > "$body"
      ovhcloud vps reinstall "$SERVICE" --from-file "$body" --wait
      rm -f "$body"
    EOT
    environment = {
      SERVICE = ovh_vps.vps.service_name
      IMAGE   = var.image_name
      BODY = jsonencode({
        publicSshKey      = var.ssh_public_key
        postInstallScript = local.first_boot
      })
    }
  }
}
