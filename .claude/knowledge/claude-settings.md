# Claude preferences on the host

Three kinds of personalization, three mechanisms: software in an image built `FROM` the base (see [architecture.md](architecture.md#your-own-image)), everything else — tokens and text — in the person's dotfiles, the one exception being the Tailscale auth key and the dotfiles' own name, in the env note.

## `CLAUDE_PERMISSION_MODE`

`default` | `acceptEdits` | `auto` | `plan`, written to `permissions.defaultMode` of `~/.claude/settings.json` at every start, after the dotfiles: a line of the env note, or an `export` of `env.sh`. Unset: Claude asks.

## The dotfiles

`DOTFILES_REPO` is a chezmoi repository. At every start the entrypoint `git pull --ff-only`s its source directory (a failed pull keeps the last copy), then runs `chezmoi init --apply --no-tty --force "$DOTFILES_REPO"`: the config is regenerated from `.chezmoi.toml.tmpl` and the home is brought to the source state. `--force` because the dotfiles win over a file edited on the host, and there is no terminal to ask. A failed apply is logged and the host comes up on what the last apply wrote: the home is on the data disk.

**1Password.** The container has `OP_SERVICE_ACCOUNT_TOKEN`, the host's, so `onepasswordRead` resolves against the host's vault. Two constraints follow:

- the config must set `[onepassword] mode = "service"`: in the default mode chezmoi refuses to run with a service-account token in the environment. The config template itself cannot call `onepasswordRead` (the mode is not set yet while it renders).
- every reference must be in that one vault: a service account is scoped per vault.

**`~/.config/orca-host/env.sh`** is the one file the host reads. It is sourced, `set -a`, before `exec orca serve`, so the variables reach every process `orca serve` starts. A `.zshrc` would not: Claude panes and MCP servers are not started by a shell, and the image has no zsh. A laptop can source the same file from its shell rc, so the list of tokens is written once. Values that only the host needs (`CLAUDE_CODE_OAUTH_TOKEN`, `GH_TOKEN`: a laptop has its own login for both) go under `{{ if eq .chezmoi.os "linux" }}`. Name it `private_env.sh.tmpl` in the source: 0600. `make shell` sources it too, since `docker exec` does not inherit what the entrypoint added. `GIT_COMMITTER_*` default to `GIT_AUTHOR_*`.

**What a laptop has and the host must not.** `.chezmoiignore` is a template: `{{ if ne .chezmoi.os "darwin" }}` around `Library/`, the `run_*-darwin` scripts, an `~/.ssh/config` with `UseKeychain` (fatal on Linux's ssh), a `.gitconfig` that signs with a key the host does not have. A `sourceDir` set in the config only for darwin: on the host the default, `~/.local/share/chezmoi`, is where the entrypoint pulls.

## Claude settings from the dotfiles

Orca writes its hooks into `~/.claude/settings.json`, Claude rewrites `~/.claude.json`: neither can be a file chezmoi replaces. A `run_after_` script merges into them with `jq`, as the base used to: `permissions` only from the settings file (hooks and status lines point at laptop things), user-level MCP servers added without overwriting one already present. `CLAUDE.md` and skills are `symlink_` entries.

A settings repository kept apart from the dotfiles is a `.chezmoiexternal` of type `git-repo`, `refreshPeriod` short enough that every start pulls it. Private, it needs a GitHub credential while chezmoi runs: git asks `gh auth git-credential` (a `credential.helper` in the image), which reads `GH_TOKEN` from the environment or gh's own `~/.config/gh/hosts.yml`. The second can be a template of the dotfiles: chezmoi applies in the alphabetical order of target paths, so `.config/gh/hosts.yml` is written before an external at `claude/`. A `run_after_` script runs after every external.

## MCP servers

The same shape as any `.mcp.json`, HTTP or stdio:

```json
{
  "mcpServers": {
    "example": { "type": "http", "url": "https://example.com/mcp" },
    "keyed": { "type": "http", "url": "https://keyed.example.com/mcp", "headers": { "Authorization": "Bearer ${KEYED_API_KEY}" } }
  }
}
```

Claude Code expands `${VAR}` in `url`, `headers`, `env` and `args` from the environment it runs in, which on the host is the env file plus `env.sh`: a token is one `onepasswordRead` there and one `${VAR}` here, and a server that takes its key in a header needs no OAuth. At start Claude warns which variables are missing; `claude mcp list` shows the same. A server that only offers OAuth needs its browser flow once per host, by hand.
