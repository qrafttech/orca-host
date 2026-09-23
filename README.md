# orca-host

A headless [Orca](https://github.com/stablyai/orca) server on a GCP VM, reached from the desktop and mobile Orca clients over the tailnet. One host per person, all of their projects on it. What a project needs on a worktree (`orca.yaml`, scripts, `.env` files, base images) lives in that project's repository, not here.

| Layer | Artifact | Runs on |
|---|---|---|
| Image | `Dockerfile` → `ghcr.io/qrafttech/orca-host` | any Docker host, amd64 and arm64 |
| Stack | `compose.yaml` + one env file | any Linux Docker host with `/dev/net/tun` |
| Host | `terraform/` | GCP |

How it works and why: [`.claude/knowledge/`](.claude/knowledge/).

## Before the first host

On the laptop: `docker`, `terraform`, `gcloud`, `op` (1Password CLI), `jq`, `ssh`, `qrencode`, the Orca desktop CLI.

Once:

- `gcloud auth application-default login`. Terraform's login, separate from `gcloud auth login`.
- A Tailscale tag `orca-host` with owner `autogroup:admin`: admin console → Access controls → Tags ([screenshot](docs/tailscale-tag.png)). Tagged nodes never expire.
- Tailscale on the phone, on the same tailnet.

## Bring up a host

Two 1Password Secure Notes, in the vault `OP_VAULT` (`Private` by default). `make` fetches them when the local file is missing; edit the local copy freely, `rm` it to refetch.

`orca-host-tfvars` is `terraform/terraform.tfvars.example` filled in: name, project, zone, SSH public key.

`orca-host` is the env file:

```
TS_AUTHKEY=tskey-auth-...          admin console → Settings → Keys: reusable off, ephemeral off, tag orca-host
CLAUDE_CODE_OAUTH_TOKEN=...        from `claude setup-token`
GH_TOKEN=...                       classic token, scopes `repo` + `read:org`
GIT_AUTHOR_NAME=...
GIT_AUTHOR_EMAIL=...
CLAUDE_PERMISSION_MODE=auto        optional, see Claude settings
CLAUDE_SETTINGS_REPO=me/claude     optional, see Claude settings
CLAUDE_SETTINGS_FILE=config/settings.json   optional: where settings.json is in that repository
```

Screenshots: [auth key](docs/tailscale-auth-key.png), [token scopes](docs/github-token.png). Fine-grained GitHub tokens do not work; the organisation must allow classic ones.

Then:

```bash
make bootstrap   # once per GCP project: the state bucket
make init        # once per checkout
make apply       # VPC, service account, secret, data disk, VM
make secret      # the env file, from 1Password, into Secret Manager
make pair        # the desktop client, then the phone
```

`make pair-desktop` registers the server in the desktop app; then Settings → Remote Orca Servers → Advanced → Active Server. `make pair-mobile` shows a QR code to scan from the phone. Both pairings survive restarts and rebuilds.

## Use it

Add a project in the app: Set project location → Clone from URL, the https URL, destination `/home/orca`. Git authenticates through `gh` with `GH_TOKEN`: no login, no key. What a worktree's setup hook starts with `docker compose` is reachable at `http://<tailnet IP>:<port>`.

```bash
make restart     # new secret version, or new image under the same tag; ends live terminals
make logs
make shell       # a shell in the container, as `orca`, the same paths an Orca terminal sees
make ssh         # a shell on the VM, as `core`
```

A change to `compose.yaml` or `terraform/ignition.yaml.tftpl` needs a rebuild: `terraform -chdir=terraform apply -replace=google_compute_instance.vm`. The data disk (checkouts, Tailscale identity, pairing) survives it.

## Claude settings

- `CLAUDE_PERMISSION_MODE`: the permission mode of Claude panes (`default`, `acceptEdits`, `auto`, `plan`).
- `CLAUDE_SETTINGS_REPO`: a repository with your Claude settings, pulled at every start. Its `permissions`, root `CLAUDE.md`, `.claude/skills`, `config/mcp.json` and `config/bin.json` are applied. Formats: [claude-settings.md](.claude/knowledge/claude-settings.md).

Neither set: Claude's defaults. Workspace trust stays a question, once per project, as on a laptop.

## Develop

Every push builds the image for amd64 and arm64, tagged `<branch>` and `sha-<sha>`; `image_tag` in `terraform.tfvars` picks the one a host runs. On a Mac, `make build` builds `orca-host:dev` and `make up` runs it with Docker Desktop, on the laptop's own tailnet IP.
