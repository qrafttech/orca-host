# orca-host, laptop side. Needs: docker, terraform, gcloud, op (1Password CLI), jq, ssh, qrencode, the Orca desktop CLI.
# PROVIDER: gcp, the default, or ovh (an OVH VPS); the Terraform root is terraform/$(PROVIDER)/. On ovh, Terraform and the ovhcloud
# CLI run from the image `make tools` builds: Docker, op and gcloud's application-default credentials are enough.
# Two per-person files, plain configuration, versioned wherever you keep your host (the repository of your own image
# is the natural place) or kept here, gitignored: TFVARS, the host's name, project, zone, SSH key; ENV_TPL, the
# variables the host starts with, `VAR=value` per line, a secret as a `{{ op://Vault/Item/field }}` reference.
# A reference is not a secret: 1Password holds the values, and nothing else.
# A service account reads one vault of one 1Password account. For a secret in another account: a service account
# created in that account, its token an item of the host's vault, read by a line OP_SERVICE_ACCOUNT_TOKEN_<NAME> of
# ENV_TPL; the references to that account go in a second template next to ENV_TPL, .env.<name>.tpl, resolved with it.
# A template comes from one of two places, both optional, read in this order, the last line of a variable winning:
#   the image      /etc/orca-host/env.tpl and env.<name>.tpl, which a derived image COPYs: a push reaches the host
#   this laptop    ENV_TPL and the .env.<name>.tpl next to it: Terraform carries them, `make restart` copies them
# The host resolves them at every boot with its service account, through inject-env.sh. `make env` does the same
# here, with your own account. What the host needs from this laptop is that account's token — `make secret`, once.
PROVIDER ?= gcp
TF_DIR    = terraform/$(PROVIDER)
TFVARS  ?= $(TF_DIR)/terraform.tfvars
ENV_TPL ?= .env.tpl
# `=`, not `:=`: expanded in recipes, once $(TFVARS) is known to exist. At parse time it may not.
NAME     = $(shell sed -n 's/^name *= *"\(.*\)".*/\1/p' $(TFVARS) 2>/dev/null)
PROJECT  = $(shell sed -n 's/^project *= *"\(.*\)".*/\1/p' $(TFVARS) 2>/dev/null)
ZONE     = $(or $(shell sed -n 's/^zone *= *"\(.*\)".*/\1/p' $(TFVARS) 2>/dev/null),europe-west9-b)
REGION   = $(shell echo $(ZONE) | sed 's/-[a-z]$$//')
BUCKET   = $(or $(shell sed -n 's/^state_bucket *= *"\(.*\)".*/\1/p' $(TFVARS) 2>/dev/null),$(PROJECT)-tfstate)
OP_VAULT  = $(shell sed -n 's/^op_vault *= *"\(.*\)".*/\1/p' $(TFVARS) 2>/dev/null)
OP_TOKEN ?= op://$(OP_VAULT)/orca-host-op-token/credential
# The templates on this laptop: ENV_TPL and the .env.<name>.tpl next to it, and the name each takes on the host.
LOCAL_TPLS = $(wildcard $(ENV_TPL) $(basename $(ENV_TPL)).*.tpl)
host_tpl   = $(if $(filter $(ENV_TPL),$(1)),env.tpl,env.$(patsubst $(basename $(ENV_TPL)).%.tpl,%,$(1)).tpl)
TF       = $(if $(filter ovh,$(PROVIDER)),$(TF_OVH),terraform -chdir=$(TF_DIR))
# OVH's API credentials, items of 1Password: `op run` resolves the references into the environment of the tools
# container, for Terraform's ovh provider and the ovhcloud CLI alike. The state is in GCS: application-default
# credentials, or without them gcloud's access token for its active account. TFVARS and the laptop's templates
# are mounted at their own paths, so TF_VARS reads the same inside.
TOOLS     := orca-host-tools:dev
OVH_ITEM  ?= op://$(OP_VAULT)/ovh-api
ADC       ?= $(HOME)/.config/gcloud/application_default_credentials.json
GCS_AUTH  = $(if $(wildcard $(ADC)),-e GOOGLE_APPLICATION_CREDENTIALS=/adc.json -v $(ADC):/adc.json:ro,-e GOOGLE_OAUTH_ACCESS_TOKEN)
TF_OVH    = $(if $(wildcard $(ADC)),,GOOGLE_OAUTH_ACCESS_TOKEN=$$(gcloud auth print-access-token)) OVH_ENDPOINT="$(OVH_ITEM)/endpoint" OVH_APPLICATION_KEY="$(OVH_ITEM)/application_key" \
	    OVH_APPLICATION_SECRET="$(OVH_ITEM)/application_secret" OVH_CONSUMER_KEY="$(OVH_ITEM)/consumer_key" \
	    op run -- docker run --rm -i -u $$(id -u):$$(id -g) -e HOME=/tmp \
	      -e OVH_ENDPOINT -e OVH_APPLICATION_KEY -e OVH_APPLICATION_SECRET -e OVH_CONSUMER_KEY \
	      $(GCS_AUTH) \
	      -v $(CURDIR):$(CURDIR) -v $(abspath $(TFVARS)):$(abspath $(TFVARS)):ro \
	      $(foreach f,$(LOCAL_TPLS),-v $(abspath $(f)):$(abspath $(f)):ro) \
	      -w $(CURDIR) $(TOOLS) -chdir=$(TF_DIR)
