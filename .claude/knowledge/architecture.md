# Architecture

Three layers, each usable without the one above: an **image** that runs on any Docker host, a **stack** (`compose.yaml`) that runs on any Linux Docker host with `/dev/net/tun`, and a **host**: a Debian VM that Terraform brings up and one script, `host/first-boot.sh.tftpl`, turns into a machine running the stack. The script is the same on every provider; only the Terraform root differs, `terraform/gcp/` or `terraform/ovh/`, picked by `PROVIDER`.

```
laptop / phone ──tailnet──▶ VM (Debian, host/first-boot.sh.tftpl)
                             ├─ data disk  /var/lib/orca, kept across rebuilds
                             │    home/       /home/orca: checkouts, ~/.claude, Orca state
                             │    tailscale/  the node identity: same tailnet IP after a rebuild
                             │    docker/     Docker's data root: images, build cache, project volumes
                             │    env         the env file, rendered from .env.tpl and 1Password
                             │    op-token    the 1Password service-account token
                             └─ compose.yaml
                                  ├─ tailscale   host network, /dev/net/tun
                                  └─ orca-host   host network, `orca serve`, the VM's Docker socket
```

## What runs where

| | Runs | Installed |
|---|---|---|
| The VM | Docker, the `tailscale` and `orca-host` containers, and at each boot a short-lived `op` container that renders the env file | nothing else |
| The `orca-host` container | `orca serve`, every Claude pane and Orca terminal, a project's Claude Code hooks, the worktree sweep | `claude`, `gh`, `git`, the Docker CLI, `op`, `ruby`, `python3`, `node` |
| A project's containers | the app, its database, its cache | the app's own runtime, from the project's compose file |

`orca-host` has the VM's Docker socket, so a `docker compose up` from an Orca terminal starts the project's containers on the VM, next to `orca-host` rather than inside it. `/home/orca` is the same path on both sides (a symlink to `/var/lib/orca/home` on the VM, a bind mount in the container), so a project's `./:/app` bind mount points at the same files.

## The image

- **Orca**: `orca serve` from the official AppImage, unpacked at build time (no FUSE in a container, and QEMU cannot run an AppImage for the arm64 build). It follows Orca's latest release: the apps update themselves, and the mobile app refuses a server older than its protocol.
- **Claude Code**: the native binary, checksum-verified. The auto-updater is off: the image is the version.
- **`gh`, `git`, the Docker CLI** with compose and buildx. Without buildx, compose falls back to the classic builder, which keeps no cache and doesn't label images with their project, the label the worktree sweep relies on. `git` authenticates through `gh`, so `GH_TOKEN` is the only GitHub credential.
- **`op`**, the 1Password CLI: the host's secrets are 1Password items, so it is infrastructure, like `gh`.
- **`ruby`, `python3`, `node`**, for a project's Claude Code hooks, which run next to `claude` and not in the project's containers.

Versions are build args at the top of the `Dockerfile`, bumped by Renovate, one pull request per release. Nothing else is in the image: a person's own tools go in their own image.

At start, the entrypoint gives `orca` the Docker socket's group and its home, then, as `orca`: seeds Claude's first-run answers in `~/.claude.json`, applies the Claude settings ([claude-settings.md](claude-settings.md)), starts the worktree sweep, waits for `tailscale0`, and runs `orca serve --port 6768 --pairing-address <tailnet IP> --json`.

### Your own image

Three kinds of personal things, three places:

- **software** (binaries, MCP servers): an image of the person's own, `FROM` this one, built by their CI, named in `orca_image`;
- **text** (permissions, `CLAUDE.md`, skills, `config/mcp.json`): the settings repository, pulled at every start, so a permission needs no rebuild;
- **configuration**: `.env.tpl`, versioned, with secrets as references to 1Password items.

Why an image rather than installing tools when the host starts: an image built from a pinned base is the same wherever it runs, `docker history` says what is in it, versions are fixed at build time, and `RUN` handles any release format. The cost is a rebuild for a new tool, and an image that goes stale when the base moves; Dependabot on a digest-pinned `FROM` turns that into a pull request. The image must be public: the host does no registry login.

### CI

On every push: lint (hadolint, shellcheck, `terraform fmt` and `validate`, the rendered first-boot script, the firewall rules), build, a smoke test (the server reports ready, Docker works from inside, the worktree sweep removes a stack whose directory is gone), then push the multi-arch image tagged `<branch>` and `sha-<sha>`, plus `main` on `main`. A host or a derived image pins a build with its `sha-` tag or a digest.

