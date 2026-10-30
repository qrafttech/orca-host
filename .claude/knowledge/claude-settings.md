# Claude settings on the host

The settings repository holds text only, what should change without a rebuild: permissions, a `CLAUDE.md`, skills, MCP server declarations. The MCP servers themselves are software, so they go in the person's own image ([architecture.md](architecture.md#your-own-image)).

Two optional variables in `.env.tpl`, both merged into `~/.claude/settings.json` at every start. Orca writes its hooks to that same file, so it is merged, never overwritten.

- `CLAUDE_PERMISSION_MODE`: `default`, `acceptEdits`, `auto` or `plan`, written to `permissions.defaultMode`.
- `CLAUDE_SETTINGS_REPO`: `<owner>/<repo>`, cloned into `~/claude` with `GH_TOKEN` and pulled at every start (if the pull fails, the last copy stays). From it the host takes:
  - `permissions` from `settings.json` (or the file `CLAUDE_SETTINGS_FILE` names), and only that key: hooks and status lines point at things on a laptop;
  - `CLAUDE.md` at the root, linked as `~/.claude/CLAUDE.md` unless one already exists;
  - `.claude/skills`, linked as `~/.claude/skills` unless one already exists;
  - `config/mcp.json`, which replaces the user-level MCP servers at every start: a server changed or removed there is changed or removed on the host.

With neither variable, Claude uses its defaults and asks.

## `config/mcp.json`

The same shape as any `.mcp.json`, HTTP or stdio:

```json
{
  "mcpServers": {
    "sentry": { "type": "http", "url": "https://mcp.sentry.dev/mcp" },
    "fireflies": { "type": "http", "url": "https://api.fireflies.ai/mcp", "headers": { "Authorization": "Bearer ${FIREFLIES_API_KEY}" } },
    "notion": { "command": "notion-mcp-server", "env": { "NOTION_TOKEN": "${NOTION_TOKEN}" } }
  }
}
```

Claude fills each `${VAR}` from its environment, which on the host is the env file rendered from `.env.tpl`: a token is one line there and one `${VAR}` here. At start Claude warns about missing variables; `claude mcp list` shows the same. A server that only offers OAuth needs its browser login once per host, by hand. A stdio server's command must be in the image.

To change something: commit, push, then `make restart`.
