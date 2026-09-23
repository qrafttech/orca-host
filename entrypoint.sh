#!/usr/bin/env bash
# orca-host entrypoint. Starts as root: gives `orca` the Docker socket's group and its home, then re-executes
# as `orca` and runs `orca serve`. Environment: PAIRING_ADDRESS (optional: default is the tailscale0 address,
# waited for), ORCA_PORT (6768), ORCA_PAIRING (desktop | mobile).
# shellcheck disable=SC2016  # $m, $s below are jq variables
set -euo pipefail

: "${ORCA_PORT:=6768}"
: "${ORCA_PAIRING:=desktop}"

if [ "$(id -u)" = 0 ]; then
  if [ -S /var/run/docker.sock ]; then
    gid=$(stat -c %g /var/run/docker.sock)
    getent group "$gid" >/dev/null || groupadd -g "$gid" docker-host
    usermod -aG "$(getent group "$gid" | cut -d: -f1)" orca
  fi
  # /home/orca is a volume: empty and root-owned the first time
  [ "$(stat -c %u /home/orca)" = "$(id -u orca)" ] || chown orca:orca /home/orca
  exec runuser -u orca --preserve-environment -- "$0" "$@"
fi

export HOME=/home/orca
cd "$HOME"
# Binaries a settings repo installs for itself (config/bin.json below) land in ~/bin, on the volume, not the
# image — every user's tool choices, none of them baked into this shared image.
export PATH="$HOME/bin:$PATH"
# Claude Code's first-run questions (theme, login, bypass-permissions acceptance), answered up front. Merged at
# every start: Claude rewrites this file. Workspace trust is per project and stays a question: it is keyed on the
# checkout, covers its worktrees, and a checkout nested in a trusted folder is excluded by design.
[ -f .claude.json ] || echo '{}' > .claude.json
jq --arg v "$(claude --version | cut -d' ' -f1)" \
  '. + {hasCompletedOnboarding: true, lastOnboardingVersion: $v, theme: "dark", bypassPermissionsModeAccepted: true}' \
  .claude.json > .claude.json.tmp && mv .claude.json.tmp .claude.json
# Your Claude preferences, two optional ways, both merged into the user settings (Orca writes its hooks there too,
# so never overwritten):
#   CLAUDE_PERMISSION_MODE   default | acceptEdits | auto | plan — the permission mode of interactive panes
#   CLAUDE_SETTINGS_REPO     <owner>/<repo>, cloned with GH_TOKEN and pulled at every start: `permissions` is taken
#                            from CLAUDE_SETTINGS_FILE (only that: hooks and status lines point at laptop things),
#                            and a CLAUDE.md and a .claude/skills at the repository root become the global ones.
mkdir -p .claude
[ -f .claude/settings.json ] || echo '{}' > .claude/settings.json
settings() { jq "$@" .claude/settings.json > .claude/settings.json.tmp && mv .claude/settings.json.tmp .claude/settings.json; }
if [ -n "${CLAUDE_PERMISSION_MODE:-}" ]; then
  settings --arg m "$CLAUDE_PERMISSION_MODE" '.permissions.defaultMode = $m'
fi
if [ -n "${CLAUDE_SETTINGS_REPO:-}" ]; then
  repo="$HOME/claude"
  if [ -d "$repo/.git" ]; then git -C "$repo" pull -q --ff-only || echo "settings repo: pull failed, keeping the last copy"
  else gh repo clone "$CLAUDE_SETTINGS_REPO" "$repo" -- -q || echo "settings repo: clone failed"
  fi
  file="$repo/${CLAUDE_SETTINGS_FILE:-settings.json}"
  [ ! -f "$file" ] || settings --slurpfile s "$file" '.permissions = $s[0].permissions'
  [ -e .claude/CLAUDE.md ] || [ ! -f "$repo/CLAUDE.md" ] || ln -s "$repo/CLAUDE.md" .claude/CLAUDE.md
  [ -e .claude/skills ] || [ ! -d "$repo/.claude/skills" ] || ln -s "$repo/.claude/skills" .claude/skills
  # User-level MCP servers (config/mcp.json in the settings repo): merged in, never overwriting a server
  # already present (manually added, or from a previous merge with local edits).
  mcpfile="$repo/config/mcp.json"
  if [ -f "$mcpfile" ]; then
    jq --slurpfile m "$mcpfile" '.mcpServers = (($m[0].mcpServers // {}) + (.mcpServers // {}))' \
      .claude.json > .claude.json.tmp && mv .claude.json.tmp .claude.json
  fi
  # Binaries a settings repo wants on PATH (config/bin.json: {"bin": {"<name>": {"<amd64|arm64>": {"url",
  # "sha256"}}}}), fetched into ~/bin — generic (this script never names a specific tool), whatever's declared,
  # checksum-verified, skipped once already installed and matching.
  binfile="$repo/config/bin.json"
  if [ -f "$binfile" ]; then
    mkdir -p bin
    arch=$(uname -m); case "$arch" in x86_64) arch=amd64 ;; aarch64) arch=arm64 ;; esac
    for name in $(jq -r '.bin | keys[]' "$binfile"); do
      url=$(jq -r --arg n "$name" --arg a "$arch" '.bin[$n][$a].url // empty' "$binfile")
      sha=$(jq -r --arg n "$name" --arg a "$arch" '.bin[$n][$a].sha256 // empty' "$binfile")
      if [ -z "$url" ] || [ -z "$sha" ]; then echo "bin/$name: no $arch build declared, skipping"; continue; fi
      dest="bin/$name"
      [ ! -f "$dest" ] || ! echo "$sha  $dest" | sha256sum -c - >/dev/null 2>&1 || continue
      curl -fsSL -o "$dest.tmp" "$url" \
        && echo "$sha  $dest.tmp" | sha256sum -c - \
        && install -m 755 "$dest.tmp" "$dest" \
        || echo "bin/$name: install failed, keeping the last copy"
      rm -f "$dest.tmp"
    done
  fi
fi

# The stacks of deleted worktrees, torn down within 5 minutes, volumes included: see prune-stacks. Orca does not
# tell the host about a delete, so a loop, for as long as the container runs.
(while :; do prune-stacks || true; sleep 300; done) &

if [ -z "${PAIRING_ADDRESS:-}" ]; then
  echo "waiting for tailscale0"
  until PAIRING_ADDRESS=$(ip -4 -o addr show tailscale0 2>/dev/null | awk '{print $4}' | cut -d/ -f1) \
     && [ -n "$PAIRING_ADDRESS" ]; do sleep 2; done
fi

pairing=()
[ "$ORCA_PAIRING" != mobile ] || pairing=(--mobile-pairing)
exec /opt/orca/AppRun serve --port "$ORCA_PORT" --pairing-address "$PAIRING_ADDRESS" "${pairing[@]}" --json "$@"
