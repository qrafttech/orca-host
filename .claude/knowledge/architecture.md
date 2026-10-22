# Architecture

A host is three layers, each usable without the one above it:

1. **The image**: Orca, Claude Code and the tools a session needs. Runs on any Docker host.
2. **The stack**, `compose.yaml`: the image plus Tailscale. Runs on any Linux Docker host with `/dev/net/tun`.
3. **The VM**: Debian, brought up by Terraform and turned into a machine running the stack by one script, `host/first-boot.sh.tftpl`. The script is the same on every provider; only the Terraform root differs, `terraform/gcp/` or `terraform/ovh/`.

```
laptop / phone ──tailnet──▶ VM (Debian)
                             ├─ data disk /var/lib/orca, kept across rebuilds
                             │    home/       /home/orca: checkouts, ~/.claude, Orca state
                             │    tailscale/  the node identity: same tailnet IP after a rebuild
                             │    docker/     Docker's data root: images, build cache, project volumes
                             │    env         the env file, rendered from .env.tpl and 1Password
                             │    op-token    the 1Password service-account token
                             └─ the stack
                                  ├─ tailscale   host network, /dev/net/tun
                                  └─ orca-host   host network, `orca serve`, the VM's Docker socket
                                       └─ project stacks, started from Orca terminals, run next to it on the VM's Docker
```

## 1. The image

| Tool | Why it's there |
|---|---|
| `orca serve` | the server; unpacked from Orca's AppImage at build time (no FUSE in a container). Follows Orca's latest release: the apps update themselves and refuse an older server |
| `claude` | the native binary, checksum-verified, auto-updater off: the image is the version |
| `gh`, `git` | `git` authenticates through `gh`, so `GH_TOKEN` is the only GitHub credential |
| Docker CLI, compose, buildx | a project's stack runs on the VM's Docker; buildx so compose labels the images it builds, which the worktree sweep relies on |
| `op` | the host's secrets are 1Password items |
| `ruby`, `python3`, `node` | a project's Claude Code hooks run next to `claude`, not in the project's containers |

Versions are build args at the top of the `Dockerfile`, bumped by Renovate in three pull requests: Orca alone, other minor and patch releases, GitHub Actions. A new Debian major is done by hand, since it renames packages.

At start, the entrypoint gives `orca` the Docker socket and its home, then, as `orca`: seeds Claude's first-run answers, applies the [Claude settings](claude-settings.md), starts the worktree sweep, waits for `tailscale0`, and runs `orca serve`.

CI, on every push: lint, build, a smoke test (the server comes up, Docker works from inside, the sweep works), then the multi-arch image tagged `<branch>` and `sha-<sha>`, plus `main` on `main`.

### Your own image

What is personal goes in one of three places, never in this repository:

- **software** (binaries, MCP servers): the person's own image, `FROM` this one, named in `orca_image`. An image is reproducible, says what is in it, and handles any release format with `RUN`; installing at boot would give none of that. The image must be public: the host does no registry login. To follow the base, Dependabot opens a pull request per base build and `docs/your-image/base-bump.yml` merges it once the image's CI passes; left to a hand, a bump goes stale, since Dependabot never refreshes a waiting one (both digests are the tag `main`).
- **text** (permissions, `CLAUDE.md`, skills, `config/mcp.json`): the settings repository, pulled at every start.
- **configuration**: `.env.tpl`, with secrets as references to 1Password items.

## 2. The stack

`compose.yaml` lists every variable a host takes at the top, all read from one env file. The `orca-host` container also gets the whole file, so a new variable needs no change to compose.

- `tailscale` uses `TS_AUTHKEY` once, on its first start, for a node tagged `orca-host` that never expires.
- `orca-host` mounts `/home/orca` from the data disk at the same path as on the VM, so a project's bind mounts point at the same files, and gets the VM's Docker socket, so project stacks run next to it.

`compose.laptop.yaml` adapts the stack to Docker Desktop on a Mac, for development.

## 3. The VM

**The first-boot script** is everything the VM is, and it is idempotent:

