# orca-host, laptop side. Needs: docker, terraform, gcloud, op (1Password CLI), jq, ssh, qrencode, the Orca desktop CLI.
# Two per-person files, plain configuration, versioned wherever you keep your host (the repository of your own image
# is the natural place) or kept here, gitignored: TFVARS, the host's name, project, zone, SSH key; ENV_TPL, the
# variables the host starts with, `VAR=value` per line, a secret as a `{{ op://Vault/Item/field }}` reference.
# A reference is not a secret: 1Password holds the values, and nothing else. Next to ENV_TPL, one template per extra
# 1Password account, its name ENV_TPL's with the account in it (.env.<name>.tpl), resolved with the token
# OP_SERVICE_ACCOUNT_TOKEN_<NAME> that ENV_TPL yields.
# The host reads the image's /etc/orca-host/env*.tpl, then these (Terraform carries them, `make restart` copies them
# again), and resolves them at every boot with a service account, through inject-env.sh. `make env` does the same
# here, with your own account. What the host needs from this laptop is that account's token — `make secret`, once.
TFVARS  ?= terraform/terraform.tfvars
ENV_TPL ?= .env.tpl
# `=`, not `:=`: expanded in recipes, once $(TFVARS) is known to exist. At parse time it may not.
NAME     = $(shell sed -n 's/^name *= *"\(.*\)".*/\1/p' $(TFVARS) 2>/dev/null)
PROJECT  = $(shell sed -n 's/^project *= *"\(.*\)".*/\1/p' $(TFVARS) 2>/dev/null)
ZONE     = $(or $(shell sed -n 's/^zone *= *"\(.*\)".*/\1/p' $(TFVARS) 2>/dev/null),europe-west9-b)
REGION   = $(shell echo $(ZONE) | sed 's/-[a-z]$$//')
BUCKET   = $(PROJECT)-tfstate
SECRET   = $(NAME)-op-token
OP_VAULT  = $(shell sed -n 's/^op_vault *= *"\(.*\)".*/\1/p' $(TFVARS) 2>/dev/null)
OP_TOKEN  = op://$(OP_VAULT)/orca-host-service-account/credential
# The local templates: ENV_TPL and the .env.<name>.tpl next to it, and the name each one takes on the host.
LOCAL_TPLS = $(wildcard $(ENV_TPL) $(basename $(ENV_TPL)).*.tpl)
host_tpl   = $(if $(filter $(ENV_TPL),$(1)),env.tpl,env.$(patsubst $(basename $(ENV_TPL)).%.tpl,%,$(1)).tpl)
TF      := terraform -chdir=terraform
# TFVARS by path, wherever it is; the local templates when there are any, their content goes into Ignition
TF_VARS  = -var-file=$(abspath $(TFVARS)) \
	   $(if $(LOCAL_TPLS),-var 'env_tpls={$(foreach f,$(LOCAL_TPLS),"$(call host_tpl,$(f))"="$(abspath $(f))",)}')
# Every rebuild is a new host key, and the tailnet already authenticates the peer: no host-key check for this host.
SSH     := ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR
# What `make up` runs, the same variable a host uses: `make build`'s output by default, any reference on request.
ORCA_IMAGE ?= orca-host:dev

.PHONY: build up down secret bootstrap init plan apply rebuild pair pair-desktop pair-mobile restart logs shell ssh
# A failed `op inject` (locked vault, missing item) must not leave an empty file that Make then takes as up to date.
.DELETE_ON_ERROR:

# `secret` pipes, and `sh` has no pipefail: a failed `op` would exit 0 through the next command and upload an empty
# secret version. bash for it, so the pipeline fails with its first command.
secret: SHELL := /bin/bash
secret: .SHELLFLAGS := -o pipefail -c

# The image's templates first, then the local ones, as on the host (render-env); an image that is not there is none.
env:                ## the env file, resolved from the templates with your own account, into ./env. `rm env` to redo it.
	img=$$(mktemp -d) && trap 'rm -rf "$$img"' EXIT && \
	  if cid=$$(docker create $(ORCA_IMAGE) 2>/dev/null); then \
	    docker cp $$cid:/etc/orca-host/. $$img/ >/dev/null 2>&1; docker rm $$cid >/dev/null; fi && \
	  ./inject-env.sh $$img/*.tpl $(LOCAL_TPLS) > $@ && chmod 600 $@

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
secret bootstrap init plan apply rebuild pair-desktop pair-mobile restart logs shell ssh: $(TFVARS)
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

rebuild:            ## a new VM from Ignition, the data disk kept: what Ignition carries changed. Ends live terminals.
	$(TF) apply $(TF_VARS) -replace=google_compute_instance.vm

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

# The local templates first, when there are any: Ignition wrote them at first boot only, so a line or a file added
# since reaches the host here, with no rebuild, and one removed since is removed there. compose recreates the container only when its image or its env file changed: a push to the
# settings repository changes neither, so the container is restarted as well, and its entrypoint runs again.
restart:            ## copy the local templates, re-render the env file from 1Password, re-run the stack and the entrypoint. Ends live terminals.
	$(if $(LOCAL_TPLS),$(SSH) core@$(NAME) 'sudo rm -f /opt/orca/env.tpl /opt/orca/env.*.tpl' && \
	  $(foreach f,$(LOCAL_TPLS),$(SSH) core@$(NAME) "sudo sh -c 'umask 077; cat > /opt/orca/$(call host_tpl,$(f))'" < $(f) &&) true)
	$(SSH) core@$(NAME) 'sudo systemctl restart orca-env orca && docker restart orca-host'

logs:
	$(SSH) core@$(NAME) docker logs -f --tail 100 orca-host

shell:              ## a shell in the Orca container, as `orca`, the same paths an Orca terminal sees
	$(SSH) -t core@$(NAME) docker exec -it -u orca orca-host bash

ssh:                ## a shell on the VM itself, as `core`
	$(SSH) core@$(NAME)
