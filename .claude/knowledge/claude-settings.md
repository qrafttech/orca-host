# Claude preferences on the host

Text, and text only. The settings repository carries what should change without a rebuild: a permission, a `CLAUDE.md`, a skill, an MCP server declaration. Software — binaries, MCP server implementations — is not here: it is an image built `FROM` the base, see [architecture.md](architecture.md#your-own-image). Three kinds of personalization, three mechanisms: text here, software in an image, secrets in the env file.

Two optional variables in the env file, both merged into `~/.claude/settings.json` at every start. Orca writes its hooks to that file too, so it is merged, never overwritten.

- `CLAUDE_PERMISSION_MODE`: `default` | `acceptEdits` | `auto` | `plan`, written to `permissions.defaultMode`.
- `CLAUDE_SETTINGS_REPO`: `<owner>/<repo>`, cloned into `~/claude` with `GH_TOKEN`, pulled `--ff-only` at every start (a failed pull keeps the last copy). From it:
  - `permissions` from `CLAUDE_SETTINGS_FILE` (default `settings.json`). Only that key: hooks and status lines point at laptop things.
  - a root `CLAUDE.md`, symlinked to `~/.claude/CLAUDE.md` unless one exists
  - `.claude/skills`, symlinked to `~/.claude/skills` unless one exists
  - `config/mcp.json`: merged into the user-level MCP servers of `~/.claude.json`, never overwriting a server already present (added by hand, or from a previous merge with local edits). Its `${VAR}` are read from the container's environment, which is the env file.

Neither set: Claude's defaults, it asks.

## `config/mcp.json`

The same shape as any `.mcp.json`, HTTP or stdio:

```json
{
  "mcpServers": {
    "example": { "type": "http", "url": "https://example.com/mcp" },
    "keyed": { "type": "http", "url": "https://keyed.example.com/mcp", "headers": { "Authorization": "Bearer ${KEYED_API_KEY}" } }
  }
}
```

Claude Code expands `${VAR}` in `url`, `headers`, `env` and `args` from the environment it runs in, which on the host is the env file: a token is one line there and one `${VAR}` here, and a server that takes its key in a header needs no OAuth. At start Claude warns which variables are missing; `claude mcp list` shows the same. A server that only offers OAuth needs its browser flow once per host, by hand.

Commit, push, and `make restart`: the repository is pulled at every start. Setting `CLAUDE_SETTINGS_REPO` for the first time is a new secret version: `make secret`, then `make restart`.