## The stack

`compose.yaml` is the contract of a host: every personal value is a variable listed at the top, read from one env file. Compose reads the file for the variables it names, and the `orca-host` container gets all of it (`env_file`), so a new variable needs no change to the compose file.

- `tailscale`: host network, `NET_ADMIN`, `/dev/net/tun`. `TS_AUTHKEY` is used once, on the first start, for a node tagged `orca-host`, which never expires. The identity then lives in `tailscale/` on the data disk.
- `orca-host`: host network, `/home/orca` from the data disk, the Docker socket.

On a Mac, `compose.laptop.yaml` adapts it to Docker Desktop, which has no `/dev/net/tun`, no host network, and no unix sockets in bind mounts: the laptop's own Tailscale is the node, port 6768 is published, and the home is a named volume.

## The host

**Terraform state.** One state per host, in a Google Cloud Storage bucket of the person's project, whatever the provider: `make bootstrap` creates the bucket, and each host has its prefix, `orca-host/<name>`. `plan`, `apply` and `rebuild` run `make init` first, against the host `TFVARS` names, so they never act on another host's state. Terraform reads the bucket with application-default credentials, or gcloud's access token when there are none.

**The first-boot script** is everything the VM is. Terraform renders it from `compose.yaml` and `host/`. It is idempotent, and it does:

