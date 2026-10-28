# syntax=docker/dockerfile:1
#
# cyrus-agent-k8s runtime image.
#
# Deliberately ships NO Cyrus and NO Anthropic code. `cyrus-ai` (and its
# @anthropic-ai/claude-agent-sdk dependency, which is covered by Anthropic's
# Commercial Terms of Service rather than an open-source licence) is installed
# by entrypoint.sh at container start, into the persistent volume, with its
# tarball verified against a pinned SRI hash. That keeps this published image
# free of anything we do not have the right to redistribute, and lets you bump
# CYRUS_VERSION without rebuilding.
#
# Two published targets:
#   base  -> node, git, gh, mise. Covers JS/TS directly, and anything mise can
#            install (python, go, ruby, java, rust, bun, deno) at runtime.
#   php   -> base + PHP 8.5 + composer. A compiled runtime mise would have to
#            build from source, so it earns a dedicated tag.
#
# For anything else, derive your own — see "Bring your own toolchain" in the
# README. That is the intended path, not a workaround.

# Base images are pinned by digest, not tag: a tag is a mutable pointer, and
# "reproducible" and "whatever :2.8 means today" are different things.
# Renovate keeps these current.
# renovate: datasource=docker depName=node versioning=docker
ARG NODE_IMAGE=node:24-bookworm-slim@sha256:be8204d4bd327363357f532187b752ff62759c31bedf98e9e18fc08c9cbd605c
# renovate: datasource=docker depName=composer versioning=docker
ARG COMPOSER_IMAGE=composer:2.8@sha256:5248900ab8b5f7f880c2d62180e40960cd87f60149ec9a1abfd62ac72a02577c

# `COPY --from` does not expand variables, so the pinned composer image needs a
# named stage to be referenced from.
FROM ${COMPOSER_IMAGE} AS composer-bin

# ---------------------------------------------------------------- base -------
FROM ${NODE_IMAGE} AS base

ARG TARGETARCH
# renovate: datasource=github-releases depName=jdx/mise
ARG MISE_VERSION=v2026.8.2
ARG MISE_SHA256_amd64=febda574ac4e036bf91e1ef9d33ec5e24dbfad6839eb0defa6abc12125186b74

ENV DEBIAN_FRONTEND=noninteractive \
    HOME=/home/cyrus \
    CYRUS_HOME=/home/cyrus/.cyrus \
    NPM_CONFIG_PREFIX=/home/cyrus/.cyrus/npm \
    NPM_CONFIG_CACHE=/home/cyrus/.cyrus/cache/npm \
    GIT_CONFIG_GLOBAL=/home/cyrus/.cyrus/gitconfig \
    GH_CONFIG_DIR=/home/cyrus/.cyrus/gh \
    CLAUDE_CONFIG_DIR=/home/cyrus/.cyrus/claude \
    MISE_DATA_DIR=/home/cyrus/.cyrus/mise \
    MISE_CACHE_DIR=/home/cyrus/.cyrus/cache/mise \
    MISE_CONFIG_DIR=/home/cyrus/.cyrus/mise/config \
    MISE_STATE_DIR=/home/cyrus/.cyrus/mise/state \
    CODEX_HOME=/home/cyrus/.cyrus/codex \
    XDG_CONFIG_HOME=/home/cyrus/.config \
    XDG_CACHE_HOME=/home/cyrus/.cyrus/cache \
    XDG_STATE_HOME=/home/cyrus/.cyrus/state \
    XDG_DATA_HOME=/home/cyrus/.cyrus/share \
    CHROME_BIN=/usr/bin/chromium \
    PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium \
    PUPPETEER_SKIP_DOWNLOAD=true \
    PLAYWRIGHT_BROWSERS_PATH=/home/cyrus/.cyrus/playwright

ENV PATH=/home/cyrus/.cyrus/app/node_modules/.bin:/home/cyrus/.cyrus/npm/bin:/home/cyrus/.cyrus/mise/shims:$PATH

