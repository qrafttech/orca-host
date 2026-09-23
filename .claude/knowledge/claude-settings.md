# Claude preferences on the host

Two optional variables in the env file, both merged into `~/.claude/settings.json` at every start. Orca writes its hooks to that file too, so it is merged, never overwritten.

- `CLAUDE_PERMISSION_MODE`: `default` | `acceptEdits` | `auto` | `plan`, written to `permissions.defaultMode`.
- `CLAUDE_SETTINGS_REPO`: `<owner>/<repo>`, cloned into `~/claude` with `GH_TOKEN`, pulled `--ff-only` at every start (a failed pull keeps the last copy). From it:
  - `permissions` from `CLAUDE_SETTINGS_FILE` (default `settings.json`). Only that key: hooks and status lines point at laptop things.
  - a root `CLAUDE.md`, symlinked to `~/.claude/CLAUDE.md` unless one exists
  - `.claude/skills`, symlinked to `~/.claude/skills` unless one exists
  - `config/mcp.json`: merged into the user-level MCP servers of `~/.claude.json`, never overwriting a server already present (added by hand, or from a previous merge with local edits)
  - `config/bin.json`: binaries installed into `~/bin`, on the volume and on `PATH`, checksum-verified, skipped when already installed and matching. The image never names a tool: every user's tool choices, none baked in.

Neither set: Claude's defaults, it asks.

## `config/mcp.json`

The same shape as any `.mcp.json`, HTTP or stdio:

```json
{
  "mcpServers": {
    "example": { "type": "http", "url": "https://example.com/mcp" }
  }
}
```

## `config/bin.json`

One entry per binary, one URL and sha256 per architecture. A missing architecture is skipped with a message; a failed download or checksum keeps the last copy.

```json
{
  "bin": {
    "example-tool": {
      "amd64": { "url": "https://example.com/example-tool-linux-amd64", "sha256": "<sha256sum of that file>" },
      "arm64": { "url": "https://example.com/example-tool-linux-arm64", "sha256": "<sha256sum of that file>" }
    }
  }
}
```

Commit, push, and `make restart`: the repository is pulled at every start. Setting `CLAUDE_SETTINGS_REPO` for the first time is a new secret version: `make secret`, then `make restart`.
