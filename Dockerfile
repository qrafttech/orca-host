# syntax=docker/dockerfile:1
# orca-host — `orca serve` headless, with the tools an Orca worktree needs: claude, gh, git, docker CLI + compose.
# Built for amd64 and arm64. State is not in the image: /home/orca is a volume, see compose.yaml.

ARG ORCA_VERSION=1.4.205
ARG CLAUDE_CODE_VERSION=2.1.276
ARG GH_VERSION=2.101.0
ARG DOCKER_VERSION=29.8.1

# --- Orca: the official AppImage, extracted once (no FUSE in a container) ---------------------------------
# An AppImage is an ELF runtime with a squashfs appended: unsquashfs at the runtime's size extracts it without
# executing anything, so the arm64 image builds under QEMU (the AppImage magic bytes in the ELF header make the
# kernel's binfmt rule refuse to run it there).
FROM debian:12-slim AS orca
ARG ORCA_VERSION
ARG TARGETARCH
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl binutils squashfs-tools \
 && rm -rf /var/lib/apt/lists/*
RUN case "$TARGETARCH" in amd64) asset=orca-linux.AppImage ;; arm64) asset=orca-linux-arm64.AppImage ;; *) exit 1 ;; esac \
 && curl -fsSL -o /tmp/orca.AppImage "https://github.com/stablyai/orca/releases/download/v${ORCA_VERSION}/${asset}" \
 && offset=$(readelf -h /tmp/orca.AppImage | awk '/Start of section headers/ {o=$5} /Size of section headers/ {s=$5} /Number of section headers/ {n=$5} END {print o + s * n}') \
 && unsquashfs -q -n -o "$offset" -d /opt/orca /tmp/orca.AppImage >/dev/null \
 && chmod -R a+rX /opt/orca && rm /tmp/orca.AppImage

# --- Claude Code: the native binary, checksum from the release manifest --------------------------------------
FROM debian:12-slim AS claude
ARG CLAUDE_CODE_VERSION
ARG TARGETARCH
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl jq && rm -rf /var/lib/apt/lists/*
RUN case "$TARGETARCH" in amd64) platform=linux-x64 ;; arm64) platform=linux-arm64 ;; *) exit 1 ;; esac \
 && base="https://downloads.claude.ai/claude-code-releases/${CLAUDE_CODE_VERSION}" \
 && curl -fsSL -o /tmp/claude "${base}/${platform}/claude" \
 && echo "$(curl -fsSL "${base}/manifest.json" | jq -r ".platforms[\"${platform}\"].checksum")  /tmp/claude" | sha256sum -c - \
 && install -D -m 755 /tmp/claude "/opt/claude/${CLAUDE_CODE_VERSION}/claude"

# --- gh --------------------------------------------------------------------------------------------------------
FROM debian:12-slim AS gh
ARG GH_VERSION
ARG TARGETARCH
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_${TARGETARCH}.tar.gz" \
    | tar -xz -C /tmp \
 && install -m 755 "/tmp/gh_${GH_VERSION}_linux_${TARGETARCH}/bin/gh" /usr/local/bin/gh

# --- docker CLI + compose plugin, static binaries from the official image ------------------------------------
FROM docker:${DOCKER_VERSION}-cli AS docker-cli

# --- the image -------------------------------------------------------------------------------------------------
FROM debian:12-slim
ARG CLAUDE_CODE_VERSION
ENV DEBIAN_FRONTEND=noninteractive
# Electron runtime libraries (Orca's headless-linux-server doc, Debian 12 names), Xvfb (Orca starts it itself),
# the tools a worktree setup hook may call, and the interpreters a project's Claude Code hooks may need: hooks run
# here, next to claude, not in the project's containers. The app's own runtime, at its own version, is in those.
RUN apt-get update && apt-get install -y --no-install-recommends \
      bash ca-certificates curl git jq make lsof procps iproute2 util-linux xvfb xauth zlib1g \
      ruby python3 nodejs \
      libgtk-3-0 libnss3 libatk1.0-0 libatk-bridge2.0-0 libgbm1 libasound2 \
      libxtst6 libcups2 libdrm2 libxkbcommon0 libpango-1.0-0 libcairo2 libatspi2.0-0 \
      libxcomposite1 libxdamage1 libxfixes3 libxrandr2 libxrender1 libx11-xcb1 \
      libxcb-dri3-0 libxss1 \
 && rm -rf /var/lib/apt/lists/*

COPY --from=orca /opt/orca /opt/orca
COPY --from=claude /opt/claude /opt/claude
COPY --from=gh /usr/local/bin/gh /usr/local/bin/gh
COPY --from=docker-cli /usr/local/bin/docker /usr/local/bin/docker
COPY --from=docker-cli /usr/local/libexec/docker/cli-plugins/docker-compose /usr/local/libexec/docker/cli-plugins/docker-compose

RUN useradd --create-home --shell /bin/bash orca \
 && ln -s "/opt/claude/${CLAUDE_CODE_VERSION}/claude" /usr/local/bin/claude \
 && printf '#!/bin/sh\nexec /opt/orca/AppRun "$@"\n' > /usr/local/bin/orca && chmod 755 /usr/local/bin/orca

# Claude Code never updates itself here (the image is the version). git authenticates to GitHub through gh,
# so GH_TOKEN alone is the GitHub credential: no ssh key, no `gh auth login`.
ENV DISABLE_AUTOUPDATER=1 \
    LIBGL_ALWAYS_SOFTWARE=1 \
    GIT_CONFIG_COUNT=1 \
    GIT_CONFIG_KEY_0=credential.https://github.com.helper \
    GIT_CONFIG_VALUE_0="!gh auth git-credential"

COPY prune-stacks.sh /usr/local/bin/prune-stacks
COPY entrypoint.sh /usr/local/bin/entrypoint
ENTRYPOINT ["/usr/local/bin/entrypoint"]
