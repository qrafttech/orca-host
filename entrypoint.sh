#!/usr/bin/env bash
# orca-host entrypoint. Starts as root: gives `orca` the Docker socket's group and its home, then re-executes
# as `orca`, applies your dotfiles and runs `orca serve`. Environment: DOTFILES_REPO (optional), PAIRING_ADDRESS
# (optional: default is the tailscale0 address, waited for), ORCA_PORT (6768), ORCA_PAIRING (desktop | mobile).
# shellcheck disable=SC2016  # $m, $v below are jq variables
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
# Your dotfiles: DOTFILES_REPO is anything `chezmoi init` takes (<owner>/<repo>, a URL), pulled and applied into
# the home at every start. Their templates read 1Password with OP_SERVICE_ACCOUNT_TOKEN, the host's own token, so
# a session's tokens come from the same items as your laptop's. ~/.config/orca-host/env.sh, if they write one, is
# sourced before `orca serve`: every Claude pane, every MCP server, every terminal sees its variables. A failed
# pull or apply keeps what the last one wrote: the home is on the data disk.
if [ -n "${DOTFILES_REPO:-}" ]; then
  src=$(chezmoi source-path)
  [ ! -d "$src/.git" ] || git -C "$src" pull -q --ff-only || echo "dotfiles: pull failed, applying the last copy"
  chezmoi init --apply --no-tty --force "$DOTFILES_REPO" || echo "dotfiles: apply failed, keeping the last files"
fi
if [ -f .config/orca-host/env.sh ]; then
  # shellcheck source=/dev/null
  { set -a +u; . .config/orca-host/env.sh; } || echo "dotfiles: env.sh failed, starting with what it set"
  set +a -u
fi
# git's committer is its author, unless set apart
[ -z "${GIT_AUTHOR_NAME:-}" ] || export GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-$GIT_AUTHOR_NAME}"
[ -z "${GIT_AUTHOR_EMAIL:-}" ] || export GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-$GIT_AUTHOR_EMAIL}"

# Claude Code's first-run questions (theme, login, bypass-permissions acceptance), answered up front. Merged at
# every start: Claude rewrites this file. Workspace trust is per project and stays a question: it is keyed on the
# checkout, covers its worktrees, and a checkout nested in a trusted folder is excluded by design.
[ -f .claude.json ] || echo '{}' > .claude.json
jq --arg v "$(claude --version | cut -d' ' -f1)" \
  '. + {hasCompletedOnboarding: true, lastOnboardingVersion: $v, theme: "dark", bypassPermissionsModeAccepted: true}' \
  .claude.json > .claude.json.tmp && mv .claude.json.tmp .claude.json
# The permission mode of interactive panes, merged into the user settings (Orca writes its hooks there too, so
# never overwritten): CLAUDE_PERMISSION_MODE, default | acceptEdits | auto | plan. Everything else of yours —
# permissions, CLAUDE.md, skills, MCP servers — is your dotfiles' business, above.
mkdir -p .claude
[ -f .claude/settings.json ] || echo '{}' > .claude/settings.json
if [ -n "${CLAUDE_PERMISSION_MODE:-}" ]; then
  jq --arg m "$CLAUDE_PERMISSION_MODE" '.permissions.defaultMode = $m' .claude/settings.json > .claude/settings.json.tmp \
    && mv .claude/settings.json.tmp .claude/settings.json
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
