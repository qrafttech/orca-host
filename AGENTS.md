# Orca host

A VM that runs `orca serve` headless, one host per person, all of that person's projects on it. The desktop and mobile Orca clients pair with it over the Qraft tailnet; nothing is published on the public IP.

## Rules of this repository

- **English only**, everywhere: README, script comments, commit messages, pull requests. Source material that arrives in French (issue comments, call notes) is translated on the way in.
- **The host is generic.** Nothing in `Dockerfile`, `compose.yaml` or `terraform/` knows a project. What a project needs on a worktree (`orca.yaml`, worktree scripts, `.env` files, base images) lives in that project's repository and runs from its setup hook.
- **No secrets, no per-person values in the tree.** Tokens (`TS_AUTHKEY`, `GH_TOKEN`, `CLAUDE_CODE_OAUTH_TOKEN`), git identity and `.env` contents come in as environment variables at run time. Where a person keeps them (1Password, a file outside the repo) is theirs.
- **Everything is declarative and idempotent**: a file says at the top where it runs and what it needs; applying it twice changes nothing.
- **Plain facts, no state, no history.** The README says what a host is and how one is brought up, not what was done on which day, on which machine, for which project. No dates, no IPs, no IDs, no project or client names, no reference to other repositories or issues. What happened lives in the git log and in the issue trackers of the projects that use the host.
- **The README's last table is the specification.** Every step is marked *script* or *by hand*; the goal is that every *by hand* row becomes a *script* row. A new manual step is added to the table before it is automated, not after.
- **Pinned versions.** Orca is pinned to the desktop client's version (protocol compatibility); Claude Code is pinned. A bump is a commit that says why.
