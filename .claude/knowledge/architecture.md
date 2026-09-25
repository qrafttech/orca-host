# Architecture

Image, stack, host. Each layer works without the one above it: the image runs on any Docker host, the stack on any Linux Docker host with `/dev/net/tun`, the Terraform module brings up a GCP VM that runs the stack. Another provider is another module rendering the same Ignition config.

```
laptop / phone ──tailnet──▶ VM (Flatcar Container Linux, Ignition)
                             ├─ data disk  /var/lib/orca — survives a VM rebuild, snapshotted daily
                             │    home/       /home/orca: checkouts, ~/.claude, Orca state
                             │    tailscale/  node identity: same tailnet IP after a rebuild
                             │    docker/     Docker's data root: images, build cache, the volumes of project stacks
                             │    env         the env file, fetched from Secret Manager at every boot
                             └─ compose.yaml
                                  ├─ tailscale   host network, /dev/net/tun
                                  └─ orca-host   host network, `orca serve --pairing-address <tailnet IP>`
                                       claude, gh, git, docker + compose in the image, under /usr/local and /opt
                                       /var/run/docker.sock: project stacks are sibling containers on the VM's Docker
                                       /home/orca is the same path inside and outside
```

## Where things run

| | Runs | Installed |
|---|---|---|
| The VM | Docker, and two containers: `tailscale` and `orca-host` | nothing else |
| The `orca-host` container | `orca serve`, every Claude pane, every Orca terminal, a project's Claude Code hooks, `prune-stacks` every 5 minutes | `claude`, `gh`, `git`, the Docker CLI, `ruby`, `python3`, `node` |
| A project's containers | the app, its database, its cache: a worktree's stack | the app's runtime, at its version, from the project's compose |

Beside, not inside: the `orca-host` container has the VM's Docker socket, so a `docker compose up` from an Orca terminal creates the project's containers on the VM's Docker, as siblings of `orca-host`. Same path everywhere: on the VM, `/home/orca` is a symlink to `/var/lib/orca/home`, which the container mounts at `/home/orca`, so a project's `./:/app` bind mount names the same files on both sides.

**Deleted worktrees.** Orca deletes a worktree without telling the host, and the stack the worktree started stays behind: containers running, volumes kept. Every container compose starts carries two labels, its project and the directory it was started from, so every 5 minutes `prune-stacks` takes down, volumes included, every project whose directory is under `/home/orca` and no longer exists: `docker compose -p <name> down -v`, which acts on the labels and needs no compose file. One log line per stack torn down. Directories elsewhere (a laptop's stacks, the host's own `/opt/orca`) are out of reach. Not covered: a stack brought down without `-v` before its worktree is deleted leaves no container to name the directory, so its volumes stay; that case is the project's archive script.

## The image

- `orca serve` from the official AppImage, extracted with `unsquashfs` at build time. No FUSE in a container, and the arm64 build runs under QEMU, where the kernel's binfmt rule refuses to execute an AppImage.
- Claude Code as the native binary, checksum-verified against the release manifest. `DISABLE_AUTOUPDATER=1`: the image is the version.
- `gh`, `git`, the Docker CLI with the compose plugin. `git` authenticates to GitHub through `gh` (a `credential.helper` in the image), so `GH_TOKEN` is the only GitHub credential: no SSH key, no `gh auth login`.
- `ruby`, `python3`, `node`: a project's Claude Code hooks run next to `claude`, not in the project's containers. The app's own runtime, at its own version, lives in those.
- Versions are build args at the top of the `Dockerfile`. Orca is pinned to the desktop client's version (protocol compatibility). A bump is a PR that says why.
- It names no tool beyond those. What one person wants installed is not in this repository at all: see below.

**What is personal, and where.** Software is an image of the person's own, below. Text (permissions, `CLAUDE.md`, skills, `config/mcp.json`) is the settings repository, pulled at every start, because a permission should not need a rebuild. Secrets are the env file, because an image must never carry one. Three kinds, three mechanisms, no overlap.

The entrypoint starts as root, gives `orca` the Docker socket's group and its home (a volume: empty and root-owned the first time), then re-executes as `orca`:

1. Seeds `~/.claude.json` with Claude Code's first-run answers (onboarding, theme, bypass-permissions acceptance). Merged at every start: Claude rewrites the file.
2. Applies the Claude preferences, see [claude-settings.md](claude-settings.md).
3. Starts the `prune-stacks` loop in the background, every 5 minutes, for as long as the container runs.
4. Waits for `tailscale0`, unless `PAIRING_ADDRESS` is given.
5. `exec orca serve --port 6768 --pairing-address <IP> [--mobile-pairing] --json`.

### Your own image

