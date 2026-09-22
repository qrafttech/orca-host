# orca-host, laptop side. Needs: docker, terraform, gcloud, op (1Password CLI), jq, ssh, qrencode, the Orca desktop CLI.
# The two per-person files are gitignored and come from 1Password when absent: terraform/terraform.tfvars is the
# body of a Secure Note named orca-host-tfvars, the env file of one named orca-host, both in the vault OP_VAULT
# (override: `make secret OP_VAULT="My Vault"`, or export it). Edit the local copies freely; `rm` one to refetch it.
TFVARS  := terraform/terraform.tfvars
# `=`, not `:=`: expanded in recipes, after the $(TFVARS) rule has fetched the file. At parse time it may not exist.
NAME     = $(shell sed -n 's/^name *= *"\(.*\)".*/\1/p' $(TFVARS))
PROJECT  = $(shell sed -n 's/^project *= *"\(.*\)".*/\1/p' $(TFVARS))
ZONE     = $(or $(shell sed -n 's/^zone *= *"\(.*\)".*/\1/p' $(TFVARS)),europe-west9-b)
REGION   = $(shell echo $(ZONE) | sed 's/-[a-z]$$//')
BUCKET   = $(PROJECT)-tfstate
SECRET   = orca-host-$(NAME)-env
OP_VAULT ?= Private
OP        := op://$(OP_VAULT)/orca-host/notesPlain
OP_TFVARS := op://$(OP_VAULT)/orca-host-tfvars/notesPlain
TF      := terraform -chdir=terraform
# Every rebuild is a new host key, and the tailnet already authenticates the peer: no host-key check for this host.
SSH     := ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR

.PHONY: build up down secret bootstrap init plan apply pair pair-desktop pair-mobile restart logs shell ssh
# A failed `op read` (locked vault, missing note) must not leave an empty file that Make then takes as up to date.
.DELETE_ON_ERROR:

## the per-person files, from 1Password when absent
env:                ## the env file, into ./env
	op read "$(OP)" > $@ && chmod 600 $@

$(TFVARS):          ## the host's name, project, zone, SSH key, into terraform/terraform.tfvars
	op read "$(OP_TFVARS)" > $@

## image and stack, on this laptop
build:              ## build the image for this machine's architecture, as orca-host:dev
	docker build -t orca-host:dev .

up: env             ## run the stack here, advertised on this laptop's tailnet IP
	PAIRING_ADDRESS=$$(tailscale ip -4) ORCA_ENV_FILE=env docker compose -f compose.yaml -f compose.laptop.yaml --env-file env up -d

down:
	docker compose -f compose.yaml -f compose.laptop.yaml --env-file env down

## host, on GCP
secret bootstrap init plan apply pair-desktop pair-mobile restart logs shell ssh: $(TFVARS)
# the pairing URL of the running server, from the last orca_server_ready line of its logs; empty until it is up
PAIRING_URL = $(SSH) core@$(NAME) docker logs orca-host 2>/dev/null \
	  | jq -Rr 'fromjson? | select(.type=="orca_server_ready") | .pairing.url' | tail -1

secret:             ## the env file, from 1Password, as a new version of the host's secret
	op read "$(OP)" | gcloud secrets versions add $(SECRET) --data-file=- --project $(PROJECT)

bootstrap:          ## once per project: the state bucket
	gcloud storage buckets describe gs://$(BUCKET) --project $(PROJECT) >/dev/null 2>&1 || \
	  gcloud storage buckets create gs://$(BUCKET) --project $(PROJECT) --location $(REGION) \
	    --uniform-bucket-level-access --public-access-prevention
	gcloud storage buckets update gs://$(BUCKET) --versioning >/dev/null

init:               ## terraform init against the state bucket, one prefix per host. Once per checkout.
	$(TF) init -backend-config=bucket=$(BUCKET) -backend-config=prefix=orca-host/$(NAME)

plan:
	$(TF) plan

apply:              ## bring the host up (or update it)
	$(TF) apply

pair: pair-desktop pair-mobile  ## the desktop client, then the phone, then the server back to its desktop link

pair-desktop:       ## read the pairing URL over the tailnet, pair the desktop client with it
	$(PAIRING_URL) > .pairing-url
	test -s .pairing-url || { echo "no pairing URL yet: make logs"; rm -f .pairing-url; exit 1; }
	orca environment add --name $(NAME) --pairing-code "$$(cat .pairing-url)"; rm -f .pairing-url
	orca status --environment $(NAME)

# `orca serve` prints one pairing link per process, so the phone's is a restart with ORCA_PAIRING=mobile appended
# to the host's env file, and a second one that refetches the file (orca-env is a oneshot: restarting it re-runs the
# fetch). Two container restarts, at setup time, before any project is cloned. Interrupted between the two, the
# host stays on the mobile link: `make restart` is the way back.
pair-mobile:        ## restart the server on its mobile link, show it as a QR for the phone, restart back
	printf '\nORCA_PAIRING=mobile\n' | $(SSH) core@$(NAME) 'sudo tee -a /var/lib/orca/env >/dev/null && sudo systemctl restart orca'
	for i in $$(seq 1 24); do $(PAIRING_URL) > .pairing-url; test -s .pairing-url && break; sleep 5; done; \
	  test -s .pairing-url || { echo "no pairing URL after 2 minutes: make logs"; rm -f .pairing-url; exit 1; }
	qrencode -t ansiutf8 "$$(cat .pairing-url)"; cat .pairing-url; rm -f .pairing-url
	@printf 'scan it from the phone (Tailscale on, same tailnet), then Enter: '; read -r _
	$(SSH) core@$(NAME) sudo systemctl restart orca-env orca

restart:            ## re-run the stack: new secret version, new image under the same tag. Ends live terminals.
	$(SSH) core@$(NAME) sudo systemctl restart orca-env orca

logs:
	$(SSH) core@$(NAME) docker logs -f --tail 100 orca-host

shell:              ## a shell in the Orca container, as `orca`, the same paths an Orca terminal sees
	$(SSH) -t core@$(NAME) docker exec -it -u orca orca-host bash

ssh:                ## a shell on the VM itself, as `core`
	$(SSH) core@$(NAME)