- the user `core` with its SSH key, no password login;
- the data disk mounted at `/var/lib/orca`, formatted only if empty;
- Docker, pinned, with its data root on the data disk (the graph-driver store, so images don't land on the boot disk);
- a firewall: only the tailnet, Tailscale's UDP port and SSH (until `make lockdown`) come in, and nothing from the internet reaches a container;
- three units: `orca-env` renders the env file, `orca` pulls the image and starts the stack, `orca-update.timer` restarts `orca` every five minutes.

**The disks.** The boot disk (Debian, Docker, `/opt/orca`) goes with the VM. The data disk stays: checkouts, Orca and Claude state, the Tailscale identity, Docker's images and volumes.

**Terraform state.** One per host, in a Google Cloud Storage bucket whatever the provider, under `orca-host/<name>`. `plan`, `apply` and `rebuild` run `make init` first, so they always act on the host `TFVARS` names.

## 4. Secrets

One file, one token, one vault. `make secret` writes a 1Password service-account token to `/var/lib/orca/op-token` over SSH, so no secret goes through Terraform. The token reads one vault, read-only.

At every start, `orca-env` renders the env file from the templates (the image's `/etc/orca-host/env*.tpl`, then the laptop's), resolving every `{{ op://… }}`. If one fails, the stack stays down rather than start on part of its environment.

- **Several accounts**: another account's token is a line `OP_SERVICE_ACCOUNT_TOKEN_<NAME>` of `.env.tpl`, and its secrets go in `.env.<name>.tpl`.
- **Rotation**: a token changed in 1Password reaches the host with `make restart`. When the service-account token expires: a new one in its item, `make secret`, `make restart`.
- **Sessions** get `OP_SERVICE_ACCOUNT_TOKEN` too, so a project's setup hook can run `op inject`. That's why the vault holds technical tokens only, no passwords. In `auto` mode, Claude needs an allow rule for `op` in the settings repository.

## 5. Providers

| | Google Cloud | OVH |
|---|---|---|
| The machine | a VM; the script runs as its `startup-script`, at every boot, and stops early once applied | a VPS, ordered or imported by `ovh_vps`; the script runs once after a reinstall (`postInstallScript`), gzipped because OVH refuses it raw, sent by `ovhcloud` since the provider can't |
| The data disk | regional, in two zones: a zone out of stock is a new `zone` and a `make apply`. A snapshot a day, 7 kept | the VPS's additional disk if there is one (`data_device`); without one, a reinstall wipes everything |
| Getting in | its own VPC, nothing open; SSH over the tailnet, or IAP as a break-glass | SSH on the public address until `make lockdown`; OVH's KVM console as a break-glass |
| Deleting it | `make destroy`: VM, disk, snapshots and state | cancelled in OVH's control panel; Terraform never cancels a VPS |
| Size and cost | `e2-standard-4` by default (4 vCPU, 16 GB, about three project stacks): about $135 a month, $160 with `n2d-standard-4` | about €10 (VPS-3) to €20 (VPS-4) a month excl. VAT, one-year commitment |

## 6. How a change reaches the host

- **By itself**: every five minutes the host pulls the image tag it follows; compose recreates the container only if the image changed. This closes open terminals. A host pinned to a `sha-` tag never moves.
- **`make restart`**: copies the laptop's templates, renders the env file again, restarts the container (which pulls the settings repository again).
- **`make rebuild`**: a new Debian from the first-boot script, the data disk kept. Needed after a change to `compose.yaml` or `host/`.

## 7. Details

- **Deleted worktrees.** Every five minutes, `prune-stacks` takes down every compose project whose directory under `/home/orca` is gone, with its volumes and the images it built, then caps the build cache at 10 GB. A stack brought down without `-v` before its worktree is deleted can't be found, so its volumes stay. A project's containers must not write into the worktree as root, or Orca can't delete it.
- **Pairing.** `orca serve` prints one pairing link per run. `make pair-desktop` hands it to `orca environment add` on the laptop; `make pair-mobile` restarts the server in mobile mode, shows its link as a QR code, then restarts it back. Pairings survive rebuilds.
- **GitHub token.** A classic token with `repo` and `read:org`: fine-grained ones can't read GHCR, and the mobile app needs `read:org` to list repositories.
- **Host keys.** Each rebuild brings a new one; the Makefile skips the check, since the tailnet already authenticates the machine.
- **Workspace trust.** Claude asks once per project, as on a laptop; it can't be granted from a parent folder.
