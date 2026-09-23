# orca-host

A headless [Orca](https://github.com/stablyai/orca) server on a GCP VM, used from the desktop and mobile Orca clients over the tailnet. One host per person, all of their projects on it.

Three layers, each usable without the one above: an image (`Dockerfile`, published as `ghcr.io/qrafttech/orca-host`), a stack (`compose.yaml`, driven by one env file), a host (`terraform/`, a VM on GCP that runs the stack). How it works and why: [`.claude/knowledge/`](.claude/knowledge/).

<img src="docs/architecture.svg" alt="The Orca clients reach the VM over the tailnet; in the VM, a tailscale container carries the address and an orca-host container runs orca serve; project stacks are sibling containers on the VM's Docker; a data disk holds the home, the Tailscale identity, Docker's images and volumes, and the env file, fetched from Secret Manager at every boot">

## What is configured where

| What | Where | Holds |
|---|---|---|
| The host | `terraform/terraform.tfvars` | name, GCP project, zone, SSH public key; size and image tag, optional |
| You | the env file | Tailscale auth key, Claude token, GitHub token, git identity, Claude preferences |
| Your Claude settings | a git repository of yours, optional | permissions, `CLAUDE.md`, skills, MCP servers, binaries |
| A project | its own repository | `orca.yaml`, worktree scripts, `.env` files, compose, `.claude/` |

Nothing in this repository is per person or per project. The first two files are gitignored and come from 1Password: `terraform.tfvars` is the body of a Secure Note named `orca-host-tfvars`, the env file of one named `orca-host`, both in the vault `OP_VAULT` (`Private` by default). `make` fetches a file when it is missing; edit the local copy freely, `rm` it to refetch.

The env file:

```
TS_AUTHKEY=tskey-auth-...                   Tailscale admin console → Settings → Keys: reusable off, ephemeral off, tag orca-host
CLAUDE_CODE_OAUTH_TOKEN=...                 `claude setup-token` on the laptop
GH_TOKEN=...                                classic personal access token, scopes `repo` + `read:org`
GIT_AUTHOR_NAME=...
GIT_AUTHOR_EMAIL=...
CLAUDE_PERMISSION_MODE=auto                 optional, see Claude settings
CLAUDE_SETTINGS_REPO=me/claude              optional, see Claude settings
CLAUDE_SETTINGS_FILE=config/settings.json   optional: where settings.json is in that repository
```

On the host it lives in Secret Manager: `make secret` uploads it from 1Password, the VM fetches it at every boot. On a laptop, `make env` writes it to `./env`.

## Install

Needed on the laptop: `docker`, `terraform`, `gcloud`, `op` (1Password CLI), `jq`, `ssh`, `qrencode`, the Orca desktop CLI.

1. **Once per tailnet**: a tag `orca-host` with owner `autogroup:admin`, in the Tailscale admin console → Access controls → Tags. Tagged nodes never expire.

   <img src="docs/tailscale-tag.png" width="49%" alt="Create tag">

2. **Once per GCP project**: `gcloud auth application-default login` (Terraform's login, separate from `gcloud auth login`), then `make bootstrap` for the state bucket.
3. **The two Secure Notes**: `orca-host-tfvars` is `terraform/terraform.tfvars.example` filled in; `orca-host` is the env file above. Fine-grained GitHub tokens do not work; the organisation must allow classic ones.

   <img src="docs/tailscale-auth-key.png" width="49%" alt="Generate auth key"> <img src="docs/github-token.png" width="49%" alt="Token scopes">

4. **The host**:

   ```bash
   make init      # once per checkout
   make apply     # VPC, service account, secret, data disk, VM
   make secret    # the env file into Secret Manager; the VM picks it up
   make pair      # the desktop client, then the phone
   ```

   `make pair-desktop` registers the server in the desktop app; then Settings → Remote Orca Servers → Advanced → Active Server. `make pair-mobile` shows a QR code to scan from the phone (Tailscale on, same tailnet). Both pairings survive restarts and rebuilds.

## Projects

Add one from the app: Add a project → Clone from URL, the https URL, parent folder `/home/orca` (the repository name is appended). Git authenticates through `gh` with `GH_TOKEN`: no login, no key.

<img src="docs/orca-add-project.png" width="49%" alt="Add a project"> <img src="docs/orca-clone-from-url.png" width="49%" alt="Clone from URL">

Everything a project needs is in its repository and runs from its worktree setup hook: `docker compose` on the VM's Docker, `.env` files, base images. What it starts is reachable at `http://<tailnet IP>:<port>`. Claude Code in a worktree works as on a laptop: the project's own `.claude/` and `CLAUDE.md` apply on top of your settings, hooks run in the container (`ruby`, `python3`, `node` are there), and workspace trust is asked once per project.

## Claude settings

Two optional variables in the env file. Neither set: Claude's defaults.

- `CLAUDE_PERMISSION_MODE`: `default`, `acceptEdits`, `auto` or `plan`, the permission mode of Claude panes.
- `CLAUDE_SETTINGS_REPO`: `<owner>/<repo>`, your Claude settings versioned in git, pulled at every start. What is taken from it:

  | In the repository | On the host |
  |---|---|
  | `permissions` in `CLAUDE_SETTINGS_FILE` (default `settings.json`) | `~/.claude/settings.json`; hooks and status lines are not taken |
  | `CLAUDE.md` at the root | `~/.claude/CLAUDE.md` |
  | `.claude/skills/` | `~/.claude/skills` |
  | `config/mcp.json` | user-level MCP servers |
  | `config/bin.json` | binaries in `~/bin`, checksum-verified |

  Formats: [claude-settings.md](.claude/knowledge/claude-settings.md).

## Day to day

```bash
make restart   # after `make secret`, or for a new image under the same tag; ends live terminals
make logs
make shell     # a shell in the container, as `orca`, the same paths an Orca terminal sees
make ssh       # a shell on the VM, as `core`
```

A change to `compose.yaml` or `terraform/ignition.yaml.tftpl` needs a rebuild: `terraform -chdir=terraform apply -replace=google_compute_instance.vm`. The data disk survives it: checkouts, Tailscale identity, pairing, Docker's images and the volumes of project stacks. Docker is what fills the data disk over time: `docker system prune` from `make shell`, and a worktree's archive script should `docker compose down -v`.

## Develop

Every push builds the image for amd64 and arm64, tagged `<branch>` and `sha-<sha>`; `image_tag` in `terraform.tfvars` picks the one a host runs. On a Mac, `make build` builds `orca-host:dev` and `make up` runs it with Docker Desktop, on the laptop's own tailnet IP.
