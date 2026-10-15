#!/usr/bin/env bash
# Empties Orca's worktree trash. Orca deletes a worktree by moving it to `.orca-worktree-trash/wt-<timestamp>-<id>`,
# next to the project's worktrees, then removing it; the removal fails on a file `orca` does not own, as those a
# project's root containers write through the bind mount. Whatever is in that trash, Orca put there to delete it: every
# `wt-*` in an `.orca-worktree-trash` under /home/orca is removed, whoever owns it. Nothing else, no computed path.
# One pass, one line per worktree removed. Runs in the orca-host container, as root, every 5 minutes from the
# entrypoint.
set -euo pipefail

# depth 4: /home/orca/<root>/workspaces/<project>/.orca-worktree-trash, without walking every checkout
find /home/orca -maxdepth 4 -type d -name .orca-worktree-trash -print0 2>/dev/null \
  | while IFS= read -r -d '' trash; do
      for wt in "$trash"/wt-*; do
        [ -e "$wt" ] || continue
        if rm -rf "$wt"; then echo "empty-trash: $wt removed"; else echo "empty-trash: $wt: rm failed"; fi
      done
    done
