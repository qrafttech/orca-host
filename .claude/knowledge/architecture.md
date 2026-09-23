# Architecture

Image, stack, host. Each layer works without the one above it: the image runs on any Docker host, the stack on any Linux Docker host with `/dev/net/tun`, the Terraform module brings up a GCP VM that runs the stack. Another provider is another module rendering the same Ignition config.

```
laptop / phone ──tailnet──▶ VM (Flatcar Container Linux, Ignition)
                             ├─ data disk  /var/lib/orca — survives a VM rebuild, snapshotted daily
                             │    home/       /home/orca: checkouts, ~/.claude, Orca state
                             │    tailscale/  node identity: same tailnet IP after a rebuild
                             │    env         the env file, fetched from Secret Manager at every boot
                             └─ compose.yaml
                                  ├─ tailscale   host network, /dev/net/tun
                                  └─ orca-host   host network, `orca serve --pairing-address <tailnet IP>`
                                       claude, gh, git, docker + compose in the image, under /usr/local and /opt
                                       /var/run/docker.sock: project stacks are sibling containers on the VM's Docker
                                       /home/orca is the same path inside and outside
```

## The image

- `orca serve` from the official AppImage, extracted with `unsquashfs` at build time. No FUSE in a container, and the arm64 build runs under QEMU, where the kernel's binfmt rule refuses to execute an AppImage.
- Claude Code as the native binary, checksum-verified against the release manifest. `DISABLE_AUTOUPDATER=1`: the image is the version.
- `gh`, `git`, the Docker CLI with the compose plugin. `git` authenticates to GitHub through `gh` (a `credential.helper` in the image), so `GH_TOKEN` is the only GitHub credential: no SSH key, no `gh auth login`.
- `ruby`, `python3`, `node`: a project's Claude Code hooks run next to `claude`, not in the project's containers. The app's own runtime, at its own version, lives in those.
- Versions are build args at the top of the `Dockerfile`. Orca is pinned to the desktop client's version (protocol compatibility). A bump is a PR that says why.

The entrypoint starts as root, gives `orca` the Docker socket's group and its home (a volume: empty and root-owned the first time), then re-executes as `orca`:

1. Seeds `~/.claude.json` with Claude Code's first-run answers (onboarding, theme, bypass-permissions acceptance). Merged at every start: Claude rewrites the file.
2. Applies the Claude preferences, see [claude-settings.md](claude-settings.md).
3. Waits for `tailscale0`, unless `PAIRING_ADDRESS` is given.
4. `exec orca serve --port 6768 --pairing-address <IP> [--mobile-pairing] --json`.

### CI

`.github/workflows/ci.yml`, on every push: lint (hadolint, shellcheck, `terraform fmt` and `validate`), build amd64, smoke-test the ready contract (an `orca_server_ready` line with `schemaVersion: 1`, then `docker version` from inside the container), then push the multi-arch image as `<branch>` and `sha-<sha>`. The `main` tag moves; a host pinned to a build uses the sha tag as `image_tag`.

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
- `orca-env.service`: fetches the secret with the VM's own service account, retrying until a version exists (`make secret` may come after `make apply`)
- `orca.service`: `docker compose up -d --pull always --remove-orphans`, run from the `docker:cli` image, since Flatcar ships no compose

**Secrets.** Terraform creates the Secret Manager secret empty; versions are added by `make secret`, so no secret ever passes through Terraform or its state. The VM's service account reads that one secret and nothing else. 1Password is never on the host.

**Data disk.** `pd-balanced`, `prevent_destroy`, daily snapshots at 03:00, seven kept, kept if the disk is deleted. Grows live, never shrinks. The boot disk holds the OS and the Docker images and is replaced with the VM.

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
| a new secret version, a new variable in it, a new image under the same tag | `make restart` |
| `compose.yaml`, `terraform/ignition.yaml.tftpl` | `terraform -chdir=terraform apply -replace=google_compute_instance.vm` |

Ignition runs at first boot only, and `compose.yaml` is baked into it. A rebuild keeps the data disk (checkouts, Tailscale identity, pairing) and pulls the images again.

## Pairing

`orca serve` prints one pairing link per process, the desktop one by default. `make pair-desktop` reads the `orca_server_ready` line from the container's logs over SSH and hands `pairing.url` to `orca environment add`. `make pair-mobile` appends `ORCA_PAIRING=mobile` to the env file on the host, restarts the container, shows the new link as a QR code, then on Enter restarts `orca-env` (which refetches the file: the secret again, without `ORCA_PAIRING`) and the container. Two container restarts, at setup time, before any project is cloned. Interrupted between the two, the host stays on the mobile link: `make restart` is the way back.

The pairing URL is a credential. Both pairings survive restarts and rebuilds.

## GitHub token

A classic personal access token with the `repo` and `read:org` scopes, one token for every organisation the person belongs to. Fine-grained tokens are per organisation and cannot read GHCR; the organisation must allow classic tokens (Settings → Personal access tokens). `read:org` is required by the mobile app's GitHub source picker (organisation and repository lookups over GraphQL); without it, creating a worktree from mobile fails.

## Workspace trust

Claude Code's workspace trust is keyed on the checkout, covers its worktrees, and cannot be seeded from a parent folder: a checkout nested in a trusted folder is excluded by design. So it stays a question, once per project, as on a laptop.