The host installs nothing at run time. A person's binaries and MCP servers are a `Dockerfile` of a few lines in their own repository, `FROM ghcr.io/qrafttech/orca-host:main@sha256:<digest>`, `RUN` per tool into `/usr/local/bin` (on every PATH already), built by their own CI; `orca_image` points the host at the result. The recipe is in the README, "Your own tools".

Why not a boot-time installer — the entrypoint reading a list of declared URLs and checksums and fetching them into `~/bin` on the volume, which is the obvious alternative and the wrong one:

- **Reproducible.** A `docker build` from a digest-pinned base gives the same image whoever runs it; a volume gives whatever it already held. Two hosts on the same image and the same settings repository could differ.
- **Auditable.** `docker history` and a tag say what is installed. A volume only says it by being read.
- **Pinned in time.** The digest in the `FROM` and the checksums in the `RUN` are fixed when the build runs, not re-resolved against a release page months later.
- **No package format to maintain.** Each new release shape (a bare binary, a `.tar.gz`, a `.zip`, a nested path) was a special case in shell. `RUN` is the whole vocabulary, and it is Docker's, not ours.
- **It is what the VM is for.** Flatcar is immutable so that nothing is installed on the host; installing into a volume at every start put the moving parts back.

The cost is a rebuild for a new tool instead of a restart, and a derived image going stale when the base moves. A digest-pinned `FROM` plus Dependabot in the derived repository turns the second into a pull request per base build. Private derived images are not supported: `/opt/orca/up` does no registry login, so a derived image must be public — it holds no secret, only software that was already downloadable.

### CI

`.github/workflows/ci.yml`, on every push: lint (hadolint, shellcheck, `terraform fmt` and `validate`), build amd64, smoke-test the ready contract (an `orca_server_ready` line with `schemaVersion: 1`, then `docker version` from inside the container) and `prune-stacks` (a compose stack started from a `/home/orca` directory that no longer exists is gone by the time the server is ready), then push the multi-arch image as `<branch>` and `sha-<sha>`. The `main` tag moves; a host pinned to a build names the sha tag, or a digest, in `orca_image`. Those tags are also the contract of a derived image: its `FROM` names one of them.

## The stack

`compose.yaml` is the whole contract of a host: every personal value is a variable, listed at the top of the file, from one env file. The file is read twice: by compose for the declared variables, and by the `orca-host` container as a whole (`env_file`), so a new variable needs no compose change.

- `tailscale`: host network, `NET_ADMIN`, `/dev/net/tun`. `TS_AUTHKEY` is read on the first start only (`TS_AUTH_ONCE`); the node identity then lives in `<ORCA_DATA>/tailscale`, so the host keeps its tailnet IP across rebuilds.
- `orca-host`: host network, `init: true`. `/home/orca` is bind-mounted from `<ORCA_DATA>/home` at the same path, so a project's compose file can bind-mount `/home/orca/<project>/...`. The Docker socket is mounted: project stacks are sibling containers on the VM's Docker.

Stopping the stack ends live terminals, as a service restart does.

### Laptop override

`compose.laptop.yaml`, for a Mac with Docker Desktop. Docker Desktop has no `/dev/net/tun` and no host network, and its bind mounts refuse the unix sockets Orca needs in its home. So: the Tailscale service goes to a `vm` profile (not started), the laptop's own Tailscale is the tailnet node, `PAIRING_ADDRESS` is the laptop's tailnet IP (`tailscale ip -4`), port 6768 is published, and the home is a named volume.

## The host

One person, one `terraform apply`, one state, in a bucket of the person's own GCP project: `make bootstrap` creates it, `make init` points Terraform at it, one prefix per host. Terraform authenticates with Application Default Credentials, separate from `gcloud auth login`.

The VM is Flatcar Container Linux: immutable, Docker built in, nothing installed, updates itself. Ignition, rendered from `terraform/ignition.yaml.tftpl`, is everything the VM is, applied at first boot only:

- the SSH key for `core`
- the data disk: ext4, labelled `orca`, mounted at `/var/lib/orca`, never wiped (`wipe_filesystem: false`)
- `/home/orca → /var/lib/orca/home`
- `/opt/orca/compose.yaml`, `/opt/orca/fetch-env`, `/opt/orca/up` (`/etc` is noexec on Flatcar)
- `/etc/docker/daemon.json`: Docker's data root at `/var/lib/orca/docker`, and a drop-in so `docker.service` starts after the data disk is mounted
- `orca-env.service`: fetches the secret with the VM's own service account, retrying until a version exists (`make secret` may come after `make apply`)
- `orca.service`: `docker compose up -d --pull always --remove-orphans`, run from the `docker:cli` image, since Flatcar ships no compose. Then `docker image prune -f`, once the stack is up: `--pull always` on a moving tag leaves the image it replaced untagged, and a full orca-host image is not small next to every project's images on the same disk. Dangling only, so nothing tagged and nothing a container uses is touched, and a failed prune does not fail the unit.

