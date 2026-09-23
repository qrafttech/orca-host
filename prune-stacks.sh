#!/usr/bin/env bash
# Tears down the compose stacks of deleted worktrees. Every container compose starts carries two labels, its project
# and the directory it was started from; a project whose directory is under /home/orca and no longer exists is taken
# down, volumes included. `docker compose -p <name> down -v` acts on the labels: no compose file needed. Anything
# started elsewhere (a laptop's /Users/..., the host's own /opt/orca) is out of reach. One pass, one line per stack
# torn down. Runs in the orca-host container, as `orca`, every 5 minutes from the entrypoint; needs the Docker socket.
set -euo pipefail

# From /: run in a directory that holds a compose file, compose would take that file's services instead of the labels.
cd /

docker ps -a --format '{{.Label "com.docker.compose.project"}} {{.Label "com.docker.compose.project.working_dir"}}' \
  | sort -u | while read -r project dir; do
      case "$dir" in /home/orca/*) ;; *) continue ;; esac
      [ ! -d "$dir" ] || continue
      if out=$(docker compose -p "$project" down -v 2>&1); then
        echo "prune-stacks: $project torn down, $dir is gone"
      else
        echo "prune-stacks: $project: down -v failed, $dir is gone: $out"
      fi
    done