REPLACE   = $(if $(filter ovh,$(PROVIDER)),terraform_data.install,google_compute_instance.vm)
# TFVARS by path, wherever it is; the laptop's templates when there are any, their content goes into the first-boot
# script
TF_VARS  = -var-file=$(abspath $(TFVARS)) \
	   $(if $(LOCAL_TPLS),-var 'env_tpls={$(foreach f,$(LOCAL_TPLS),"$(call host_tpl,$(f))"="$(abspath $(f))",)}')
# Every rebuild is a new host key, and the tailnet already authenticates the peer: no host-key check for this host.
SSH     := ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR
# What `make up` runs, the same variable a host uses: `make build`'s output by default, any reference on request.
ORCA_IMAGE ?= orca-host:dev

.PHONY: build up down tools secret bootstrap init plan apply rebuild lockdown destroy pair pair-desktop pair-mobile restart logs shell ssh
# A failed `op inject` (locked vault, missing item) must not leave an empty file that Make then takes as up to date.
.DELETE_ON_ERROR:

# `secret` pipes, and `sh` has no pipefail: a failed `op` would exit 0 through the next command and hand the host
# an empty token. bash for it, so the pipeline fails with its first command.
secret: SHELL := /bin/bash
secret: .SHELLFLAGS := -o pipefail -c

