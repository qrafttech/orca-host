# orca-host

Your own [Orca](https://github.com/stablyai/orca) server in the cloud. It runs on a Debian VM, on Google Cloud or on an OVH VPS, and you use it from the Orca desktop and mobile apps over your tailnet. Each person gets one host and puts all of their projects on it. If you want to know how it works and why, read [`.claude/knowledge/`](.claude/knowledge/).

<img src="docs/architecture.svg" alt="The Orca clients reach the VM over the tailnet; in the VM, a tailscale container carries the address and an orca-host container runs orca serve; project stacks are sibling containers on the VM's Docker; a data disk holds the home, the Tailscale identity, Docker's images and volumes, and the env file, rendered from 1Password at every boot">

## Install

You need these on your laptop: `terraform`, `gcloud`, `op` (the 1Password CLI), `jq`, `ssh`, `qrencode` and the Orca desktop CLI, plus the [OVH CLI](https://github.com/ovh/ovhcloud-cli) (`ovhcloud`) for an OVH host.

1. **Tailscale** (once per tailnet). In the admin console, go to Access controls → Tags and create a tag called `orca-host`, owned by `autogroup:admin`.
2. **1Password** (once). Create a vault for the host. Put in it the tokens your agents need, and no passwords. Then create a read-only service account on that vault, and save its token in the same vault, in an item called `orca-host-op-token`.
3. **A bucket for Terraform's state** (once). Whatever the provider, Terraform keeps track of your hosts in a Google Cloud Storage bucket. Log in with `gcloud auth application-default login`, then run `make bootstrap`.
4. **Your provider.** Pick one, and do what it needs:

   | | Google Cloud | OVH |
   |---|---|---|
   | `PROVIDER` | `gcp` (the default) | `ovh` |
   | your tfvars, from | `terraform/gcp/terraform.tfvars.example` | `terraform/ovh/terraform.tfvars.example` |
   | the machine | a VM, created by `make apply` | a VPS: `make apply` orders one with your default payment method, or takes the one whose `service_name` you put in your tfvars. The first `make apply` reinstalls it, so anything on it is lost |
   | credentials | the `gcloud` login from step 3 | an API token from [this page](https://eu.api.ovh.com/createToken/?GET=/vps/*&POST=/vps/*&PUT=/vps/*&POST=/order/cart*&GET=/me/payment/method&GET=/me/order*&POST=/me/order*) (rights already filled in), saved in the vault as an item `ovh-api` with the fields `endpoint` (`ovh-eu`), `application_key`, `application_secret` and `consumer_key` |

5. **Your two config files.** Neither holds a secret, so you can keep them in a git repository of your own. Tell `make` where they are, and which provider you use:

   ```sh
   export PROVIDER=gcp                              # or ovh
   export TFVARS=~/my-repo/orca-host/gcp.tfvars     # your tfvars, from step 4
   export ENV_TPL=~/my-repo/orca-host/.env.tpl
   ```

   `.env.tpl` lists the variables your host starts with, one per line. A secret is never written there: you point to the 1Password item that holds it.

   ```sh
   # Tailscale → Settings → Keys: not reusable, not ephemeral, tag orca-host. A new key for each new host
   TS_AUTHKEY={{ op://Vault/tailscale/authkey }}
   # from `claude setup-token`
   CLAUDE_CODE_OAUTH_TOKEN={{ op://Vault/claude/token }}
   # a classic GitHub token, with the repo and read:org scopes
   GH_TOKEN={{ op://Vault/github/token }}
   GIT_AUTHOR_NAME=...
   GIT_AUTHOR_EMAIL=...
   # anything else you add here shows up in every session
   FOO_TOKEN={{ op://Vault/foo/token }}
   ```

6. **The host itself.**

   ```sh
   make apply     # creates the machine and its disk; type yes when asked
   make secret    # wait a minute first: this gives the host its 1Password token
   make pair      # connects your desktop app, then your phone
   make lockdown  # OVH only: from now on, SSH only answers over the tailnet
   ```

   Then, in the desktop app, open Settings → Remote Orca Servers → Advanced → Active Server and pick your host. If you can open a terminal, it works.

## Projects

In the app, click Add a project → Clone from URL, paste the https URL, and choose `/home/orca` as the parent folder.

Each project starts itself from its worktree setup hook (`docker compose`, `op inject -i .env.tpl -o .env`, and so on). Whatever it runs is at `http://<tailnet IP>:<port>`. When you delete a worktree, the host cleans up after it within five minutes.

## Day to day

| You want to | Run |
|---|---|
| apply a change to `.env.tpl`, a token in 1Password or your settings repository | `make restart` |
| apply a change to `orca_image`, `compose.yaml` or `host/` | `make rebuild` |
| renew the 1Password token once it has expired | put a new token in its item, then `make secret` and `make restart` |
| move to the disk's other zone when the VM's zone is out of stock (Google Cloud) | set `zone` to the other value of `data_disk_zones`, then `make apply` |
| read the host's logs | `make logs` |
| open a shell, as an Orca terminal sees it, or on the VM | `make shell`, or `make ssh` |
| delete the host for good, with its disk and its state | Google Cloud: `make destroy`, which asks you to type the name. OVH: cancel the VPS in the OVH control panel |

You don't need to do anything when a change is merged here or into your own image: the host picks it up by itself within five minutes. `restart` and `rebuild` close the terminals you have open, but they never touch the data disk, so your checkouts, your pairing and your Docker images and volumes stay.

If the host was offline when you ran `make destroy`, it is still listed in Tailscale. Remove it from the admin console (Machines), otherwise a new host with the same name will show up as `<name>-1`.

## When a command fails

| You see | Do this |
|---|---|
| `invalid_grant` … `invalid_rapt` | log in again with `gcloud auth application-default login`, then rerun the command |
| `Reauthentication required` | type your Google password at the prompt; if the command stopped, run it again |
| `Failed to lookup instance` (`make secret`) | the VM is still booting: wait a minute and try again |
| `no name in …` | `make` can't find your tfvars: `export TFVARS=<your file>` |

## Going further

### Claude settings

You can add two optional lines to `.env.tpl`. `CLAUDE_PERMISSION_MODE` sets the permission mode of Claude panes (`default`, `acceptEdits`, `auto` or `plan`). `CLAUDE_SETTINGS_REPO=<owner>/<repo>` points to a repository of yours: its `permissions`, `CLAUDE.md`, `.claude/skills/` and `config/mcp.json` are applied every time the host starts. More in [claude-settings.md](.claude/knowledge/claude-settings.md).

### Several 1Password accounts

A service account can only read one vault. If some of your secrets live in another 1Password account, create a service account there too, save its token in the host's vault, and add a second file next to `.env.tpl`:

```sh
# .env.tpl
OP_SERVICE_ACCOUNT_TOKEN_ACME={{ op://Vault/acme-op-token/credential }}

# .env.acme.tpl, read with that token
ACME_API_TOKEN={{ op://Acme Vault/api/credential }}
```

If one of these files can't be read, the host won't start. Every session can see these tokens, so keep those vaults for technical tokens only, and read-only.

### Your own tools

To add your own tools, build your own image on top of this one, with your own CI, and publish it publicly:

```dockerfile
FROM ghcr.io/qrafttech/orca-host:main@sha256:<digest>
RUN curl -fsSL -o /tmp/x "<url>" && echo "<sha256>  /tmp/x" | sha256sum -c - \
 && install -m 755 /tmp/x /usr/local/bin/<tool> && rm /tmp/x
# optional: ship your templates with the image (the ones on your laptop still win)
COPY .env.tpl /etc/orca-host/env.tpl
```

Then set `orca_image = "ghcr.io/me/orca-host:main"` in your tfvars and run `make rebuild` once. Turn on Dependabot for Docker (`package-ecosystem: docker`) in that repository to keep the `FROM` line up to date.

## Develop

Every push builds the image, tagged `<branch>` and `sha-<sha>`.

To try a change on your Mac, you also need Docker Desktop. Run `make build`, then `make up`: the host runs on your laptop, on its tailnet IP.