# node:24 already ships uid/gid 1000 as `node`; rename rather than add a second
# uid-1000 user, so file ownership on the PVC stays unambiguous.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg git jq unzip zip xz-utils less procps tini openssh-client \
        socat bubblewrap gettext-base; \
    # Headless browser. Present because an agent that can't take a screenshot or
    # run a browser test is half-blind, and because the failure mode without it
    # is a cryptic shared-library error rather than "no browser installed".
    #
    # chromium here is the general-purpose one (CHROME_BIN, puppeteer, MCP
    # browser tools). Playwright is deliberately NOT pointed at it: Playwright
    # pins a browser build per version, and a mismatched system Chromium fails
    # in ways that waste an afternoon. PLAYWRIGHT_BROWSERS_PATH sends
    # `npx playwright install chromium` to the volume instead, so each repo gets
    # the build it expects, cached across worktrees. The system libraries below
    # are what that download needs and does not bring.
    apt-get install -y --no-install-recommends \
        chromium \
        fonts-liberation fonts-noto-color-emoji \
        libasound2 libatk-bridge2.0-0 libatk1.0-0 libcups2 libdbus-1-3 \
        libdrm2 libgbm1 libgtk-3-0 libnspr4 libnss3 libpango-1.0-0 \
        libx11-xcb1 libxcomposite1 libxdamage1 libxfixes3 libxkbcommon0 \
        libxrandr2 xdg-utils; \
    install -m 0755 -d /usr/share/keyrings; \
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        -o /usr/share/keyrings/githubcli-archive-keyring.gpg; \
    chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg; \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends gh; \
    rm -rf /var/lib/apt/lists/*

# Before anything can create /home/cyrus behind our back — `usermod -m` refuses
# to move the home directory onto an existing one (exit 12), and running mise
# under HOME=/home/cyrus is exactly what would create it.
RUN set -eux; \
    usermod -l cyrus -d /home/cyrus -m node; \
    groupmod -n cyrus node; \
    mkdir -p /home/cyrus/.cyrus /home/cyrus/.config; \
    chown -R 1000:1000 /home/cyrus

# npm's own vendored dependencies, patched in place. The npm that ships with
# node 24.22.1 (11.19.1) bundles undici 6.28.0 — used only by node-gyp to
# download Node headers, and affected by a TLS certificate-validation bypass
# (CVE-2026-109383) plus three DoS CVEs — and brace-expansion 5.0.9 (two DoS
# CVEs). Not even npm 12.2.1 carries the fixed undici (6.29.1). Both
# replacements are drop-in within the ranges npm declares (node-gyp: undici
# ^6.25.0; minimatch: brace-expansion ^5.0.5, whose balanced-match ^4.0.2 is
# already bundled). Drop this step once a node image ships an npm with both.
# After the usermod step: npm must not create /home/cyrus before it runs, so
# its cache goes to /tmp and is removed again.
RUN set -eux; \
    cd /usr/local/lib/node_modules/npm/node_modules; \
    for spec in undici@6.29.1 brace-expansion@5.0.12; do \
        name="${spec%@*}"; \
        tgz="$(NPM_CONFIG_CACHE=/tmp/npm-cache npm pack "${spec}" --silent)"; \
        rm -rf "${name}"; \
        mkdir "${name}"; \
        tar -xzf "${tgz}" -C "${name}" --strip-components=1 --no-same-owner; \
        rm -f "${tgz}"; \
    done; \
    rm -rf /tmp/npm-cache; \
    node -e 'require("/usr/local/lib/node_modules/npm/node_modules/undici"); require("/usr/local/lib/node_modules/npm/node_modules/minimatch")'; \
    npm --version

# mise, verified against a pinned checksum rather than piped from a shell script.
RUN set -eux; \
    case "${TARGETARCH:-amd64}" in \
        amd64) arch=x64; sha="${MISE_SHA256_amd64}" ;; \
        *) echo "unsupported TARGETARCH=${TARGETARCH}; add its checksum to the Dockerfile" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/mise.tar.gz \
        "https://github.com/jdx/mise/releases/download/${MISE_VERSION}/mise-${MISE_VERSION}-linux-${arch}.tar.gz"; \
    echo "${sha}  /tmp/mise.tar.gz" | sha256sum -c -; \
    tar -xzf /tmp/mise.tar.gz -C /tmp; \
    install -m 0755 /tmp/mise/bin/mise /usr/local/bin/mise; \
    rm -rf /tmp/mise /tmp/mise.tar.gz; \
    HOME=/root mise --version; \
    chown -R 1000:1000 /home/cyrus

COPY --chown=1000:1000 entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh

USER 1000:1000
WORKDIR /home/cyrus

# CYRUS_VERSION is overridden by the chart; this is only the fallback.
# CYRUS_HOST_EXTERNAL is not a preference: Cyrus binds to localhost unless it is
# exactly "true", and in a container that means nothing outside the pod can
# reach it — including the kubelet running the probes.
ENV CYRUS_VERSION=0.2.67 \
    CYRUS_SERVER_PORT=3456 \
    CYRUS_HOST_EXTERNAL=true

EXPOSE 3456
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]

# ----------------------------------------------------------------- php -------
FROM base AS php

ARG PHP_VERSION=8.5

ENV COMPOSER_HOME=/home/cyrus/.cyrus/composer \
    COMPOSER_CACHE_DIR=/home/cyrus/.cyrus/cache/composer \
    COMPOSER_ALLOW_SUPERUSER=0

USER root

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends apt-transport-https lsb-release; \
    curl -fsSL https://packages.sury.org/php/apt.gpg -o /usr/share/keyrings/sury-php.gpg; \
    echo "deb [signed-by=/usr/share/keyrings/sury-php.gpg] https://packages.sury.org/php/ bookworm main" \
        > /etc/apt/sources.list.d/sury-php.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        php${PHP_VERSION}-cli \
        php${PHP_VERSION}-bcmath \
        php${PHP_VERSION}-curl \
        php${PHP_VERSION}-gd \
        php${PHP_VERSION}-intl \
        php${PHP_VERSION}-mbstring \
        php${PHP_VERSION}-mysql \
        php${PHP_VERSION}-pgsql \
        php${PHP_VERSION}-redis \
        php${PHP_VERSION}-sqlite3 \
        php${PHP_VERSION}-xml \
        php${PHP_VERSION}-zip; \
    rm -rf /var/lib/apt/lists/*

COPY --from=composer-bin /usr/bin/composer /usr/local/bin/composer

USER 1000:1000
