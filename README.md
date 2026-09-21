# orca-host

A headless [Orca](https://github.com/stablyai/orca) server on a VM, driven from the desktop or mobile client over the tailnet. **One host per person, all of their projects on it**; what belongs to a project (`orca.yaml`, worktree scripts, `.env` files) lives in the project's repository, not here.

| File | Runs on | Does |
|---|---|---|
| `create-vm.sh` | laptop | creates the GCP VM (`PROJECT=… ./create-vm.sh`) |
| `install.sh` | VM, root | system packages, Docker, `gh`, Tailscale, Orca, Claude Code, the `orca-serve` unit — idempotent |

Competing track to `qrafttech/remote-agent`, which stays in place until Orca has proven the equivalent (epistofr/episto#2062 → #2063).

## Inventory of the VM

Everything done to get `orca-host` running, in order, with who did it (script or hand) and on which machine.
Goal: **every "hand" step below becomes a script**, and nothing depends on the laptop.

## State (2026-09-21)

| | |
|---|---|
| VM | `orca-host`, GCP `qraft-remote-agent-nrouanne`, `europe-west9-b`, e2-standard-4, 100 GB pd-balanced, Debian 12 |
| Public IP | 34.155.16.240 — only 22 open (default GCP firewall) |
| Qraft tailnet | `orca-host` = `100.105.104.105` (account nicolas.rouanne@qraft.tech) |
| Orca | 1.4.205, `orca serve` on `100.105.104.105:6768`, systemd unit `orca-serve`, user `orca` |
| Claude Code | 2.1.276 in `/home/orca/.local/bin`, logged in (subscription, `~/.claude/.credentials.json`) |
| Project | `/home/orca/episto` (SSH clone, `gh` logged in as nicolasrouanne), registered in Orca (repo `58f5ce25-…`) |
| Worktrees | `/home/orca/orca/workspaces/episto/<branch>` |
| Client | Orca desktop on the laptop, environment `orca-host` (`a0da68ab-…`), active server |
| Single user | one system user `orca`: Claude login, `gh`, git identity and `.env` files are Nicolas's |

## 1. Create the VM — laptop, **script** `create-vm.sh`

```bash
PROJECT=qraft-remote-agent-nrouanne ./create-vm.sh     # NAME, ZONE, MACHINE_TYPE, DISK_SIZE can be overridden
```

Rebuild from scratch = `gcloud compute instances delete orca-host …` then the same command.

## 2. System — VM, root, **script** `install.sh`

`gcloud compute scp install.sh orca-host:~ && gcloud compute ssh orca-host -- sudo bash install.sh`. Idempotent. It does:

1. apt: Electron/Xvfb deps (Orca headless doc), `git jq curl lsof make file`
2. Docker (`get.docker.com`, Compose ≥ 2.24 — required by `bin/worktree`)
3. `gh`
4. Tailscale, `tailscale up --hostname orca-host` — **hand**: without `TS_AUTHKEY`, the script prints the URL, you approve the machine in the Tailscale admin, you rerun
5. Orca AppImage 1.4.205 extracted into `/opt/orca/squashfs-root` (no FUSE), wrapper `/usr/local/bin/orca` with `LIBGL_ALWAYS_SOFTWARE=1`
6. user `orca` (bash, `docker` group), Claude Code 2.1.276 in its `~/.local/bin` (native installer)
7. `orca-serve` unit: `AppRun serve --port 6768 --pairing-address <tailnet IP>`, `Restart=on-failure`, enabled
8. report + the command to read the pairing URL from the journal

## 3. Pairing — laptop, hand

```bash
# on the VM: the pairing URL
sudo journalctl -u orca-serve -o cat | grep '^Pairing URL:' | tail -1
# on the laptop (Orca desktop installed, laptop on the tailnet)
orca environment add --name orca-host --pairing-code '<URL>'
orca status --environment orca-host     # runtimeConnectionState: connected, graphState: ready
```

Then in the app: Settings → Remote Orca Servers → Advanced → **Active Server = orca-host**. Pairing survives service restarts.

## 4. Project — VM, user `orca`, hand (in an Orca terminal, which runs on the VM)

```bash
gh auth login                        # GitHub, SSH, browser
git clone git@github.com:epistofr/episto.git ~/episto
git config --global user.name  "Nicolas Rouanne"
git config --global user.email nicolas.rouanne@qraft.tech
# api/.env and chat/.env copied from the laptop into ~/episto (1Password: "DEV webapp .env", "DEV chat .env")
cd ~/episto && docker build -t base-episto-ruby -f api/docker/app/Dockerfile.base api   # 810 MB, ~5 min
```

Then from the laptop: `orca repo add --environment orca-host --path /home/orca/episto` (it must be a real git repository, not an empty folder).

## 5. Claude login — VM, user `orca`, hand

What **works**: open a Claude agent pane in the app (on an orca-host worktree), pick `1. Claude account with subscription`, open the URL, paste the code. Writes `~/.claude/.credentials.json`; every later pane reuses it.

What **is not enough**: `orca account add --agent claude`. It registers a "managed" account under `~/.config/orca/claude-accounts/<id>/`, but panes default to `selectionKey: host` (= the user's `~/.claude`) and ignore it. Only useful for several accounts on one host.

First launch by Orca (`claude --dangerously-skip-permissions`): Claude asks to accept bypass mode, once per machine → `bypassPermissionsModeAccepted: true` in `~/.claude.json`. To be set by `bootstrap.sh`.

Lead for scripting: `claude setup-token` (long-lived token, subscription) → `CLAUDE_CODE_OAUTH_TOKEN` in an `EnvironmentFile` of the unit. Verified: the environment of `orca-serve` is inherited by the Claude processes Orca spawns.

## 6. Per worktree — app, then hand

Created in the app: project episto (orca-host), branch name, base `origin/nr/orca-worktree-config` (the only branch carrying `orca.yaml`, PR epistofr/episto#2065 not merged), setup **Run**.

- `setup` hook (`orca.yaml`): `bin/worktree init "$ORCA_WORKTREE_PATH"` → `.env.worktree` (ports 4001/4000/6173…), copies `api/.env` and `chat/.env`. **Verified on 2026-09-21 against headless `orca serve`: runs on its own.**
- Then **hand** in the worktree's terminal: `bin/worktree start --setup-db` (brings the stack up, creates the database). To move into the `setup` hook.

Access from the laptop (tailnet): `http://100.105.104.105:4001` (API/nginx), `:4001/next` (web), `:4001/chat`.

## What is still done by hand, to script

| Step | Today | Target |
|---|---|---|
| 1 VM creation | `create-vm.sh` | explicit firewall (6768 closed, 22 from the tailnet) instead of the default rules |
| 2.4 Tailscale join | browser approval | `TS_AUTHKEY` |
| 3 pairing | laptop, `orca environment add` | Orca client — desktop or mobile, to verify |
| 4 gh / git / clone / .env / image | Orca terminal | `bootstrap.sh` (user `orca`) with `GH_TOKEN`, identity and `.env` files provided |
| 5 Claude login | Orca pane | `CLAUDE_CODE_OAUTH_TOKEN` |
| 5 bypass permissions acceptance | Orca pane, first time | `bypassPermissionsModeAccepted` in `~/.claude.json` |
| 6 stack start | worktree terminal | `setup` hook of `orca.yaml` |
