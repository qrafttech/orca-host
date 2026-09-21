#!/usr/bin/env bash
# orca-host — create the VM on GCP. Run from the laptop. Then: scp install.sh, ssh, sudo bash install.sh.
# Rebuild from scratch = `gcloud compute instances delete $NAME --project $PROJECT --zone $ZONE`, then this again.
set -euo pipefail

NAME="${NAME:-orca-host}"
PROJECT="${PROJECT:?GCP project id (e.g. qraft-remote-agent-nrouanne)}"
ZONE="${ZONE:-europe-west9-b}"
MACHINE_TYPE="${MACHINE_TYPE:-e2-standard-4}"   # ~3.9 GB RAM per episto stack: 4 vCPU / 16 GB = 3 stacks + Orca
DISK_SIZE="${DISK_SIZE:-100GB}"                 # ~12 GB per stack; disk binds before RAM

gcloud compute instances create "$NAME" --project "$PROJECT" --zone "$ZONE" \
  --machine-type "$MACHINE_TYPE" --image-family debian-12 --image-project debian-cloud \
  --boot-disk-size "$DISK_SIZE" --boot-disk-type pd-balanced
