# orca-host, laptop side. Needs: docker, terraform, gcloud, op (1Password CLI), jq, ssh, qrencode, the Orca desktop CLI.
# Two per-person files, plain configuration, versioned wherever you keep your host (the repository of your own image
# is the natural place) or kept here, gitignored: TFVARS, the host's name, project, zone, SSH key; ENV_TPL, the
# variables the host starts with, `VAR=value` per line, a secret as a `{{ op://Vault/Item/field }}` reference.
# A reference is not a secret: 1Password holds the values, and nothing else.
# The host reads the image's /etc/orca-host/env.tpl, then ENV_TPL (Terraform carries it), and resolves both at every
# boot with a service account. `make env` does the same here, with your own account. What the host needs from this
# laptop is that account's token — `make secret`, once.
TFVARS  ?= terraform/terraform.tfvars
ENV_TPL ?= .env.tpl
# `=`, not `:=`: expanded in recipes, once $(TFVARS) is known to exist. At parse time it may not.
NAME     = $(shell sed -n 's/^name *= *"\(.*\)".*/\1/p' $(TFVARS) 2>/dev/null)
PROJECT  = $(shell sed -n 's/^project *= *"\(.*\)".*/\1/p' $(TFVARS) 2>/dev/null)
ZONE     = $(or $(shell sed -n 's/^zone *= *"\(.*\)".*/\1/p' $(TFVARS) 2>/dev/null),europe-west9-b)
REGION   = $(shell echo $(ZONE) | sed 's/-[a-z]$$//')
BUCKET   = $(PROJECT)-tfstate
SECRET   = orca-host-$(NAME)-op-token
OP_VAULT  = $(shell sed -n 's/^op_vault *= *"\(.*\)".*/\1/p' $(TFVARS) 2>/dev/null)
OP_TOKEN  = op://$(OP_VAULT)/orca-host-service-account/credential
# The image's template, then the local one; the last line of a variable wins, as on the host (render-env).
READ_TPL  = { docker run --rm --entrypoint sh $(ORCA_IMAGE) -c '[ ! -f /etc/orca-host/env.tpl ] || cat /etc/orca-host/env.tpl'; \
	      [ ! -f $(ENV_TPL) ] || cat $(ENV_TPL); }
LAST_WINS = awk -F= '/^[A-Za-z_][A-Za-z0-9_]*=/ { if (!($$1 in v)) k[n++] = $$1; v[$$1] = $$0 } END { for (i = 0; i < n; i++) print v[k[i]] }'
TF      := terraform -chdir=terraform
# TFVARS by path, wherever it is; ENV_TPL only when it exists, its content goes into Ignition
TF_VARS  = -var-file=$(abspath $(TFVARS)) $(if $(wildcard $(ENV_TPL)),-var env_tpl=$(abspath $(ENV_TPL)))
# Every rebuild is a new host key, and the tailnet already authenticates the peer: no host-key check for this host.
SSH     := ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR
# What `make up` runs, the same variable a host uses: `make build`'s output by default, any reference on request.
ORCA_IMAGE ?= orca-host:dev

.PHONY: build up down secret bootstrap init plan apply pair pair-desktop pair-mobile restart logs shell ssh
# A failed `op inject` (locked vault, missing item) must not leave an empty file that Make then takes as up to date.
.DELETE_ON_ERROR:

# Both recipes pipe, and `sh` has no pipefail: a failed `op` would exit 0 through the next command and write an
# empty file, or upload an empty secret version. bash for these two, so the pipeline fails with its first command.
env secret: SHELL := /bin/bash
env secret: .SHELLFLAGS := -o pipefail -c

env:                ## the env file, resolved from the templates with your own account, into ./env. `rm env` to redo it.
	$(READ_TPL) | op inject | $(LAST_WINS) > $@ && chmod 600 $@

$(TFVARS):
	@echo "$@ is missing: fill in terraform/terraform.tfvars.example there, or point TFVARS at yours"; exit 1

## image and stack, on this laptop
build:              ## build the image for this machine's architecture, as orca-host:dev
	docker build -t orca-host:dev .

up: env             ## run the stack here, advertised on this laptop's tailnet IP
	PAIRING_ADDRESS=$$(tailscale ip -4) ORCA_IMAGE=$(ORCA_IMAGE) ORCA_ENV_FILE=env docker compose -f compose.yaml -f compose.laptop.yaml --env-file env up -d

down:
	docker compose -f compose.yaml -f compose.laptop.yaml --env-file env down

