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

`orca serve` from the official AppImage, Claude Code, `gh`, `git`, the Docker CLI with compose. Runs as the unprivileged user `orca`; the entrypoint gives it the Docker socket's group, waits for `tailscale0` (or takes `PAIRING_ADDRESS`), seeds `~/.claude.json` with the bypass-permissions acceptance, and execs `orca serve --json`. Versions are build args at the top of the `Dockerfile`; a bump is a PR that says why.

CI builds every push, runs the ready-contract smoke test, and pushes `ghcr.io/qrafttech/orca-host:<branch>` and `:sha-<sha>`; `main` also gets a multi-arch build. `make build` builds `orca-host:dev` for this machine.

## The stack

`compose.yaml` is the whole contract of a host: every personal value is a variable, listed at the top of the file. They come from one env file, one per host:

```
TS_AUTHKEY=tskey-auth-...          tagged tag:orca-host, preauthorized, single-use; read on the first start only
CLAUDE_CODE_OAUTH_TOKEN=...        from `claude setup-token`
GH_TOKEN=...                       repo, read:packages
GIT_AUTHOR_NAME=...
GIT_AUTHOR_EMAIL=...
ORCA_PAIRING=desktop               or mobile
```

The file lives in a 1Password item, in one field, `OP` in the `Makefile`. `make env` renders it to `./env` for a laptop; `make secret` sends it to the host's secret. 1Password is never on the host.

Tailscale identity, Orca state and checkouts are under `ORCA_DATA` on the host (`/var/lib/orca` on the VM). Stopping the stack ends live terminals, as a service restart does.

On a Mac, `make up`: `compose.laptop.yaml` drops the Tailscale service (Docker Desktop has no `/dev/net/tun` and no host network), publishes 6768 and advertises the laptop's own tailnet IP. Docker Desktop bind mounts refuse the unix sockets Orca needs, so the home is a named volume there.

## The host

One person, one `terraform apply`, one state. `terraform.tfvars` (gitignored) holds the name, project, zone, size and your SSH public key; state goes to a bucket in your project.

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars   # fill in
make bootstrap   # once per project: the state bucket
make init
make apply       # VPC, service account, secret, data disk + daily snapshots, VM
make secret      # the env file, from 1Password, into Secret Manager
make pair        # pairing URL over the tailnet → `orca environment add`
```

The VM is Flatcar Container Linux: immutable, Docker built in, nothing installed, updates itself. Ignition, rendered by Terraform from `terraform/ignition.yaml.tftpl`, is everything the VM is: the SSH key, the data-disk filesystem and mount, `/home/orca → /var/lib/orca/home`, `compose.yaml`, and two units: `orca-env.service` fetches the secret with the VM's own service account (retrying until a version exists), `orca.service` runs `docker compose up -d` from the `docker:cli` image. Rotate a secret: `make secret`, reboot.

Network: own VPC, no firewall rule, so nothing reaches the VM from the internet. SSH answers on the tailnet address only: `ssh core@<name>` (`make ssh`, `make logs`). Without Tailscale, the serial console shows the boot log.

Rebuild the VM: `terraform -chdir=terraform apply -replace=google_compute_instance.vm`. The data disk keeps the checkouts, the Tailscale identity and the pairing. The disk has `prevent_destroy`; the images on the boot disk are pulled again.

## Pairing and projects

`make pair` reads the `orca_server_ready` line from the container's logs and hands `pairing.url` to `orca environment add`. Then in the app: Settings → Remote Orca Servers → Advanced → Active Server. For a phone: `ORCA_PAIRING=mobile` in the env file, `make secret`, restart the stack, and scan the QR of the URL (`qrencode -t ansiutf8 '<URL>'`). The URL is a credential; pairing survives restarts and rebuilds.

Add a project from the laptop: `orca repo add --environment <name> --path /home/orca/<project>` after `gh repo clone <owner>/<project> /home/orca/<project>` in an Orca terminal. `git` authenticates through `gh` with `GH_TOKEN`: no login, no key. A worktree's setup hook runs `docker compose` on the VM's Docker; what it starts is reachable at `http://<tailnet IP>:<port>`.

## By hand, and to script

| Step | Today | Target |
|---|---|---|
| Tailscale ACL: `"tagOwners": {"tag:orca-host": ["autogroup:admin"]}` | admin console, once per tailnet | — |
| Tailscale auth key, tagged, preauthorized, single-use | admin console, into the 1Password item | Tailscale API from `make secret` |
| `claude setup-token`, GitHub token, git identity | laptop, into the 1Password item | — |
| state bucket | `make bootstrap` | — |
| env file into Secret Manager | `make secret` | — |
| pairing | `make pair` | from the Orca client |
| mobile pairing | `ORCA_PAIRING=mobile`, `make secret`, restart, QR on the laptop | from the desktop client |
| first clone of a project | Orca terminal, `gh repo clone` | `orca repo add` clones |
