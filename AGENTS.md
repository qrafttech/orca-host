# Orca host

A VM that runs `orca serve` headless, one host per person, all of that person's projects on it. The desktop and mobile Orca clients pair with it over the Qraft tailnet; nothing is published on the public IP.

## Rules of this repository

- **English only**, everywhere: README, script comments, commit messages, pull requests. Source material that arrives in French (issue comments, call notes) is translated on the way in.
- **The host is generic.** Nothing in `Dockerfile`, `compose.yaml` or `terraform/` knows a project. What a project needs on a worktree (`orca.yaml`, worktree scripts, `.env` files, base images) lives in that project's repository and runs from its setup hook.
- **Nothing is installed at run time.** The image is a base; a person's own tools are their own image, `FROM` it, built by their own CI and named in `orca_image`. No mechanism here downloads, unpacks or installs software after the build — not even a generic one that names no tool.
- **What must survive a rebuild is under `/var/lib/orca`**, Docker's data root included. The boot disk is Flatcar and nothing else; it is replaced with the VM. A project's databases are worktree databases: its setup hook creates them, its archive script removes them, nothing migrates them.
- **No secrets, no per-person values in the tree.** Tokens (`TS_AUTHKEY`, `GH_TOKEN`, `CLAUDE_CODE_OAUTH_TOKEN`), git identity and `.env` contents come in as environment variables at run time. Where a person keeps them (1Password, a file outside the repo) is theirs.
- **Everything is declarative and idempotent**: a file says at the top where it runs and what it needs; applying it twice changes nothing.
- **Plain facts, no state, no history.** The README says what a host is and how one is brought up, not what was done on which day, on which machine, for which project. No dates, no IPs, no IDs, no project or client names, no reference to other repositories or issues. What happened lives in the git log and in the issue trackers of the projects that use the host.
- **The README is the quickstart**, for a person: short, the steps and the commands. How it works and why goes to `.claude/knowledge/` (table below), not to the README.
- **The table at the end of this file is the specification.** Every step is marked *script* or *by hand*; the goal is that every *by hand* row becomes a *script* row. A new manual step is added to the table before it is automated, not after.
- **Pinned versions.** Orca is pinned to the desktop client's version (protocol compatibility); Claude Code is pinned. A bump is a commit that says why.

## Knowledge base

| File | Covers |
|---|---|
| [architecture.md](.claude/knowledge/architecture.md) | where things run, image and derived images, entrypoint, CI, stack, VM and Ignition, network, disks and sizing, restart vs rebuild, pairing, GitHub token, workspace trust |
| [claude-settings.md](.claude/knowledge/claude-settings.md) | `CLAUDE_PERMISSION_MODE`, the settings repository, `config/mcp.json` |

## Setup steps: script or by hand

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