## host, on GCP
secret bootstrap init plan apply pair-desktop pair-mobile restart logs shell ssh: $(TFVARS)
# the pairing URL of the running server, from the last orca_server_ready line of its logs; empty until it is up
PAIRING_URL = $(SSH) core@$(NAME) docker logs orca-host 2>/dev/null \
	  | jq -Rr 'fromjson? | select(.type=="orca_server_ready") | .pairing.url' | tail -1

# One line, and the only thing this laptop hands the host. A service-account token expires: the day it does,
# a new one goes in the item and this runs again — nothing else moves.
secret:             ## the service-account token, from 1Password, as a new version of the host's secret
	op read "$(OP_TOKEN)" | tr -d '\r\n' | gcloud secrets versions add $(SECRET) --data-file=- --project $(PROJECT)

bootstrap:          ## once per project: the state bucket
	gcloud storage buckets describe gs://$(BUCKET) --project $(PROJECT) >/dev/null 2>&1 || \
	  gcloud storage buckets create gs://$(BUCKET) --project $(PROJECT) --location $(REGION) \
	    --uniform-bucket-level-access --public-access-prevention
	gcloud storage buckets update gs://$(BUCKET) --versioning >/dev/null

init:               ## terraform init against the state bucket, one prefix per host. Once per checkout.
	$(TF) init -backend-config=bucket=$(BUCKET) -backend-config=prefix=orca-host/$(NAME)

plan:
	$(TF) plan $(TF_VARS)

apply:              ## bring the host up (or update it)
	$(TF) apply $(TF_VARS)

pair: pair-desktop pair-mobile  ## the desktop client, then the phone, then the server back to its desktop link

pair-desktop:       ## read the pairing URL over the tailnet, pair the desktop client with it
	$(PAIRING_URL) > .pairing-url
	test -s .pairing-url || { echo "no pairing URL yet: make logs"; rm -f .pairing-url; exit 1; }
	orca environment add --name $(NAME) --pairing-code "$$(cat .pairing-url)"; rm -f .pairing-url
	orca status --environment $(NAME)

# `orca serve` prints one pairing link per process, so the phone's is a restart with ORCA_PAIRING=mobile appended
# to the host's env file, and a second one that renders it again (orca-env is a oneshot: restarting it re-runs the
# rendering, from the templates, without ORCA_PAIRING). Two container restarts, at setup time, before any project is
# cloned. Interrupted between the two, the host stays on the mobile link: `make restart` is the way back.
pair-mobile:        ## restart the server on its mobile link, show it as a QR for the phone, restart back
	printf '\nORCA_PAIRING=mobile\n' | $(SSH) core@$(NAME) 'sudo tee -a /var/lib/orca/env >/dev/null && sudo systemctl restart orca'
	for i in $$(seq 1 24); do $(PAIRING_URL) > .pairing-url; test -s .pairing-url && break; sleep 5; done; \
	  test -s .pairing-url || { echo "no pairing URL after 2 minutes: make logs"; rm -f .pairing-url; exit 1; }
	qrencode -t ansiutf8 "$$(cat .pairing-url)"; cat .pairing-url; rm -f .pairing-url
	@printf 'scan it from the phone (Tailscale on, same tailnet), then Enter: '; \
	  read -r _ || { echo; echo "no terminal to wait on: scan it, then \`make restart\`"; exit 1; }
	$(SSH) core@$(NAME) sudo systemctl restart orca-env orca

# compose recreates the container only when its image or its env file changed: a push to ENV_TEMPLATE or the
# settings repository changes neither, so the container is restarted as well, and its entrypoint runs again.
restart:            ## re-render the env file from 1Password, re-run the stack and the entrypoint. Ends live terminals.
	$(SSH) core@$(NAME) 'sudo systemctl restart orca-env orca && docker restart orca-host'

logs:
	$(SSH) core@$(NAME) docker logs -f --tail 100 orca-host

# `docker exec` gets the container's environment, not what the entrypoint added from ENV_TEMPLATE: sourced again.
shell:              ## a shell in the Orca container, as `orca`, the same paths an Orca terminal sees
	$(SSH) -t core@$(NAME) docker exec -it -u orca orca-host bash -c "'set -a; [ ! -f ~/.config/orca-host/env.sh ] || . ~/.config/orca-host/env.sh; set +a; exec bash'"

ssh:                ## a shell on the VM itself, as `core`
	$(SSH) core@$(NAME)
