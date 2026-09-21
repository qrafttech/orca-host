# orca-host

A headless [Orca](https://github.com/stablyai/orca) server on a VM, driven from the desktop or mobile Orca client over the Qraft tailnet. One host per person, all of their projects on it. What belongs to a project (`orca.yaml`, worktree scripts, `.env` files, base images) lives in the project's repository, not here.

| File | Runs on | Does |
|---|---|---|
| `create-vm.sh` | laptop | creates the GCP VM |
| `install.sh` | VM, root | system packages, Docker, `gh`, Tailscale, Orca, Claude Code, the `orca-serve` unit — idempotent |

## Layout

- VM: Debian 12, e2-standard-4 (4 vCPU / 16 GB), 100 GB pd-balanced by default. A Docker Compose stack takes ~4 GB RAM and ~12 GB disk; disk binds before RAM.
- Network: the VM is on the tailnet; `orca serve` advertises its tailnet IP and listens on `0.0.0.0:6768`. The GCP firewall is the only guard on the public IP: 22 only, by default. Clients pair over the tailnet, without a tunnel.
- `/opt/orca/squashfs-root/AppRun`: the Orca AppImage, extracted (no FUSE on Debian cloud images), exposed as `/usr/local/bin/orca` with `LIBGL_ALWAYS_SOFTWARE=1`.
- `orca`: the one system user, bash login, in the `docker` group. Owns the Claude login, the `gh` login, the git identity and every project checkout. Claude Code is in its `~/.local/bin`.
- `/home/orca/<project>`: the project checkouts. `/home/orca/orca/workspaces/<project>/<branch>`: the worktrees Orca creates.
- `orca-serve`: the systemd unit, `AppRun serve --port 6768 --pairing-address <tailnet IP>`, `Restart=on-failure`, enabled. No auto-update in serve mode. The environment of the unit is inherited by every Claude process Orca spawns.
- Versions are pinned in `install.sh`: Orca to the desktop client's version (protocol compatibility), Claude Code to a release.

## 1. Create the VM — laptop, `create-vm.sh`

```bash
PROJECT=<gcp project> ./create-vm.sh     # NAME, ZONE, MACHINE_TYPE, DISK_SIZE can be overridden
```

Rebuild from scratch: `gcloud compute instances delete <name> --project <project> --zone <zone>`, then the same command.

## 2. Install — VM, root, `install.sh`

```bash
gcloud compute scp install.sh <name>:~ --project <project> --zone <zone>
gcloud compute ssh <name> --project <project> --zone <zone> -- sudo bash install.sh
```

Idempotent. In order:

1. apt: Electron/Xvfb runtime deps (Orca headless doc), `git jq curl lsof make file`
2. Docker from `get.docker.com` (Debian's `docker.io` lacks Compose ≥ 2.24)
3. `gh`
4. Tailscale, `tailscale up --hostname <name>`. Without `TS_AUTHKEY`, the script prints the login URL and exits 2: approve the machine in the Tailscale admin, rerun. With `TS_AUTHKEY`, the join is non-interactive.
5. Orca AppImage, extracted, wrapper
6. user `orca`, Claude Code in its `~/.local/bin` (native installer, no Node)
7. `orca-serve` unit
8. a report, and the command that reads the pairing URL from the journal

## 3. Pair — laptop, by hand

```bash
# on the VM: the pairing URL
sudo journalctl -u orca-serve -o cat | grep '^Pairing URL:' | tail -1
# on the laptop (Orca desktop installed, laptop on the tailnet)
orca environment add --name <name> --pairing-code '<URL>'
orca status --environment <name>     # runtimeConnectionState: connected, graphState: ready
```

Then in the app: Settings → Remote Orca Servers → Advanced → **Active Server = <name>**. Pairing survives service restarts.

## 4. Add a project — VM, user `orca`, by hand

In an Orca terminal, which runs on the VM:

```bash
gh auth login                        # GitHub, SSH, browser
git config --global user.name  "<name>"
git config --global user.email <email>
git clone git@github.com:<owner>/<project>.git ~/<project>
# then the project's gitignored files (.env …), from wherever they are kept; dev values only
```

Then from the laptop: `orca repo add --environment <name> --path /home/orca/<project>`. The path must be a git repository, not an empty folder.

## 5. Claude login — VM, user `orca`, by hand

What works: open a Claude agent pane in the app, on a worktree of this host, pick `1. Claude account with subscription`, open the URL, paste the code. Writes `~/.claude/.credentials.json`; every later pane reuses it. There is no keyring on the VM: the credentials are in clear under `/home/orca`. Never copy that file.

What is not enough: `orca account add --agent claude`. It registers a "managed" account under `~/.config/orca/claude-accounts/<id>/`, but panes default to `selectionKey: host` (= the user's `~/.claude`) and ignore it. Only useful for several accounts on one host.

First launch by Orca (`claude --dangerously-skip-permissions`): Claude asks to accept bypass mode, once per machine → `bypassPermissionsModeAccepted: true` in `~/.claude.json`.

## 6. Worktrees — app

A worktree is created in the app: project, branch name, base branch, setup **Run**. The project's `orca.yaml` `setup` hook runs on the VM, against `orca serve`, without a renderer. Whatever the hook starts is reachable from the laptop at `http://<tailnet IP>:<port>`.

## By hand today, to script

| Step | Today | Target |
|---|---|---|
| 1 VM creation | `create-vm.sh` | an explicit firewall rule (6768 closed, 22 from the tailnet only) instead of the defaults |
| 2.4 Tailscale join | browser approval | `TS_AUTHKEY` |
| 3 pairing | laptop, `orca environment add` | from the Orca client, desktop or mobile |
| 4 gh, git identity, clone, gitignored files | Orca terminal | `bootstrap.sh` as user `orca`, with `GH_TOKEN`, identity and files provided |
| 5 Claude login | Orca pane | `claude setup-token` → `CLAUDE_CODE_OAUTH_TOKEN` in an `EnvironmentFile` of the unit |
| 5 bypass permissions acceptance | Orca pane, first time | `bypassPermissionsModeAccepted` in `~/.claude.json`, set by `bootstrap.sh` |
