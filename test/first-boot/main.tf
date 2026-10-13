# CI only: renders host/first-boot.sh.tftpl with placeholder values, every branch of the template taken (a data
# disk, two templates), so shellcheck reads the script a VM would run. No provider, no state worth keeping.
#   terraform -chdir=test/first-boot init && terraform -chdir=test/first-boot apply -auto-approve
#   terraform -chdir=test/first-boot output -raw script > first-boot.sh
output "script" {
  value = templatefile("${path.module}/../../host/first-boot.sh.tftpl", {
    name        = "orca-host"
    orca_image  = "ghcr.io/qrafttech/orca-host:main"
    ssh_key     = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPlaceholderPlaceholderPlaceholderPlace me@laptop"
    data_device = "/dev/sdb"
    compose     = trimsuffix(file("${path.module}/../../compose.yaml"), "\n")
    env_tpls = {
      "env.tpl"      = "GH_TOKEN={{ op://Vault/github/token }}\nOP_SERVICE_ACCOUNT_TOKEN_ACME={{ op://Vault/acme/credential }}"
      "env.acme.tpl" = "ACME_TOKEN={{ op://Acme/api/token }}"
    }
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
