# The VM: an OVH VPS, Debian installed by OVH's API with our script run at first boot.
# No `service_name`: Terraform orders one (`plan_code`, `datacenter`), paid with the account's default payment
# method. A `service_name`: the VPS already ordered, imported. Either way Terraform never terminates it
# (`prevent_destroy`): that is done in the control panel, which OVH confirms by email.
# Rebuild: `make rebuild` (apply -replace=terraform_data.install) — Debian is new, /var/lib/orca is kept on
# the additional disk.
import {
  for_each = var.service_name == "" ? [] : [var.service_name]
  to       = ovh_vps.vps
  id       = each.value
}

resource "ovh_vps" "vps" {
  display_name         = var.name
  ovh_subsidiary       = var.ovh_subsidiary
  do_not_send_password = true
  # The order. It installs `image_name` without our script; terraform_data.install reinstalls with it.
  plan = [{
    duration     = "P1M"
    plan_code    = var.plan_code
    pricing_mode = "default"
    configuration = [
      { label = "vps_datacenter", value = var.datacenter },
      { label = "vps_os", value = var.image_name },
    ]
  }]

  lifecycle {
    prevent_destroy = true
    # Order arguments: read at the order only, empty on an imported VPS.
    ignore_changes = [ovh_subsidiary, plan, plan_option, image_id, public_ssh_key, do_not_send_password]
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
        # Compressed: OVH answers a 500 to the script as it is, some 18 kB.
        postInstallScript = "#!/bin/bash\necho '${base64gzip(local.first_boot)}' | base64 -d | gunzip | bash\n"
      })
    }
  }
}
