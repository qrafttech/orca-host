# orca-host

Your own [Orca](https://github.com/stablyai/orca) server in the cloud: a Debian VM on GCP or on an OVH VPS, reached from the Orca desktop and mobile apps over your tailnet. One host per person, all of their projects on it. How it works and why: [`.claude/knowledge/`](.claude/knowledge/).

<img src="docs/architecture.svg" alt="The Orca clients reach the VM over the tailnet; in the VM, a tailscale container carries the address and an orca-host container runs orca serve; project stacks are sibling containers on the VM's Docker; a data disk holds the home, the Tailscale identity, Docker's images and volumes, and the env file, rendered from 1Password at every boot">

## Install

On the laptop: `docker`, `terraform`, `gcloud`, `op` (1Password CLI), `jq`, `ssh`, `qrencode`, the Orca desktop CLI.

1. **Tailscale**, once per tailnet: a tag `orca-host`, owner `autogroup:admin` (admin console → Access controls → Tags).
2. **1Password**, once: a vault for the host, with the tokens your agents use and no passwords. A service account on it, read-only; its token in an item `orca-host-op-token` of that vault.
3. **Google Cloud**, once per project: `gcloud auth application-default login`, then `make bootstrap` (the bucket that keeps Terraform's state).
4. **Two files of yours**, no secret in either. Keep them in a repository of yours and tell `make` where they are:

   ```sh
   export TFVARS=~/my-repo/orca-host/gcp.tfvars   # from terraform/gcp/terraform.tfvars.example
   export ENV_TPL=~/my-repo/orca-host/.env.tpl
   ```

   `.env.tpl`, one `VAR=value` per line, a secret as a reference to an item of the vault:

   ```sh
   # Tailscale → Settings → Keys: not reusable, not ephemeral, tag orca-host. One key per new host
   TS_AUTHKEY={{ op://Vault/tailscale/authkey }}
   # `claude setup-token`
   CLAUDE_CODE_OAUTH_TOKEN={{ op://Vault/claude/token }}
   # a classic token, scopes repo + read:org
   GH_TOKEN={{ op://Vault/github/token }}
   GIT_AUTHOR_NAME=...
   GIT_AUTHOR_EMAIL=...
   # optional: anything else reaches every session as is
   FOO_TOKEN={{ op://Vault/foo/token }}
   ```

5. **The host**:

   ```sh
   make apply     # creates the VM and its data disk; answer yes
   make secret    # a minute later: gives the host its 1Password token
   make pair      # connects the desktop app, then the phone
   ```

   In the desktop app: Settings → Remote Orca Servers → Advanced → Active Server. A terminal that opens is a host that works.

## On an OVH VPS

The same steps, with `export PROVIDER=ovh` and a `TFVARS` from `terraform/ovh/terraform.tfvars.example`. Terraform runs from an image: no `terraform` needed. Step 3 still applies, for the state bucket.

- **OVH API credentials**: [createtoken](https://eu.api.ovh.com/createToken/?GET=/vps/*&POST=/vps/*&PUT=/vps/*&POST=/order/cart*&GET=/me/payment/method&GET=/me/order*&POST=/me/order*), as an item `ovh-api` of the vault: fields `endpoint` (`ovh-eu`), `application_key`, `application_secret`, `consumer_key`.
- **The VPS**: `make apply` orders one, paid with the account's default method; or takes one already ordered, its `service_name` in the tfvars. The first `make apply` reinstalls it: what was on it goes.
- **After `make pair`**: `make lockdown`, so SSH answers on the tailnet only.

## Projects

In the app: Add a project → Clone from URL, the https URL, parent folder `/home/orca`.

A project starts itself from its worktree setup hook (`docker compose`, `op inject -i .env.tpl -o .env`). What it starts is at `http://<tailnet IP>:<port>`. A deleted worktree is cleaned up within 5 minutes.

## Day to day

| To | Run |
|---|---|
| take a change of `.env.tpl`, a token in 1Password, your settings repository | `make restart` |
| take a change of `orca_image`, `compose.yaml` or `host/` | `make rebuild` |
| renew the 1Password token, once expired | a new token in its item, then `make secret` and `make restart` |
| move to the disk's other zone, when the VM's is out of stock (GCP) | the other of `data_disk_zones` as `zone`, then `make apply` |
| read the host's logs | `make logs` |
| open a shell, as an Orca terminal sees it / on the VM | `make shell` / `make ssh` |
| delete the host for good, disk and state included (GCP) | `make destroy`; it asks for the name |

A merge here, or to your own image, reaches the host by itself within five minutes. `restart` and `rebuild` end live terminals and keep the data disk: checkouts, pairing, Docker images and volumes. After `make destroy`, a host that was offline stays in Tailscale: remove it in the admin console (Machines), or a new host of that name joins as `<name>-1`.

## When a command fails

| Message | What to do |
|---|---|
| `invalid_grant` … `invalid_rapt` | `gcloud auth application-default login`, then again |
| `Reauthentication required` | your password at the prompt; a command it stopped, run again |
| `Failed to lookup instance` (`make secret`) | the VM is still booting: a minute later, again |
| `no name in …` | `export TFVARS=<your file>` |

## Going further

### Claude settings

Two optional lines in `.env.tpl`: `CLAUDE_PERMISSION_MODE` (`default`, `acceptEdits`, `auto`, `plan`), and `CLAUDE_SETTINGS_REPO=<owner>/<repo>`, whose `permissions`, `CLAUDE.md`, `.claude/skills/` and `config/mcp.json` are applied at every start. Details: [claude-settings.md](.claude/knowledge/claude-settings.md).

### Several 1Password accounts

One service account reads one vault. For a vault in another account: a service account there, its token in the host's vault, and a second template next to `.env.tpl`:

```sh
# .env.tpl
OP_SERVICE_ACCOUNT_TOKEN_ACME={{ op://Vault/acme-op-token/credential }}

# .env.acme.tpl, resolved with that token
ACME_API_TOKEN={{ op://Acme Vault/api/credential }}
```

A file that does not resolve keeps the host down. Every token reaches the sessions, so each vault stays technical and read-only.

### Your own tools

An image of yours, `FROM` this one, built by your CI, public:

```dockerfile
FROM ghcr.io/qrafttech/orca-host:main@sha256:<digest>
RUN curl -fsSL -o /tmp/x "<url>" && echo "<sha256>  /tmp/x" | sha256sum -c - \
 && install -m 755 /tmp/x /usr/local/bin/<tool> && rm /tmp/x
# optional: your templates travel with the image; the laptop's win over them
COPY .env.tpl /etc/orca-host/env.tpl
```

Then `orca_image = "ghcr.io/me/orca-host:main"` in your tfvars and `make rebuild`, once. Dependabot (`package-ecosystem: docker`) keeps the `FROM` up to date.

## Develop

Every push builds the image, tagged `<branch>` and `sha-<sha>`. On a Mac: `make build`, then `make up` runs it with Docker Desktop on the laptop's tailnet IP.
