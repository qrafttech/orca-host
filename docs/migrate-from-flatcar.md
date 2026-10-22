# A GCP host still on Flatcar, onto Debian

A host brought up before the Debian VM runs Flatcar, configured by Ignition, its 1Password token in Secret Manager. These steps move it onto the Debian VM, from a laptop, the data disk kept. They end live terminals; the GCP host is down from the rebuild to the last step.

1. **This repository up to date**, and application-default credentials that have not expired (`invalid_rapt` from Terraform: `gcloud auth application-default login`).

2. **`make init`**: the Terraform root is now `terraform/gcp/`, a new checkout for Terraform. It records `poseidon/ct`, Ignition's provider, in `terraform/gcp/.terraform.lock.hcl`, because the state still names it: not to commit, `git checkout terraform/gcp/.terraform.lock.hcl` after step 4.

3. **`make secret`, before the rebuild**: the Debian VM reads the token from the data disk, not from Secret Manager.

4. **`make rebuild`**. The plan replaces the VM (the boot image, Flatcar to Debian) and destroys what only Flatcar used: the VM's service account, the Secret Manager secret and its IAM binding, the `iam` and `secretmanager` APIs (dropped from the state, not disabled). The data disk is not in the plan.

5. **Docker's data root, emptied.** The containers Flatcar's Docker left on the data disk do not start under Debian's (`error creating overlay mount … invalid argument`, in the serial console), so the stack does not come up and the host is not on the tailnet. Over IAP, with the host's `name`, `zone` and `project`:

   ```sh
   gcloud compute ssh <name> --zone <zone> --project <project> --tunnel-through-iap \
     --command 'sudo systemctl stop docker.socket docker && sudo rm -rf /var/lib/orca/docker && sudo systemctl restart orca'
   ```

   Gone: Docker's images, containers, volumes and build cache, a project's worktree databases with them, which its setup hook creates again. Kept: `/home/orca`, the Tailscale identity, the pairing.

6. **`make pair`**, if the client does not reconnect on its own.
