# orca-host, laptop side. Needs: docker, terraform, gcloud, op (1Password CLI), jq, ssh, the Orca desktop CLI.
# Per-host values are read from terraform/terraform.tfvars; the env file is the body of a 1Password Secure Note
# named orca-host, in the vault OP_VAULT (override: `make secret OP_VAULT="My Vault"`, or export it).
TFVARS  := terraform/terraform.tfvars
NAME    := $(shell sed -n 's/^name *= *"\(.*\)".*/\1/p' $(TFVARS))
PROJECT := $(shell sed -n 's/^project *= *"\(.*\)".*/\1/p' $(TFVARS))
ZONE    := $(or $(shell sed -n 's/^zone *= *"\(.*\)".*/\1/p' $(TFVARS)),europe-west9-b)
REGION  := $(shell echo $(ZONE) | sed 's/-[a-z]$$//')
BUCKET  := $(PROJECT)-tfstate
SECRET  := orca-host-$(NAME)-env
OP_VAULT ?= Private
OP      := op://$(OP_VAULT)/orca-host/notesPlain
TF      := terraform -chdir=terraform
SSH     := ssh -o StrictHostKeyChecking=accept-new   # a new host is a new key, by construction

.PHONY: build up down env secret bootstrap init plan apply pair logs shell ssh

## image and stack, on this laptop
build:              ## build the image for this machine's architecture, as orca-host:dev
	docker build -t orca-host:dev .

up: env             ## run the stack here, advertised on this laptop's tailnet IP
	PAIRING_ADDRESS=$$(tailscale ip -4) docker compose -f compose.yaml -f compose.laptop.yaml --env-file env up -d

down:
	docker compose -f compose.yaml -f compose.laptop.yaml --env-file env down

env:                ## the env file, from 1Password, into ./env (gitignored)
	op read "$(OP)" > env && chmod 600 env

## host, on GCP
secret:             ## the env file, from 1Password, as a new version of the host's secret
	op read "$(OP)" | gcloud secrets versions add $(SECRET) --data-file=- --project $(PROJECT)

bootstrap:          ## once per project: the state bucket
	gcloud storage buckets describe gs://$(BUCKET) --project $(PROJECT) >/dev/null 2>&1 || \
	  gcloud storage buckets create gs://$(BUCKET) --project $(PROJECT) --location $(REGION) \
	    --uniform-bucket-level-access --public-access-prevention
	gcloud storage buckets update gs://$(BUCKET) --versioning >/dev/null

init:               ## terraform init against the state bucket, one prefix per host
	$(TF) init -backend-config=bucket=$(BUCKET) -backend-config=prefix=orca-host/$(NAME)

plan:
	$(TF) plan

apply:              ## bring the host up (or update it)
	$(TF) apply

pair:               ## read the pairing URL over the tailnet, pair the desktop client with it
	$(SSH) core@$(NAME) docker logs orca-host 2>/dev/null \
	  | jq -Rr 'fromjson? | select(.type=="orca_server_ready") | .pairing.url' | tail -1 > .pairing-url
	test -s .pairing-url || { echo "no pairing URL yet: make logs"; rm -f .pairing-url; exit 1; }
	orca environment add --name $(NAME) --pairing-code "$$(cat .pairing-url)"; rm -f .pairing-url
	orca status --environment $(NAME)

logs:
	ssh core@$(NAME) docker logs -f --tail 100 orca-host

shell:              ## a shell in the Orca container, as `orca`, the same paths an Orca terminal sees
	ssh -t core@$(NAME) docker exec -it -u orca orca-host bash

ssh:                ## a shell on the VM itself, as `core`
	ssh core@$(NAME)
