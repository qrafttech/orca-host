#!/usr/bin/env bash
# Tears down what a deleted worktree leaves in Docker. Every container compose starts carries two labels, its project
# and the directory it was started from; a project whose directory is under /home/orca and no longer exists is taken
# down, volumes and the images compose built for it included (`--rmi local`: a pulled `postgres` stays).
# `docker compose -p <name> down` acts on the labels: no compose file needed. Anything started elsewhere (a laptop's
# /Users/..., the host's own /opt/orca) is out of reach. Then the build cache is capped at BUILD_CACHE_MAX (10GB),
# least recently used first: the layers of those images are cache too. One pass, one line per stack torn down and per
# cache prune that freed something. Runs in the orca-host container, as `orca`, every 5 minutes from the entrypoint;
# needs the Docker socket.
set -euo pipefail

: "${BUILD_CACHE_MAX:=10GB}"

# From /: run in a directory that holds a compose file, compose would take that file's services instead of the labels.
cd /

docker ps -a --format '{{.Label "com.docker.compose.project"}} {{.Label "com.docker.compose.project.working_dir"}}' \
  | sort -u | while read -r project dir; do
      case "$dir" in /home/orca/*) ;; *) continue ;; esac
      [ ! -d "$dir" ] || continue
      if out=$(docker compose -p "$project" down -v --rmi local 2>&1); then
        echo "prune-stacks: $project torn down, $dir is gone"
      else
        echo "prune-stacks: $project: down failed, $dir is gone: $out"
      fi
    done

if out=$(docker builder prune -f --max-used-space "$BUILD_CACHE_MAX" 2>&1); then
  freed=$(echo "$out" | awk '/^Total:/ {print $2}')
  [ "$freed" = 0B ] || echo "prune-stacks: build cache capped at $BUILD_CACHE_MAX, $freed freed"
else
  echo "prune-stacks: build cache prune failed: $out"
fi
