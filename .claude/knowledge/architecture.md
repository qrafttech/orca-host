# Architecture

Image, stack, host. Each layer works without the one above it: the image runs on any Docker host, the stack on any Linux Docker host with `/dev/net/tun`, Terraform brings up a VM that runs the stack: Debian, made into a host by one script, `host/first-boot.sh.tftpl`, the same on every provider. One Terraform root per provider, `terraform/<provider>/`, picked by `PROVIDER`: `terraform/gcp/`, the default, and `terraform/ovh/` for an OVH VPS (below, **An OVH host**).

```
laptop / phone ──tailnet──▶ VM (Debian, host/first-boot.sh.tftpl)
                             ├─ data disk  /var/lib/orca — survives a VM rebuild, snapshotted daily
                             │    home/       /home/orca: checkouts, ~/.claude, Orca state
                             │    tailscale/  node identity: same tailnet IP after a rebuild
                             │    docker/     Docker's data root: images, build cache, the volumes of project stacks
                             │    env         the env file, rendered from .env.tpl and 1Password: every boot, restart, new image
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
| The VM | Docker, two containers (`tailscale`, `orca-host`), and at every boot a transient `op` one that renders the env file | nothing else |
| The `orca-host` container | `orca serve`, every Claude pane, every Orca terminal, a project's Claude Code hooks, `prune-stacks` every 5 minutes | `claude`, `gh`, `git`, the Docker CLI, `op`, `ruby`, `python3`, `node` |
| A project's containers | the app, its database, its cache: a worktree's stack | the app's runtime, at its version, from the project's compose |

Beside, not inside: the `orca-host` container has the VM's Docker socket, so a `docker compose up` from an Orca terminal creates the project's containers on the VM's Docker, as siblings of `orca-host`. Same path everywhere: on the VM, `/home/orca` is a symlink to `/var/lib/orca/home`, which the container mounts at `/home/orca`, so a project's `./:/app` bind mount names the same files on both sides.

**Deleted worktrees.** Orca deletes a worktree without telling the host, and what the worktree put on the data disk stays behind: its stack (containers running, volumes kept), the images compose built for it, their layers in the build cache. One sweep, every 5 minutes, in the `orca-host` container, so a fix is an image change and a `make restart`, not a rebuild:

- `prune-stacks`, as `orca`. Every container compose starts carries two labels, its project and the directory it was started from; every project whose directory is under `/home/orca` and no longer exists is taken down with `docker compose -p <name> down -v --rmi local`, which acts on the labels and needs no compose file. `--rmi local` removes the images compose built for the stack, those with no `image:` name, found by the project label compose puts on them; a pulled `postgres` stays. One log line per stack torn down. Directories elsewhere (a laptop's stacks, the host's own `/opt/orca`) are out of reach.
- Then, in the same pass, the build cache is capped at 10 GB (`docker builder prune --max-used-space`, `BUILD_CACHE_MAX`), least recently used first: a removed image's layers are BuildKit's cache as well, and give back little until the cache goes too. What is reused stays; a worktree deleted days ago goes first. The daemon's own GC (`builder.gc` in `daemon.json`) would do the same, but from Ignition, so a rebuild for each change.
- Nothing for the worktree itself. Orca moves a deleted worktree to `.orca-worktree-trash/wt-<timestamp>-<id>` next to the project's worktrees, then removes it, as `orca`. That fails on any file `orca` does not own, and the whole worktree stays in the trash: a project's containers must not write into the bind-mounted worktree as root (`user:` in its compose file, uid 1000, or `node_modules` and caches in named volumes). The host does not sweep it as root: the fix is the project's, and a root loop would only hide it.

Not covered: a stack brought down without `-v` before its worktree is deleted leaves no container to name the directory, so its volumes and images stay; that case is the project's archive script. Images outside any stack (one built by hand from a terminal) are not touched either.

## The image

- `orca serve` from the official AppImage, extracted with `unsquashfs` at build time. No FUSE in a container, and the arm64 build runs under QEMU, where the kernel's binfmt rule refuses to execute an AppImage.
- Claude Code as the native binary, checksum-verified against the release manifest. `DISABLE_AUTOUPDATER=1`: the image is the version.
- `gh`, `git`, the Docker CLI with the compose and buildx plugins. Buildx because without it compose falls back to the classic builder, which neither keeps a BuildKit cache nor labels the images it builds with their project, the label `prune-stacks` finds them by. `git` authenticates to GitHub through `gh` (a `credential.helper` in the image), so `GH_TOKEN` is the only GitHub credential: no SSH key, no `gh auth login`.
- `op`, the 1Password CLI, the static binary from the official image. The host's secrets *are* 1Password items — the VM renders the env file with the same CLI, from its own image, before this one is pulled — so `op` is infrastructure here, like `gh`, not somebody's tool. What it can read is the env file's business, below.
- `ruby`, `python3`, `node`: a project's Claude Code hooks run next to `claude`, not in the project's containers. The app's own runtime, at its own version, lives in those.
- Versions are build args at the top of the `Dockerfile`. Orca is pinned to the desktop client's version (protocol compatibility). A bump is a PR that says why.
- It names no tool beyond those. What one person wants installed is not in this repository at all: see below.

**What is personal, and where.** Software is an image of the person's own, below. Text (permissions, `CLAUDE.md`, skills, `config/mcp.json`) is the settings repository, pulled at every start, because a permission should not need a rebuild. Configuration is `.env.tpl`, versioned, its secrets as references; their values are 1Password items, because neither a repository nor an image may carry one. Three kinds, three mechanisms, no overlap.

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
- **No package format to maintain.** Each release shape (a bare binary, a `.tar.gz`, a `.zip`, a nested path) would be a special case in shell. `RUN` is the whole vocabulary, and it is Docker's, not ours.
- **It is what the VM is for.** The host installs Docker and nothing else, once, from a pinned script; installing into a volume at every start put the moving parts back.

The cost is a rebuild for a new tool instead of a restart, and a derived image going stale when the base moves. A digest-pinned `FROM` plus Dependabot in the derived repository turns the second into a pull request per base build. Private derived images are not supported: `/opt/orca/up` does no registry login, so a derived image must be public — it holds no secret, only software that was already downloadable.

### CI

`.github/workflows/ci.yml`, on every push: lint (hadolint, shellcheck, `terraform fmt` and `validate`), build amd64, smoke-test the ready contract (an `orca_server_ready` line with `schemaVersion: 1`, then `docker version` from inside the container) and `prune-stacks` (a compose stack started from a `/home/orca` directory that no longer exists, one image built by compose, is gone by the time the server is ready, image included), then push the multi-arch image as `<branch>` and `sha-<sha>`. The `main` tag moves; a host pinned to a build names the sha tag, or a digest, in `orca_image`. Those tags are also the contract of a derived image: its `FROM` names one of them.

## The stack

`compose.yaml` is the whole contract of a host: every personal value is a variable, listed at the top of the file, from one env file. The file is read twice: by compose for the declared variables, and by the `orca-host` container as a whole (`env_file`), so a new variable needs no compose change.

- `tailscale`: host network, `NET_ADMIN`, `/dev/net/tun`. `TS_AUTHKEY` is read on the first start only (`TS_AUTH_ONCE`), for a node tagged `orca-host`, which never expires; the node identity then lives in `<ORCA_DATA>/tailscale`, so the host keeps its tailnet IP across rebuilds.
- `orca-host`: host network, `init: true`. `/home/orca` is bind-mounted from `<ORCA_DATA>/home` at the same path, so a project's compose file can bind-mount `/home/orca/<project>/...`. The Docker socket is mounted: project stacks are sibling containers on the VM's Docker.

Stopping the stack ends live terminals, as a service restart does.

### Laptop override

`compose.laptop.yaml`, for a Mac with Docker Desktop. Docker Desktop has no `/dev/net/tun` and no host network, and its bind mounts refuse the unix sockets Orca needs in its home. So: the Tailscale service goes to a `vm` profile (not started), the laptop's own Tailscale is the tailnet node, `PAIRING_ADDRESS` is the laptop's tailnet IP (`tailscale ip -4`), port 6768 is published, and the home is a named volume.

## The host

One person, one `terraform apply`, one state, in a bucket of the person's own GCP project: `make bootstrap` creates it, `make init` points Terraform at it, one prefix per host. Bucket and prefix are given at init (`-backend-config`), not by the root's directory: a root moved in the tree finds its state again with a `make init`. Terraform authenticates with Application Default Credentials, separate from `gcloud auth login`.

The VM is Debian 13. `host/first-boot.sh.tftpl`, rendered by Terraform from `compose.yaml` and the files under `host/`, is everything the VM is: GCP runs it as the instance's `startup-script`, at every boot, and it stops at its first lines when the hash of the script it last applied, kept on the boot disk, is its own; OVH runs it once after a reinstall. Idempotent either way:

- the user `core`, its SSH key, sudo and docker; no password login
- the data disk (`data_device`): ext4, labelled `orca`, formatted only when it holds no filesystem, mounted at `/var/lib/orca` by label; without one, `/var/lib/orca` is a directory of the root disk
- `/home/orca → /var/lib/orca/home`
- Docker CE, its compose and buildx plugins and containerd from Docker's apt repository, versions pinned and held; Debian's own packages update unattended
- `/etc/docker/daemon.json`: Docker's data root at `/var/lib/orca/docker`, the graph-driver store rather than containerd's (whose images would sit under `/var/lib/containerd`, on the boot disk), and a drop-in so `docker.service` starts after the data disk is mounted
- `/opt/orca/compose.yaml`, `inject-env`, `render-env`, `up`, `firewall`, `host.env` (the host's name and image, read by the units), and `/opt/orca/env.tpl`, `/opt/orca/env.<name>.tpl` when the laptop has those templates
- `/opt/orca/firewall`: nftables, its own table beside Docker's. In: the tailnet, Docker's bridges, ICMP, DHCP, Tailscale's UDP 41641, and SSH until `make lockdown` (a marker, `/var/lib/orca/lockdown`). Forward: no new connection from the public interface reaches a container, so a project's `ports:` stays on the tailnet
- `orca-env.service`: renders the env file, below. Retries until `/var/lib/orca/op-token` is there (`make secret` comes after `make apply`). It runs `op`, so it waits for Docker as `orca.service` does
- `orca.service`: `/opt/orca/up` pulls `orca_image`, renders the env file again if the image is not the one it was rendered from (a new image may carry new `/etc/orca-host/env*.tpl`), then `docker compose up -d --pull missing --remove-orphans`: compose runs the image the env file was rendered from, not one pulled a second later. Then `docker image prune -f`, once the stack is up: a pull on a moving tag leaves the image it replaced untagged, and a full orca-host image is not small next to every project's images on the same disk. Dangling only, so nothing tagged and nothing a container uses is touched, and a failed prune does not fail the unit.

**Secrets.** Two hops, one vault. `/var/lib/orca/op-token` holds a single line, a 1Password service-account token, written by `make secret` over SSH, so no secret ever passes through Terraform or its state. The first time, the host is not on the tailnet yet — it joins with a key it reads with that very token — so `make secret` falls back to the way in before the tailnet: IAP on GCP, the public address on OVH. At every start of `orca-env.service` the VM renders the env file from the templates: the image's `/etc/orca-host/env*.tpl`, then `/opt/orca/env*.tpl`, all optional, the last line of a variable winning, every `{{ op://Vault/Item/field }}` resolved by `op inject`. `inject-env.sh` does the resolving, the same script on the VM and in `make env`. `/var/lib/orca/env.image` records the image it was rendered from. `op` runs from its own image, pinned in `render-env`.

**Configuration.** What a host is — its name, project and zone in `terraform.tfvars`, the variables it starts with in `.env.tpl` — is configuration, and most of it is not secret. It is a file, versioned in the person's own repository, as a project versions its `.env.tpl`: the secrets in it are references, and a reference is not a secret. 1Password holds the values and nothing else. Two places for `.env.tpl`, because two kinds of person: one with an image of their own `COPY`s it to `/etc/orca-host/env.tpl`, and reaches the host with a push, since the VM reads the file from the image it is about to run and knows that image already (`orca_image`); one on the base image keeps it on the laptop, and Terraform carries it, as it carries `compose.yaml` — a reference may sit in the first-boot script and in the state. The script writes it at install, so `make restart` copies it again before rendering: a new line is a restart, not a rebuild. The laptop's file comes last so a host can override what its image says.

The chain is one file on the data disk → one token → one vault, read-only. `op_vault` is a technical vault: the tokens agents read, no password data. A service account is scoped per vault, not per item, so every reference in `.env.tpl` has to resolve inside that vault.

**Several accounts.** A person's secrets may also live in another 1Password account, a client's or a team's, which no service account of the host's account can read. Each such account gets its own service account, read-only on one vault of it, and its own template: `.env.<name>.tpl`, resolved with `OP_SERVICE_ACCOUNT_TOKEN_<NAME>`. That token is a line of `.env.tpl`, an item of the host's vault, so the chain stays one token on the data disk: the host's token resolves `.env.tpl`, which yields the others. The file name is the whole declaration — nothing here names an account, and a line cannot be resolved by the wrong one. A file that fails fails the render, as `.env.tpl` does: a host up on part of its environment is a host whose tools fail later, one by one, far from the cause. Each token reaches the sessions, so each of those vaults carries the same judgement as the host's: technical, read-only, what agents read.

What this buys is rotation. A token changed in 1Password reaches the host with `make restart`; a new variable is a line in `.env.tpl`: in the person's own image, a push, and the redeploy renders it; on the laptop, `make restart`, which copies it to the VM. Nothing is frozen at the moment it was uploaded — `make env` resolves the same files, with the person's own account, for a stack run there. The service-account token itself expires: renewing it is the one secret placed by hand, a new token in the item then `make secret`. Until that is done the host does not come up — `orca-env.service` fails rather than start the stack on the env file it rendered last time, and says so on the serial console. Restarting the two units is the way back.

**The token in a session.** `op` is in the image, and `render-env` appends `OP_SERVICE_ACCOUNT_TOKEN` to the file it writes: the sessions read the same read-only vault, with the token the VM already holds rather than a copy `.env.tpl` would read back from the vault. A project whose `.env` lives in 1Password is then brought up by its own worktree setup hook — `op inject -i .env.tpl -o .env` — with no step on a laptop, and a tool a session is asked to set up can fetch its own credential.

The cost is plain: every session, and everything a session runs, reads that vault. It is bounded by what is in the vault, which is the reason the vault is technical, read-only and separate. The same env file already carries `GH_TOKEN` and `CLAUDE_CODE_OAUTH_TOKEN` into every session, so this adds credentials of the same order next to those, not a new kind of exposure — the judgement to make is what goes in the vault, not whether the file has secrets in it.

Claude Code's own permission classifier refuses `op` in `auto` mode, as credential materialization. It takes an allow rule in the settings repository for a session to use it there.

**Disks.** Two, with different fates:

| Disk | Size | Holds | On a rebuild |
|---|---|---|---|
| boot | `boot_disk_gb`, 20 GB by default | Debian, Docker, `/opt/orca` | replaced with the VM |
| data | `data_disk_gb`, 50 GB by default | `/var/lib/orca`: `home/` (checkouts, worktrees, `~/.claude`, Orca state), `tailscale/` (node identity), `docker/` (Docker's data root: the images, the containers, the build cache, the named volumes of project stacks), `env` | kept |

Everything under `/var/lib/orca` survives a rebuild, Docker's root included: nothing is pulled again, a worktree's `postgres_data` is still there. Docker's root is there by `daemon.json`, not by Docker's default (`/var/lib/docker`, on the boot disk): once Debian has its share, the boot disk is too small for one project's images, and what it held went with the VM. A database in a Docker volume is a worktree database all the same: its setup hook creates it, its archive script removes it (`docker compose down -v`), nothing migrates it. The data disk is `pd-balanced` and regional, replicated in the two `data_disk_zones`: the VM runs in either, so a zone out of stock or down is a new `zone` and a `make apply`, the disk untouched. It is `prevent_destroy`, so only `make destroy` deletes it, snapshots included; daily snapshots at 03:00 (Docker's root included), seven kept, kept if the disk is deleted any other way; it grows live, never shrinks. Docker and the worktrees are what fill it. What a deleted worktree leaves goes with it (above), and the build cache stays under 10 GB, so the steady state is the live worktrees; `docker system prune` from `make shell` is for what no sweep sees, an image built by hand. `docker system df` and `du` on `/var/lib/orca` say what takes it. If the live worktrees alone keep it above 70%, `data_disk_gb` grows it.

**Sizing.** `machine_type` defaults to `e2-standard-4`, 16 GB of RAM: about 4 GB per compose stack, so three stacks and Orca. E2, N2 or N2D only: a regional disk attaches to no other series.

**Cost.** The VM is the bill; the rest is small. An `n2d-standard-4` host in Paris (`europe-west9`), at list prices:

| Line | Unit price | USD / month |
|---|---|---|
| vCPU, 4 × 730 h | $0.0319 / vCPU-h | ~93 |
| RAM, 16 GB × 730 h | $0.00428 / GB-h | ~50 |
| data disk, 50 GB `pd-balanced`, regional | $0.26 / GB-month | ~13 |
| boot disk, 20 GB `pd-balanced`, zonal | $0.116 / GB-month | ~2.3 |
| public IP, in use | $0.005 / h | ~3.7 |
| snapshots, state bucket | | a few dollars at most |

About $160 a month, $5 a day. N2D's sustained-use discount takes up to 20% off the VM over a full month; E2 has none. The regional disk is 2.2× the zonal price: that is what a zone out of stock being an apply costs. The VM line is the one to move: `e2-standard-4` is about $113, Spot about a third of the on-demand price but preemptible, a one-year commitment about 40% off. Stopped, a host costs its disks.

Prices move; the Cloud Billing Catalog API has the current ones. Compute Engine is service `6F81-5844-456A`, and its SKU list is paginated:

```
T=$(gcloud auth print-access-token); tok=""
while :; do
  r=$(curl -s -H "Authorization: Bearer $T" "https://cloudbilling.googleapis.com/v1/services/6F81-5844-456A/skus?currencyCode=USD&pageSize=5000&pageToken=$tok")
  echo "$r" | jq -e .error >/dev/null && { echo "$r" | jq .error; break; }
  echo "$r" | jq -r '.skus[] | select(.serviceRegions | index("europe-west9"))
    | select(.description | test("N2D AMD Instance (Core|Ram)|Balanced PD|External IP"; "i"))
    | [.description, .category.usageType, (.pricingInfo[0].pricingExpression.tieredRates[-1].unitPrice | (.units|tonumber) + .nanos/1e9), .pricingInfo[0].pricingExpression.usageUnitDescription] | @tsv'
  tok=$(echo "$r" | jq -r '.nextPageToken // ""'); [ -z "$tok" ] && break
done
```

What a project holds: `gcloud compute instances|disks|snapshots|addresses list`, `gcloud storage ls`, each with `--project`. What it was actually billed: the console, Billing → Reports, filtered on the project, grouped by SKU, credits unticked — a trial account otherwise shows $0.

**Network.** Own VPC, nothing reaches the VM from the internet; the public IP is for egress only. SSH answers on the tailnet address: `ssh core@<name>`. One firewall rule, the break-glass for when the stack is down and the way in for the first `make secret`: SSH from Google's IAP range only, `gcloud compute ssh <name> --tunnel-through-iap`, as the person's OS Login user (`enable-oslogin`), which needs an IAM identity of the project. The host's own firewall leaves SSH open on the public interface: the VPC already lets in IAP only, so `make lockdown` has nothing to do on GCP. The serial console (`gcloud compute connect-to-serial-port`) shows the boot log, the startup script's included, and both units' output.

**Host keys.** Every rebuild is a new host key, and the tailnet already authenticates the peer, so the `Makefile` skips the host-key check for this host. For your own `ssh core@<name>`, the same in `~/.ssh/config`:

```
Host <name>
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
```

## An OVH host

`PROVIDER=ovh`, `terraform/ovh/`. The same VM as on GCP: an OVH VPS takes no custom image and no user-data, but a bash script run once at the first boot after a reinstall (`postInstallScript` on `POST /vps/{service}/rebuild`), and that is the first-boot script, sent gzipped and base64-encoded behind a two-line wrapper: OVH answers a 500 to the script as it is, some 18 kB.

- **The VPS** is `ovh_vps`. Without `service_name`, Terraform orders it through OVH's order workflow (cart, checkout, payment by the account's default method): `plan_code` and `datacenter`, Debian as the order's OS, then reinstalled with the script like any other. With `service_name`, the VPS already ordered is imported (`import` with `for_each`). The order arguments are ignored after the creation, so an imported VPS never sees them. `prevent_destroy`: Terraform never terminates one, nor replaces it — which would be a second order. Termination is in the control panel, confirmed by email.
- **The install** is `terraform_data.install`. The `ovh` provider does not pass a post-install script, so its `local-exec` calls `ovhcloud vps reinstall --from-file` with the image id (looked up by `image_name`), the SSH key and the script. It is replaced, i.e. the VPS reinstalled, when the image or the key changes, or on `make rebuild`; a change of the script alone is stored, not applied.
- **Tools**: Terraform and `ovhcloud` run from `tools/Dockerfile`, pinned. OVH's API credentials are an item `ovh-api` (`endpoint`, `application_key`, `application_secret`, `consumer_key`) that `op run` puts in the container's environment; the state is in the GCS bucket `state_bucket`, through application-default credentials, or gcloud's access token when there are none (on a GCE VM, `application-default login` is discouraged).
- **SSH**: on the public address until `make lockdown`, for the first `make secret`; then the tailnet only, KVM in OVH's console as the break-glass.
- **Disk**: `data_device`, the VPS's additional disk if ordered, survives a reinstall. Without one, `/var/lib/orca` is on the root disk and a reinstall wipes it, pairing included.

## Restart or rebuild

Three ways a change reaches the host; the README, "When you change something", says which one each change takes.

- **Redeploy**: the host sees a new image under the tag it follows and restarts its container on it. The env file is rendered again first, since a new image may carry a new `/etc/orca-host/env.tpl`.
- **Restart** (`make restart`): the laptop's templates copied to the host, one removed there removed, the env file rendered again from them and 1Password, the image pulled, the container restarted even when neither changed, so the entrypoint pulls the settings repository again.
- **Rebuild** (`make rebuild`, an `apply -replace` of the VM on GCP, of the install on OVH): a new Debian, from the first-boot script.

`orca-update.timer` restarts `orca.service` every five minutes. `/opt/orca/up` pulls the image, and compose recreates a container only when that image differs from the running one, so a tick with nothing new is a manifest request and no more, and a merge to `main` reaches the host without anyone doing anything. The cost is that a redeploy ends live terminals, and no one chose its moment: a host following a tag takes what the tag serves. A host pinned to `sha-<sha>` in `orca_image` never moves, and the timer then only ever costs the manifest request.

`compose.yaml` is baked into the first-boot script. On GCP a change of it is stored in the instance's metadata and runs at the next boot; a rebuild is the clean way. A rebuild keeps the data disk: checkouts, Tailscale identity, pairing, Docker's images and the volumes of project stacks. Only Debian is new.

## Pairing

`orca serve` prints one pairing link per process, the desktop one by default. `make pair-desktop` reads the `orca_server_ready` line from the container's logs over SSH and hands `pairing.url` to `orca environment add`. `make pair-mobile` appends `ORCA_PAIRING=mobile` to the env file on the host, restarts the container, shows the new link as a QR code, then on Enter restarts `orca-env` (which renders the env file again, without `ORCA_PAIRING`) and the container. Two container restarts, at setup time, before any project is cloned. Interrupted between the two, the host stays on the mobile link: `make restart` is the way back.

The pairing URL is a credential. Both pairings survive restarts and rebuilds.

## GitHub token

A classic personal access token with the `repo` and `read:org` scopes, one token for every organisation the person belongs to. Fine-grained tokens are per organisation and cannot read GHCR; the organisation must allow classic tokens (Settings → Personal access tokens). `read:org` is required by the mobile app's GitHub source picker (organisation and repository lookups over GraphQL); without it, creating a worktree from mobile fails.

## Workspace trust

Claude Code's workspace trust is keyed on the checkout, covers its worktrees, and cannot be seeded from a parent folder: a checkout nested in a trusted folder is excluded by design. So it stays a question, once per project, as on a laptop.
