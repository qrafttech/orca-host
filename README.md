# orca-host

Your own [Orca](https://github.com/stablyai/orca) server in the cloud: a Debian VM on GCP or on an OVH VPS, reached from the Orca desktop and mobile apps over your tailnet. One host per person, all of their projects on it. How it works and why: [`.claude/knowledge/`](.claude/knowledge/).

<img src="docs/architecture.svg" alt="The Orca clients reach the VM over the tailnet; in the VM, a tailscale container carries the address and an orca-host container runs orca serve; project stacks are sibling containers on the VM's Docker; a data disk holds the home, the Tailscale identity, Docker's images and volumes, and the env file, rendered from 1Password at every boot">

## Install

On the laptop: `docker`, `terraform`, `gcloud`, `op` (1Password CLI), `jq`, `ssh`, `qrencode`, the Orca desktop CLI.

1. **Tailscale**, once per tailnet: a tag `orca-host`, owner `autogroup:admin` (admin console → Access controls → Tags).

   <img src="docs/tailscale-tag.png" width="49%" alt="Create tag">

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

   <img src="docs/tailscale-auth-key.png" width="49%" alt="Generate auth key"> <img src="docs/github-token.png" width="49%" alt="Token scopes">

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

<img src="docs/orca-add-project.png" width="49%" alt="Add a project"> <img src="docs/orca-clone-from-url.png" width="49%" alt="Clone from URL">

A project starts itself from its worktree setup hook (`docker compose`, `op inject -i .env.tpl -o .env`). What it starts is at `http://<tailnet IP>:<port>`. A deleted worktree is cleaned up within 5 minutes.

## Day to day

| Command | Does |
|---|---|
| `make restart` | takes your changes now; ends live terminals |
| `make logs` | the host's logs |
| `make shell` | a shell as an Orca terminal sees it |
| `make ssh` | a shell on the VM |
| `make destroy` | GCP: deletes the host for good, disk and state included; asks for its name |

After `make destroy`, a host that was offline stays in Tailscale: remove it in the admin console (Machines), or a new host of that name joins as `<name>-1`.

## When you change something

| You changed | You do |
|---|---|
| this repository, merged to `main` | nothing if the host runs the base image; else merge Dependabot's pull request in yours |
| your own image, merged to its `main` | nothing: the host redeploys within five minutes |
| a token in 1Password, `.env.tpl`, your settings repository | `make restart` |
| `orca_image`, `compose.yaml`, `host/` | `make rebuild` |
| `zone`, to the other of `data_disk_zones` (the zone is out of stock, or down) | `make apply` |
| nothing, but the service-account token expired | a new token in its item, `make secret`, `make restart` |

Each ends live terminals and keeps the data disk: checkouts, pairing, Docker images and volumes.

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