**Secrets.** Terraform creates the Secret Manager secret empty; versions are added by `make secret`, so no secret ever passes through Terraform or its state. The VM's service account reads that one secret and nothing else. 1Password is never on the host. The env note may reference other 1Password items (`{{ op://Vault/Item/field }}`): `op inject` resolves them inside `make secret`, on the laptop, so the host still sees one flat file and a token is stored once.

**Disks.** Two, with different fates:

| Disk | Size | Holds | On a rebuild |
|---|---|---|---|
| boot | `boot_disk_gb`, 20 GB by default | Flatcar, nothing else | replaced with the VM |
| data | `data_disk_gb`, 50 GB by default | `/var/lib/orca`: `home/` (checkouts, worktrees, `~/.claude`, Orca state), `tailscale/` (node identity), `docker/` (Docker's data root: the images, the containers, the build cache, the named volumes of project stacks), `env` | kept |

Everything under `/var/lib/orca` survives a rebuild, Docker's root included: nothing is pulled again, a worktree's `postgres_data` is still there. Docker's root is there by `daemon.json`, not by Docker's default (`/var/lib/docker`, on the boot disk): once Flatcar has its share, the boot disk is too small for one project's images, and what it held went with the VM. A database in a Docker volume is a worktree database all the same: its setup hook creates it, its archive script removes it (`docker compose down -v`), nothing migrates it. The data disk is `pd-balanced`, `prevent_destroy`, daily snapshots at 03:00 (Docker's root included), seven kept, kept if the disk is deleted; it grows live, never shrinks. Docker is what fills it: `docker system df` says what takes it, `docker system prune` from `make shell` gives back what no container uses (volumes only with `--volumes`).

**Sizing.** `machine_type` defaults to `e2-standard-4`, 16 GB of RAM: about 4 GB per compose stack, so three stacks and Orca.

**Network.** Own VPC, nothing reaches the VM from the internet; the public IP is for egress only. SSH answers on the tailnet address: `ssh core@<name>`. One firewall rule, the break-glass for when the stack is down: SSH from Google's IAP range only, `gcloud compute ssh <name> --tunnel-through-iap`, which needs an IAM identity of the project. The serial console (`gcloud compute connect-to-serial-port`) shows the boot log, including both units' output.

**Host keys.** Every rebuild is a new host key, and the tailnet already authenticates the peer, so the `Makefile` skips the host-key check for this host. For your own `ssh core@<name>`, the same in `~/.ssh/config`:

```
Host <name>
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
```

## Restart or rebuild

| Change | Action |
|---|---|
| a new image under the same tag | nothing: the host redeploys itself within five minutes |
| a new secret version, a new variable in it | `make restart` |
| `compose.yaml`, `terraform/ignition.yaml.tftpl`, `orca_image` | `terraform -chdir=terraform apply -replace=google_compute_instance.vm` |

`orca-update.timer` restarts `orca.service` every five minutes. `/opt/orca/up` is `--pull always`, and compose recreates a container only when the digest it pulled differs from the running one, so a tick with nothing new is a manifest request and no more, and a merge to `main` reaches the host without anyone doing anything. The cost is that a redeploy ends live terminals, and no one chose its moment: a host following a tag takes what the tag serves. A host pinned to `sha-<sha>` in `orca_image` never moves, and the timer then only ever costs the manifest request.

Ignition runs at first boot only, and `compose.yaml` is baked into it. A rebuild keeps the data disk: checkouts, Tailscale identity, pairing, Docker's images and the volumes of project stacks. Only Flatcar is new.

## Pairing

`orca serve` prints one pairing link per process, the desktop one by default. `make pair-desktop` reads the `orca_server_ready` line from the container's logs over SSH and hands `pairing.url` to `orca environment add`. `make pair-mobile` appends `ORCA_PAIRING=mobile` to the env file on the host, restarts the container, shows the new link as a QR code, then on Enter restarts `orca-env` (which refetches the file: the secret again, without `ORCA_PAIRING`) and the container. Two container restarts, at setup time, before any project is cloned. Interrupted between the two, the host stays on the mobile link: `make restart` is the way back.

The pairing URL is a credential. Both pairings survive restarts and rebuilds.

## GitHub token

A classic personal access token with the `repo` and `read:org` scopes, one token for every organisation the person belongs to. Fine-grained tokens are per organisation and cannot read GHCR; the organisation must allow classic tokens (Settings → Personal access tokens). `read:org` is required by the mobile app's GitHub source picker (organisation and repository lookups over GraphQL); without it, creating a worktree from mobile fails.

## Workspace trust

Claude Code's workspace trust is keyed on the checkout, covers its worktrees, and cannot be seeded from a parent folder: a checkout nested in a trusted folder is excluded by design. So it stays a question, once per project, as on a laptop.