- the user `core`, its SSH key, sudo and Docker; no password login;
- the data disk, formatted only if empty, mounted at `/var/lib/orca`, with `/home/orca` pointing into it;
- Docker from Docker's apt repository, versions pinned and held (bumped by hand); Debian's own packages update unattended;
- Docker's data root on the data disk, using the graph-driver store, not containerd's, whose images would sit on the boot disk;
- `/opt/orca`: the compose file, the scripts, the host's name and image, and the laptop's templates if there are any;
- a firewall (nftables, in its own table beside Docker's): in, only the tailnet, Docker's bridges, ICMP, DHCP, Tailscale's UDP port and SSH (until `make lockdown`); no new connection from the internet reaches a container, so a project's `ports:` stay on the tailnet;
- three units: `orca-env` renders the env file, `orca` pulls the image and runs the stack, `orca-update.timer` restarts `orca` every five minutes.

**Disks.** The boot disk holds Debian, Docker and `/opt/orca`, and goes with the VM. The data disk holds everything under `/var/lib/orca` and stays: checkouts, Orca and Claude state, the Tailscale identity, Docker's images and volumes. A project's database in a Docker volume is still a worktree database: its setup hook creates it, its archive script removes it. `docker system df` from `make shell` says what fills the disk.

## Secrets

The chain is one file, one token, one vault. `/var/lib/orca/op-token` holds a 1Password service-account token, read-only on one vault, written by `make secret` over SSH so that no secret goes through Terraform. The first time, the host isn't on the tailnet yet (it joins with a key it reads using that very token), so `make secret` goes through IAP on Google Cloud, or the public address on OVH.

At every start, `orca-env` renders the env file from the templates, the image's `/etc/orca-host/env*.tpl` first, then the laptop's (`/opt/orca/env*.tpl`), the last value of a variable winning, every `{{ op://… }}` resolved by `op inject`. A template that fails to resolve keeps the stack down rather than starting it on part of its environment; the serial console says why. `make restart` copies the laptop's templates again first, so a new line needs no rebuild.

**Several 1Password accounts.** A service account reads one vault of one account. For another account: a service account there, its token as a line `OP_SERVICE_ACCOUNT_TOKEN_<NAME>` of `.env.tpl`, and a template `.env.<name>.tpl` resolved with it. The file name is the whole declaration.

**Rotation.** A token changed in 1Password reaches the host with `make restart`. The service-account token itself expires: a new one in its item, then `make secret` and `make restart`.

**In the sessions.** The env file also carries `OP_SERVICE_ACCOUNT_TOKEN`, so a session's `op` reads the same vault, and a project's setup hook can run `op inject -i .env.tpl -o .env` with nothing to do on a laptop. Every session can read that vault: that's why it holds technical tokens only, read-only, with no passwords. The same file already gives every session `GH_TOKEN` and `CLAUDE_CODE_OAUTH_TOKEN`. In `auto` mode, Claude Code's classifier refuses `op` unless the settings repository allows it.

## Deleted worktrees

Orca deletes a worktree without telling the host, and what it started stays behind. Every five minutes, `prune-stacks` in the `orca-host` container takes down every compose project whose directory under `/home/orca` no longer exists, with its volumes and the images compose built for it (`down -v --rmi local`, found by compose's own labels; a pulled `postgres` image stays). Then it caps Docker's build cache at 10 GB, oldest first.

Not covered: a stack brought down without `-v` before its worktree is deleted leaves no container to find it by, so its volumes stay (that's the project's archive script's job), and an image built by hand stays. Orca's own trash fails on files `orca` doesn't own: a project's containers must not write into the worktree as root.

## On Google Cloud

- **The VM** runs the first-boot script as its `startup-script`, at every boot; the script stops at its first lines when it has already applied itself. `machine_type` defaults to `e2-standard-4` (4 vCPU, 16 GB: about 4 GB per project stack, so three stacks and Orca). E2, N2 or N2D only: a regional disk attaches to no other series.
- **The data disk** is regional, copied in the two `data_disk_zones`, so when the VM's zone runs out of machines, the VM moves to the other zone with a `make apply` and the disk stays. A snapshot a day, 7 kept. It is `prevent_destroy`: only `make destroy` deletes it.
- **Network**: its own VPC; nothing reaches the VM from the internet. SSH goes over the tailnet, or through IAP as a break-glass (`gcloud compute ssh <name> --tunnel-through-iap`, with OS Login). The serial console shows the boot log and both units' output.
- **`make destroy`** deletes the VM, the disk, its snapshots and the host's state, after asking for the name.
- **Cost**, at list prices in Paris: about $135 a month on the defaults (the VM about $113, the regional disk $13, the rest a few dollars), about $160 with an `n2d-standard-4`. A one-year commitment takes about 40% off the VM. The billed amounts: the console, Billing → Reports, filtered on the project.

## On OVH

- **The VPS** is `ovh_vps`. Without `service_name`, `make apply` orders one (`plan_code`, `datacenter`), paid with the account's default method; with it, it imports the one already ordered. Terraform never cancels or replaces a VPS (`prevent_destroy`): cancelling is in the control panel.
- **The install.** A VPS takes no custom image, but `POST /vps/{service}/rebuild` runs a script once after a reinstall (`postInstallScript`): that's the first-boot script, gzipped and base64-encoded, since OVH answers a 500 to it raw. The `ovh` provider can't pass that script, so `terraform_data.install` calls `ovhcloud vps reinstall`. It reinstalls the VPS when the image or the SSH key changes, or on `make rebuild`; a change to the script alone waits for a rebuild.
- **Tools**: Terraform and `ovhcloud` run on the laptop; `op run` gives them the `ovh-api` item from 1Password.
- **SSH** answers on the public address until `make lockdown`, then on the tailnet only; OVH's KVM console is the break-glass.
- **Disk**: with an additional disk (`data_device`), `/var/lib/orca` survives a reinstall. Without one, it's on the root disk and a reinstall wipes it, pairing included.

## How a change reaches the host

- **Redeploy**, on its own: every five minutes the host pulls the image tag it follows, and compose recreates the container only if the image changed. A merge to `main` reaches every host on the base image without anyone doing anything, and closes their open terminals. A host pinned to a `sha-` tag never moves.
- **`make restart`**: copies the laptop's templates, renders the env file again, and restarts the container even if nothing changed, so the settings repository is pulled again.
- **`make rebuild`**: a new Debian from the first-boot script (the VM on Google Cloud, a reinstall on OVH). Needed after a change to `compose.yaml` or `host/`. The data disk stays.

## Pairing

`orca serve` prints one pairing link per run, for the desktop by default. `make pair-desktop` reads it from the container's logs and hands it to `orca environment add` on the laptop. `make pair-mobile` restarts the server in mobile mode, shows its link as a QR code, then restarts it back. Pairings survive restarts and rebuilds. A pairing link is a credential.

## GitHub token

A classic token with the `repo` and `read:org` scopes. Fine-grained tokens are per organisation and can't read GHCR; `read:org` is what the mobile app needs to list repositories when you create a worktree.

## Host keys and workspace trust

Every rebuild brings a new SSH host key, and the tailnet already authenticates the machine, so the Makefile skips the host-key check. For your own `ssh core@<name>`, put `StrictHostKeyChecking no` and `UserKnownHostsFile /dev/null` under `Host <name>` in `~/.ssh/config`.

Claude Code asks to trust a workspace once per project, as on a laptop: the trust covers a checkout's worktrees and can't be granted from a parent folder.