# The templates in ORCA_IMAGE's /etc/orca-host first, then the laptop's, as on the host (render-env); an image that
# is not there has none.
env:                ## the env file, resolved from the templates with your own account, into ./env. `rm env` to redo it.
	img=$$(mktemp -d) && trap 'rm -rf "$$img"' EXIT && \
	  if cid=$$(docker create $(ORCA_IMAGE) 2>/dev/null); then \
	    docker cp $$cid:/etc/orca-host/. $$img/ >/dev/null 2>&1; docker rm $$cid >/dev/null; fi && \
	  ./inject-env.sh $$img/*.tpl $(LOCAL_TPLS) > $@ && chmod 600 $@

$(TFVARS):
	@echo "$@ is missing: fill in $(TF_DIR)/terraform.tfvars.example there, or point TFVARS at yours"; exit 1

## image and stack, on this laptop
build:              ## build the image for this machine's architecture, as orca-host:dev
	docker build -t orca-host:dev .

up: env             ## run the stack here, advertised on this laptop's tailnet IP
	PAIRING_ADDRESS=$$(tailscale ip -4) ORCA_IMAGE=$(ORCA_IMAGE) ORCA_ENV_FILE=env docker compose -f compose.yaml -f compose.laptop.yaml --env-file env up -d

down:
	docker compose -f compose.yaml -f compose.laptop.yaml --env-file env down

## host, on GCP or OVH
secret bootstrap init plan apply rebuild lockdown pair-desktop pair-mobile restart logs shell ssh: $(TFVARS)
init plan apply rebuild secret: $(if $(filter ovh,$(PROVIDER)),tools)

tools:              ## the image Terraform and the ovhcloud CLI run from, for an OVH host
	docker build -q -t $(TOOLS) tools
# the pairing URL of the running server, from the last orca_server_ready line of its logs; empty until it is up
PAIRING_URL = $(SSH) core@$(NAME) docker logs orca-host 2>/dev/null \
	  | jq -Rr 'fromjson? | select(.type=="orca_server_ready") | .pairing.url' | tail -1

# One line, and the only thing this laptop hands the host. A service-account token expires: the day it does,
# a new one goes in the item and this runs again — nothing else moves. It goes to /var/lib/orca/op-token over SSH:
# the tailnet when the host is on it, else the way in before it, since the host joins the tailnet with a key it
# reads with this very token — IAP on GCP, the public address on OVH (looked up with stdin closed: it is the token).
WRITE_TOKEN   = sudo sh -c 'umask 077; cat > /var/lib/orca/op-token.tmp && mv /var/lib/orca/op-token.tmp /var/lib/orca/op-token'
BOOTSTRAP_SSH = $(if $(filter ovh,$(PROVIDER)),$(SSH) -o ConnectTimeout=10 core@$$ip,\
	          gcloud compute ssh $(NAME) --zone $(ZONE) --project $(PROJECT) --tunnel-through-iap --command)
secret:             ## the service-account token, from 1Password, to the host
	token=$$(op read "$(OP_TOKEN)" | tr -d '\r\n'); [ -n "$$token" ] || exit 1; \
	$(if $(filter ovh,$(PROVIDER)),ip=$$($(TF) output -raw ipv4 </dev/null); \
	  [ -n "$$ip" ] || { echo "no address for $(NAME): make init and make apply"; exit 1; };) \
	printf '%s' "$$token" | $(SSH) -o ConnectTimeout=10 core@$(NAME) "$(WRITE_TOKEN)" \
	  || printf '%s' "$$token" | $(BOOTSTRAP_SSH) "$(WRITE_TOKEN)"

bootstrap:          ## once per project: the state bucket
	gcloud storage buckets describe gs://$(BUCKET) --project $(PROJECT) >/dev/null 2>&1 || \
	  gcloud storage buckets create gs://$(BUCKET) --project $(PROJECT) --location $(REGION) \
	    --uniform-bucket-level-access --public-access-prevention
	gcloud storage buckets update gs://$(BUCKET) --versioning >/dev/null

# -reconfigure: each host has its own state, under its own prefix. A checkout that last pointed at another host points
# at this one now, and nothing is migrated: moving one host's state onto another's would be the error.
init:               ## terraform init against the state bucket, one prefix per host, the host TFVARS names. Once per checkout, and per host.
	$(TF) init -reconfigure -backend-config=bucket=$(BUCKET) -backend-config=prefix=orca-host/$(NAME)

plan:
	$(TF) plan $(TF_VARS)

apply:              ## bring the host up (or update it)
	$(TF) apply $(TF_VARS)

rebuild:            ## a new VM (GCP) or a reinstall (OVH), the data disk kept: what the VM is made of changed. Ends live terminals.
	$(TF) apply $(TF_VARS) -replace=$(REPLACE)

# An OVH host answers SSH on its public address until this, for the first `make secret`. Over the tailnet, so the
# session doing it is not the one cut. A GCP host has no public SSH to close: its VPC lets in IAP only, which stays
# the way in when the tailnet is down.
lockdown:           ## OVH: SSH on the tailnet only, from now on and across reinstalls of a kept data disk
ifeq ($(PROVIDER),ovh)
	$(SSH) core@$(NAME) 'sudo touch /var/lib/orca/lockdown && sudo /opt/orca/firewall'
else
	@echo "a GCP host has no public SSH: nothing to close"
endif

# The host is the one TFVARS names, its state too: init again against its prefix, whatever the last `make init` was.
# The data disk is `prevent_destroy`, so no plan deletes it by accident: it leaves the state first, and gcloud deletes
# it, then its snapshots. Asks once, for the host's name; every step after skips what is already gone, so a destroy
# stopped halfway is run again. A gcloud that fails, a reauthentication refused, stops it: never read as gone. The
# tailnet node is logged out when the host answers, else removed in the Tailscale admin console. Last, the host's
# state, its old versions included; the empty-name check above keeps that to one host's prefix. `make init` starts a
# new state, for a new host under the same name.
destroy:            ## GCP: the host for good, its data disk, snapshots and state included. Asks for its name.
ifeq ($(PROVIDER),ovh)
	@echo "an OVH VPS is terminated in the OVH control panel"; exit 1
else
	@[ -n "$(NAME)" ] || { echo "no name in $(TFVARS): TFVARS names the host's file"; exit 1; }
	@read -p "type $(NAME) to delete it ($(PROJECT), $(ZONE)), its data disk, its snapshots and its state: " n; [ "$$n" = "$(NAME)" ]
	$(TF) init -reconfigure -backend-config=bucket=$(BUCKET) -backend-config=prefix=orca-host/$(NAME) >/dev/null
	-$(SSH) -o ConnectTimeout=10 core@$(NAME) 'sudo docker exec tailscale tailscale logout'
	if $(TF) state list | grep -qx google_compute_region_disk.data; then \
	  $(TF) state rm google_compute_region_disk.data; fi
	$(TF) destroy $(TF_VARS) -auto-approve
	d=$$(gcloud compute disks list --project $(PROJECT) --format='value(name)' \
	  --filter='name=$(NAME)-data AND region~/$(REGION)$$') && \
	{ [ -z "$$d" ] || gcloud compute disks delete $(NAME)-data --region $(REGION) --project $(PROJECT) --quiet; }
	s=$$(gcloud compute snapshots list --project $(PROJECT) --format='value(name)' \
	  --filter='sourceDisk~/regions/$(REGION)/disks/$(NAME)-data$$') && \
	{ [ -z "$$s" ] || gcloud compute snapshots delete $$s --project $(PROJECT) --quiet; }
	o=$$(gcloud storage objects list 'gs://$(BUCKET)/orca-host/$(NAME)/**' --format='value(name)') && \
	{ [ -z "$$o" ] || gcloud storage rm -r --all-versions gs://$(BUCKET)/orca-host/$(NAME)/; }
endif

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

# The laptop's templates first, when there are any: the first-boot script wrote them at install, so a line or a file
# added since reaches the host here, with no rebuild, and one removed since is removed there. compose recreates the
# container only when its image or its env file changed: a push to the settings repository changes neither, so the
# container is restarted as well, and its entrypoint runs again.
restart:            ## copy the laptop's templates, re-render the env file from 1Password, re-run the stack and the entrypoint. Ends live terminals.
	$(if $(LOCAL_TPLS),$(SSH) core@$(NAME) 'sudo rm -f /opt/orca/env.tpl /opt/orca/env.*.tpl' && \
	  $(foreach f,$(LOCAL_TPLS),$(SSH) core@$(NAME) "sudo sh -c 'umask 077; cat > /opt/orca/$(call host_tpl,$(f))'" < $(f) &&) true)
	$(SSH) core@$(NAME) 'sudo systemctl restart orca-env orca && docker restart orca-host'

logs:
	$(SSH) core@$(NAME) docker logs -f --tail 100 orca-host

shell:              ## a shell in the Orca container, as `orca`, the same paths an Orca terminal sees
	$(SSH) -t core@$(NAME) docker exec -it -u orca orca-host bash

ssh:                ## a shell on the VM itself, as `core`
	$(SSH) core@$(NAME)
