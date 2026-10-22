# orca-host

Your own [Orca](https://github.com/stablyai/orca) server in the cloud. It runs on a Debian VM, on Google Cloud or on an OVH VPS, and you use it from the Orca desktop and mobile apps over your tailnet. Each person gets one host and puts all of their projects on it. If you want to know how it works and why, read [`.claude/knowledge/`](.claude/knowledge/).

<img src="docs/architecture.svg" alt="The Orca clients reach the VM over the tailnet; in the VM, a tailscale container carries the address and an orca-host container runs orca serve; project stacks are sibling containers on the VM's Docker; a data disk holds the home, the Tailscale identity, Docker's images and volumes, and the env file, rendered from 1Password at every boot">

## Install

You need these on your laptop: `terraform`, `gcloud`, `op` (the 1Password CLI), `jq`, `ssh`, `qrencode`, and the Orca desktop app with its `orca` command. Your provider may need one more tool: see [Providers](#providers).

1. **Tailscale** (once per tailnet). In the admin console, go to Access controls → Tags and create a tag called `orca-host`, owned by `autogroup:admin`.
2. **1Password** (once). Create a vault for the host. Put in it the tokens your agents need, and no passwords. Then create a read-only service account on that vault, and save its token in the same vault, in an item called `orca-host-op-token`.
3. **A bucket for Terraform's state** (once). Whatever the provider, Terraform keeps track of your hosts in a Google Cloud Storage bucket. Log in with `gcloud auth application-default login`, then run `make bootstrap`.
4. **Pick a provider**, Google Cloud or OVH, and do what [its section](#providers) says.
5. **Write your two config files.** Put them in a folder of yours, for instance `~/orca-config/`, and tell `make` where they are:

   ```sh
   export PROVIDER=gcp                             # or ovh
   export TFVARS=~/orca-config/orca-gcp.tfvars     # the machine: named after your host
   export ENV_TPL=~/orca-config/.env.tpl           # what runs on it
   ```

   **The tfvars file** describes the machine. Start from your provider's example (`terraform/gcp/terraform.tfvars.example` or `terraform/ovh/terraform.tfvars.example`). For Google Cloud:

   ```hcl
   name           = "orca-gcp"                      # your host's name, on the tailnet too
   project        = "my-gcp-project"
   zone           = "europe-west9-a"
   op_vault       = "AI Agents"                     # the vault from step 2
   ssh_public_key = "ssh-ed25519 AAAA... me@laptop"
   ```

   **`.env.tpl`** lists the variables your host starts with, one per line. A secret is never written there: you point to the 1Password item that holds it.

   ```sh
   # Tailscale → Settings → Keys: not reusable, not ephemeral, tag orca-host. A new key for each new host
   TS_AUTHKEY={{ op://AI Agents/tailscale/authkey }}
   # from `claude setup-token`
   CLAUDE_CODE_OAUTH_TOKEN={{ op://AI Agents/claude/token }}
   # a classic GitHub token, with the repo and read:org scopes
   GH_TOKEN={{ op://AI Agents/github/token }}
   GIT_AUTHOR_NAME=Ada Lovelace
   GIT_AUTHOR_EMAIL=ada@example.com
   ```

   Neither file holds a secret, so you can keep the folder in git.

6. **Bring the host up.**

   ```sh
   make apply     # creates the machine; type yes when asked
   make secret    # wait a minute first: gives the host its 1Password token
   make pair      # connects your desktop app, then your phone
   ```

   In the desktop app, open Settings → Remote Orca Servers → Advanced → Active Server and pick your host. If you can open a terminal, it works.

## Providers

|  | Google Cloud | OVH |
|---|---|---|
| Price, roughly | about $160 a month (4 vCPU, 16 GB) | €10 to €25 a month excl. VAT (VPS-3 or VPS-4) |
| The machine | a VM, created and deleted by `make` | a VPS, ordered by `make apply` and cancelled in OVH's control panel |
| Your data | a disk copied in two zones, plus a snapshot a day, 7 kept | the VPS's disk; OVH's backup is an option |
| Out of stock | switch to the disk's other zone | wait, or pick another datacenter |
| Extra tool | none | the [OVH CLI](https://github.com/ovh/ovhcloud-cli), `ovhcloud` |

### Google Cloud

The login from step 3 is all Terraform needs. `make destroy` deletes the host for good, with its disk, its snapshots and its state; it asks you to type the host's name first.

If the VM's zone runs out of machines, set `zone` to the other value of `data_disk_zones` in your tfvars and run `make apply`: the VM moves, the disk stays.

### OVH

- **API credentials.** Create them on [this page](https://eu.api.ovh.com/createToken/?GET=/vps/*&POST=/vps/*&PUT=/vps/*&POST=/order/cart*&GET=/me/payment/method&GET=/me/order*&POST=/me/order*) (the rights are already filled in), and save them in the vault as an item called `ovh-api`, with the fields `endpoint` (`ovh-eu`), `application_key`, `application_secret` and `consumer_key`.
- **The VPS.** `make apply` orders one and pays with your account's default payment method. If you already have one, put its `service_name` in your tfvars instead. Either way, the first `make apply` reinstalls it, so anything already on it is lost.
- **After `make pair`**, run `make lockdown`: from then on, SSH only answers over the tailnet.

## Your own tools

The host runs an image with Claude, `gh`, `git`, Docker, Node, Python and Ruby. For anything else, such as the MCP servers that let Claude read Notion or Slack, you build your own image on top of it. Nothing gets installed on the host by hand, so a rebuilt host comes back exactly the same.

Keep a `Dockerfile` in a repository of yours, for instance next to your config files:

```dockerfile
# Notion's MCP server is an npm package: install it with npm, then copy it over
FROM node:22-slim AS notion
RUN npm install --global --omit=dev --prefix /opt/notion-mcp @notionhq/notion-mcp-server@2.5.2

FROM ghcr.io/qrafttech/orca-host:main

# Slack's MCP server is a single binary
ARG TARGETARCH
RUN curl -fsSL -o /usr/local/bin/slack-mcp-server \
      "https://github.com/korotovsky/slack-mcp-server/releases/download/v1.3.0/slack-mcp-server-linux-${TARGETARCH}" \
 && chmod +x /usr/local/bin/slack-mcp-server

COPY --from=notion /opt/notion-mcp /opt/notion-mcp
RUN ln -s /opt/notion-mcp/bin/notion-mcp-server /usr/local/bin/notion-mcp-server
```

Have your CI build it and publish it as a public image, for instance `ghcr.io/me/orca-host:main`. Then add `orca_image = "ghcr.io/me/orca-host:main"` to your tfvars and run `make rebuild`, once. From then on, the host picks up every new build of your image by itself. To follow the updates of this base image too, turn on Dependabot for Docker in that repository.

## Claude settings

Two optional lines in `.env.tpl` set up Claude on the host:

```sh
CLAUDE_PERMISSION_MODE=auto              # or default, acceptEdits, plan
CLAUDE_SETTINGS_REPO=me/claude-settings  # a repository of yours, applied every time the host starts
```

That repository holds your `CLAUDE.md`, your permissions in `settings.json`, your skills in `.claude/skills/`, and your MCP servers in `config/mcp.json`. To give Claude the Notion and Slack servers of your own image:

```json
{
  "mcpServers": {
    "notion": { "command": "notion-mcp-server", "env": { "NOTION_TOKEN": "${NOTION_TOKEN}" } },
    "slack": { "command": "slack-mcp-server", "args": ["-t", "stdio"], "env": { "SLACK_MCP_XOXP_TOKEN": "${SLACK_TOKEN}" } }
  }
}
```

and their tokens to `.env.tpl`:

```sh
NOTION_TOKEN={{ op://AI Agents/notion/token }}
SLACK_TOKEN={{ op://AI Agents/slack/token }}
```

Push, then `make restart`. More in [claude-settings.md](.claude/knowledge/claude-settings.md).

## Projects

In the app, click Add a project → Clone from URL, paste the https URL, and choose `/home/orca` as the parent folder.

Each project starts itself from its worktree setup hook (`docker compose`, `op inject -i .env.tpl -o .env`, and so on). Whatever it runs is at `http://<tailnet IP>:<port>`. When you delete a worktree, the host cleans up after it within five minutes.

## Day to day

| Command | What it does |
|---|---|
| `make restart` | restarts the host with your latest `.env.tpl`, tokens and Claude settings |
| `make rebuild` | rebuilds the machine, after you change `orca_image` or this repository's `compose.yaml` or `host/` |
| `make logs` | shows the host's logs |
| `make shell` | opens a terminal like the ones in Orca |
| `make ssh` | opens a terminal on the machine itself |
| `make secret` | gives the host a new 1Password token, once you've renewed it; then `make restart` |
| `make destroy` | deletes the host for good (Google Cloud) |

A new build of this image, or of your own, reaches the host by itself within five minutes. `restart` and `rebuild` close the terminals you have open, but your checkouts, your pairing and your Docker images and volumes stay.

If the host was offline when you ran `make destroy`, it is still listed in Tailscale. Remove it from the admin console (Machines), otherwise a new host with the same name will show up as `<name>-1`.

## When a command fails

| You see | Do this |
|---|---|
| `invalid_grant` … `invalid_rapt` | log in again with `gcloud auth application-default login`, then rerun the command |
| `Reauthentication required` | type your Google password at the prompt; if the command stopped, run it again |
| `Failed to lookup instance` (`make secret`) | the VM is still booting: wait a minute and try again |
| `no name in …` | `make` can't find your tfvars: `export TFVARS=<your file>` |

## Several 1Password accounts

A service account can only read one vault. If some of your secrets live in another 1Password account, create a service account there too, save its token in the host's vault, and add a second file next to `.env.tpl`:

```sh
# .env.tpl
OP_SERVICE_ACCOUNT_TOKEN_ACME={{ op://AI Agents/acme-op-token/credential }}

# .env.acme.tpl, read with that token
ACME_API_TOKEN={{ op://Acme Vault/api/credential }}
```

If one of these files can't be read, the host won't start. Every session can see these tokens, so keep those vaults for technical tokens only, and read-only.

## Contribute

Something missing, or broken? Changes are welcome.

1. Make your change on a branch and push it. CI checks it and publishes an image tagged with your branch name, slashes turned into dashes.
2. Try it on your own host: set `orca_image = "ghcr.io/qrafttech/orca-host:<your-branch>"` in your tfvars, run `make rebuild`, and use the host as usual. Or try it on your Mac, with Docker Desktop: `make build`, then `make up`.
3. Open a pull request. [AGENTS.md](AGENTS.md) has the few rules the repository follows; Claude reads it too.

Once it's merged, every host on the base image gets it within five minutes. Set `orca_image` back afterwards.
