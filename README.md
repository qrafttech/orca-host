# orca-host

A headless [Orca](https://github.com/stablyai/orca) server, driven from the desktop or mobile Orca client over the Qraft tailnet. One host per person, all of their projects on it. What belongs to a project (`orca.yaml`, worktree scripts, `.env` files, base images) lives in the project's repository, not here.

A host is an image, a compose stack and a Terraform module. Each layer works without the one above it.

| Layer | Artifact | Runs on |
|---|---|---|
| Image | `Dockerfile` → `ghcr.io/qrafttech/orca-host` | any Docker host, amd64 and arm64 |
| Stack | `compose.yaml` + one env file | any Linux Docker host with `/dev/net/tun` |
| Host | `terraform/` | GCP; another provider is another module rendering the same Ignition config |

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

`orca serve` from the official AppImage, Claude Code, `gh`, `git`, the Docker CLI with compose, and `ruby`, `python3`, `node` for projects' Claude Code hooks, which run next to `claude`, not in the project's containers (the app's runtime, at its version, lives there). Runs as the unprivileged user `orca`; the entrypoint gives it the Docker socket's group, waits for `tailscale0` (or takes `PAIRING_ADDRESS`), seeds `~/.claude.json` with the bypass-permissions acceptance, and execs `orca serve --json`. Versions are build args at the top of the `Dockerfile`; a bump is a PR that says why.

CI builds every push, runs the ready-contract smoke test, and pushes `ghcr.io/qrafttech/orca-host:<branch>` and `:sha-<sha>`; `make build` builds `orca-host:dev` for this machine.

## The stack

`compose.yaml` is the whole contract of a host: every personal value is a variable, listed at the top of the file. They come from one env file, one per host:

```
TS_AUTHKEY=tskey-auth-...          tagged tag:orca-host, preauthorized, single-use; read on the first start only
CLAUDE_CODE_OAUTH_TOKEN=...        from `claude setup-token`
GH_TOKEN=...                       classic, `repo` + `read:org` scopes
GIT_AUTHOR_NAME=...
GIT_AUTHOR_EMAIL=...
CLAUDE_PERMISSION_MODE=auto        optional: the permission mode of Claude panes
CLAUDE_SETTINGS_REPO=me/claude     optional: your Claude settings, versioned; `permissions`, CLAUDE.md, skills, user MCP servers and their binaries are taken
CLAUDE_SETTINGS_FILE=config/settings.json   where settings.json is in that repository
```

Your Claude preferences, two ways: `CLAUDE_PERMISSION_MODE` alone sets the permission mode; `CLAUDE_SETTINGS_REPO` takes `permissions` from your own settings repository (only that: hooks and status lines point at laptop things), plus a `CLAUDE.md` and a `.claude/skills` at its root as the global ones, merges `config/mcp.json` (if present) into the user-level MCP servers — never overwriting one already configured — and installs whatever `config/bin.json` (if present) declares into `~/bin`, on the volume, checksum-verified. Neither set: Claude's defaults, it asks. Workspace trust stays a question, once per project, as on a laptop.

The file is the body of a 1Password Secure Note named `orca-host`, in the vault `OP_VAULT` (`Private` by default; `export OP_VAULT="..."` or pass it to `make`). `make env` renders it to `./env` (gitignored) for a laptop when the file is absent — edit the local copy freely, `rm` it to refetch; `make secret` always reads 1Password and sends it to the host's secret. 1Password is never on the host.

Tailscale identity, Orca state and checkouts are under `ORCA_DATA` on the host (`/var/lib/orca` on the VM). Stopping the stack ends live terminals, as a service restart does.

On a Mac, `make up`: `compose.laptop.yaml` drops the Tailscale service (Docker Desktop has no `/dev/net/tun` and no host network), publishes 6768 and advertises the laptop's own tailnet IP. Docker Desktop bind mounts refuse the unix sockets Orca needs, so the home is a named volume there.

## The host

One person, one `terraform apply`, one state. `terraform/terraform.tfvars` holds the name, project, zone, size and your SSH public key: `terraform/terraform.tfvars.example` filled in, as the body of a second Secure Note, `orca-host-tfvars`, in the same vault. Nothing in it is secret; the note is what makes it follow you to any checkout, worktree or laptop. Any `make` target that needs the file fetches it when absent (gitignored; edit it freely, `rm` it to refetch). State goes to a bucket in your project. Terraform authenticates with Application Default Credentials, which are separate from `gcloud auth login`: `gcloud auth application-default login` once.

```bash
make bootstrap   # once per project: the state bucket
make init        # once per checkout
make apply       # VPC, service account, secret, data disk + daily snapshots, VM
make secret      # the env file, from 1Password, into Secret Manager
make pair        # the desktop client, then the phone, then the server back to its desktop link
```

The VM is Flatcar Container Linux: immutable, Docker built in, nothing installed, updates itself. Ignition, rendered by Terraform from `terraform/ignition.yaml.tftpl`, is everything the VM is: the SSH key, the data-disk filesystem and mount, `/home/orca → /var/lib/orca/home`, `compose.yaml`, and two units: `orca-env.service` fetches the secret with the VM's own service account (retrying until a version exists), `orca.service` runs `docker compose up -d` from the `docker:cli` image. Rotate a secret, or pick up a new image under the same tag: `make secret`, `make restart`.

Network: own VPC, nothing reaches the VM from the internet. SSH answers on the tailnet address: `ssh core@<name>` (`make ssh`, `make logs`). The one firewall rule is the break-glass for when the stack is down: SSH from Google's IAP range only, `gcloud compute ssh <name> --tunnel-through-iap`, which needs an IAM identity of the project. The serial console shows the boot log, including the two units' output.

What changes how: a new secret version, a new variable in it, or a new image under the same tag → `make restart`; a change to `compose.yaml` or `ignition.yaml.tftpl` → a rebuild, Ignition runs at first boot only.

Rebuild the VM: `terraform -chdir=terraform apply -replace=google_compute_instance.vm`. The data disk keeps the checkouts, the Tailscale identity and the pairing; the client stays paired. The disk has `prevent_destroy`; the images on the boot disk are pulled again. A rebuilt VM has new SSH host keys; the `Makefile` skips the host-key check for the host, since the tailnet already authenticates the peer. For your own `ssh core@<name>`, the same in `~/.ssh/config`:

```
Host <name>
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
```

## Pairing and projects

`make pair` pairs both clients, in two steps. `make pair-desktop` reads the `orca_server_ready` line from the container's logs and hands `pairing.url` to `orca environment add`; then in the app: Settings → Remote Orca Servers → Advanced → Active Server. `orca serve` prints one pairing link per process, the desktop one by default, so `make pair-mobile` appends `ORCA_PAIRING=mobile` to the env file on the host, restarts the container, shows the new link as a QR in the terminal to scan from the phone (Tailscale on, same tailnet), and, on Enter, restarts the env fetch and the container: the file is the secret again, the server is back on its desktop link. Two container restarts, at setup time, before any project is cloned; interrupted between the two, `make restart` is the way back. The URL is a credential; both pairings survive restarts and rebuilds.

Add a project in the app: Set project location → Clone from URL, the https URL, destination `/home/orca` (the repository name is appended). `git` authenticates through `gh` with `GH_TOKEN`: no login, no key. `make shell` is a shell in the container as `orca`, the same paths an Orca terminal sees. A worktree's setup hook runs `docker compose` on the VM's Docker; what it starts is reachable at `http://<tailnet IP>:<port>`.

## By hand, and to script

Before the first host, once:

- **Terraform's GCP login**: `gcloud auth application-default login`. Separate from `gcloud auth login`.
- **The Tailscale tag**, once per tailnet: admin console → Access controls → Tags → Create tag: name `orca-host`, owner `autogroup:admin` (in the policy file: `"tagOwners": {"tag:orca-host": ["autogroup:admin"]}`). Tagged nodes never expire.

  ![Create tag](docs/tailscale-tag.png)
- **Tailscale on the phone**, on the same tailnet: the mobile client reaches the host over it too.

Per host, into the Secure Note:

- **`TS_AUTHKEY`**: admin console → Settings → Keys → Generate auth key: reusable off, ephemeral off, tags on with `tag:orca-host`. Read once, at the first start; after that the identity is on the data disk.

  ![Generate auth key](docs/tailscale-auth-key.png)
- **`CLAUDE_CODE_OAUTH_TOKEN`**: `claude setup-token` on the laptop.
- **`GH_TOKEN`**: a classic personal access token with the `repo` and `read:org` scopes: one token for every organisation you belong to. GHCR and multi-organisation access both rule out fine-grained tokens; the organisation must allow classic tokens (Settings → Personal access tokens). `read:org` is required by the mobile app's GitHub source picker (organisation/repo lookups over GraphQL); without it, creating a worktree from mobile fails.

  ![Token scopes](docs/github-token.png)
- **`GIT_AUTHOR_NAME`**, **`GIT_AUTHOR_EMAIL`**.

And into the Secure Note `orca-host-tfvars`: `terraform/terraform.tfvars.example`, filled in.

| Step | Today | Target |
|---|---|---|
| Tailscale tag | admin console, once per tailnet | — |
| host name, project, zone, SSH key | laptop, into the Secure Note `orca-host-tfvars` | — |
| Tailscale auth key | admin console, into the Secure Note | Tailscale API from `make secret` |
| Claude token, GitHub token, git identity | laptop, into the Secure Note | — |
| state bucket | `make bootstrap` | — |
| env file into Secret Manager | `make secret` | — |
| pairing | `make pair` | from the Orca client |
| mobile pairing | `make pair`, QR on the laptop | from the desktop client |
| first clone of a project | the app, Clone from URL | — |
| Claude Code workspace trust | first Claude pane of a project, once, covers its worktrees — as on a laptop | — |
