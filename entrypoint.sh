#!/usr/bin/env bash
# orca-host entrypoint. Starts as root: gives `orca` the Docker socket's group and its home, then re-executes
# as `orca` and runs `orca serve`. Environment: PAIRING_ADDRESS (optional: default is the tailscale0 address,
# waited for), ORCA_PORT (6768), ORCA_PAIRING (desktop | mobile).
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
# Claude Code's first-run questions (theme, login, bypass-permissions acceptance) answered up front, and the home
# trusted as a workspace, which covers every worktree under it. Merged at every start: Claude rewrites this file.
[ -f .claude.json ] || echo '{}' > .claude.json
jq --arg v "$(claude --version | cut -d' ' -f1)" --arg home "$HOME" \
  '. + {hasCompletedOnboarding: true, lastOnboardingVersion: $v, theme: "dark", bypassPermissionsModeAccepted: true}
   | .projects[$home] += {hasTrustDialogAccepted: true}' \
  .claude.json > .claude.json.tmp && mv .claude.json.tmp .claude.json

if [ -z "${PAIRING_ADDRESS:-}" ]; then
  echo "waiting for tailscale0"
  until PAIRING_ADDRESS=$(ip -4 -o addr show tailscale0 2>/dev/null | awk '{print $4}' | cut -d/ -f1) \
     && [ -n "$PAIRING_ADDRESS" ]; do sleep 2; done
fi

pairing=()
[ "$ORCA_PAIRING" != mobile ] || pairing=(--mobile-pairing)
exec /opt/orca/AppRun serve --port "$ORCA_PORT" --pairing-address "$PAIRING_ADDRESS" "${pairing[@]}" --json "$@"
