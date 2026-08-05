#!/usr/bin/env bash
#
# Installs cyrus-ai into the persistent volume on first start, wires up git/gh
# credentials, prunes stale worktrees, then hands over to the Cyrus CLI.
#
# Everything written here lands under $CYRUS_HOME (the PVC), so the container
# root filesystem can stay read-only.

set -euo pipefail

log() { printf '[entrypoint] %s\n' "$*" >&2; }

: "${CYRUS_HOME:=/home/cyrus/.cyrus}"
: "${CYRUS_VERSION:?CYRUS_VERSION must be set}"
: "${NPM_CONFIG_PREFIX:=${CYRUS_HOME}/npm}"

mkdir -p \
    "${CYRUS_HOME}/npm" \
    "${CYRUS_HOME}/cache" \
    "${CYRUS_HOME}/repos" \
    "${CYRUS_HOME}/workspaces" \
    "${CYRUS_HOME}/seed" \
    "${CYRUS_HOME}/scripts" \
    "${CYRUS_HOME}/claude" \
    "${CYRUS_HOME}/mise/state" \
    "${CYRUS_HOME}/state" \
    "${CYRUS_HOME}/codex" \
    "${CYRUS_HOME}/worktrees" \
    "${CYRUS_HOME}/playwright"

# --- 1. install cyrus-ai (idempotent, version-stamped, integrity-checked) -----
#
# A version pin says "whatever the registry serves under 0.2.67". CYRUS_INTEGRITY
# pins the bytes: the tarball's advertised SRI hash is compared against the
# expected one, and then against the tarball actually downloaded, before
# anything is unpacked or executed.

verify_integrity() {
    local version="$1" expected="$2"
    local meta advertised url actual

    meta="$(npm view "cyrus-ai@${version}" dist.integrity dist.tarball --json)"
    advertised="$(printf '%s' "${meta}" | jq -r '.["dist.integrity"] // .integrity // .[0]')"
    url="$(printf '%s' "${meta}" | jq -r '.["dist.tarball"] // .tarball // .[1]')"

    if [[ "${advertised}" != "${expected}" ]]; then
        log "FATAL: registry metadata for cyrus-ai@${version} advertises integrity"
        log "         ${advertised}"
        log "       but CYRUS_INTEGRITY pins"
        log "         ${expected}"
        log "       Refusing to install. Either the pin is stale or the package was republished."
        return 1
    fi

    curl -fsSL "${url}" -o /tmp/cyrus-ai.tgz
    actual="sha512-$(openssl dgst -sha512 -binary /tmp/cyrus-ai.tgz | openssl base64 -A)"
    rm -f /tmp/cyrus-ai.tgz

    if [[ "${actual}" != "${expected}" ]]; then
        log "FATAL: downloaded tarball hashes to ${actual}, expected ${expected}"
        return 1
    fi

    log "integrity verified: cyrus-ai@${version} matches the pinned hash"
}

install_from_lockfile() {
    # Pins the whole closure, not just the top tarball. `npm ci` refuses to
    # resolve anything: every one of the ~278 packages comes from the lockfile
    # at its recorded integrity hash, which is the only way the executable
    # payloads down there (codex, cloudflared, cursorsandbox, rg) are pinned.
    local appdir="${CYRUS_HOME}/app"
    mkdir -p "${appdir}"
    printf '{"name":"cyrus-runtime","version":"1.0.0","private":true,"dependencies":{"cyrus-ai":"%s"}}\n' \
        "${CYRUS_VERSION}" > "${appdir}/package.json"
    cp "${CYRUS_LOCKFILE}" "${appdir}/package-lock.json"

    log "installing from lockfile (npm ci) — full closure pinned"
    ( cd "${appdir}" && npm ci --omit=dev --no-fund --no-audit )
}

# The marker is per-branch AND keyed on the lockfile's content, not on the
# version alone. With a single version-keyed marker, turning on
# cyrus.lockfileConfigMap for an existing release was a silent no-op — the pod
# saw "already present", skipped npm ci, and kept running the semver-resolved
# closure while the operator believed the closure was pinned. Editing the
# lockfile to patch a transitive CVE was ignored for the same reason.
if [[ -n "${CYRUS_LOCKFILE:-}" && -f "${CYRUS_LOCKFILE}" ]]; then
    lock_digest="$(sha256sum "${CYRUS_LOCKFILE}" | cut -c1-12)"
    marker="${CYRUS_HOME}/app/.cyrus-installed-${CYRUS_VERSION}-${lock_digest}"
else
    marker="${NPM_CONFIG_PREFIX}/.cyrus-installed-${CYRUS_VERSION}"
fi

if [[ ! -f "${marker}" ]]; then
    if [[ -n "${CYRUS_LOCKFILE:-}" && -f "${CYRUS_LOCKFILE}" ]]; then
        install_from_lockfile
    else
        if [[ -n "${CYRUS_INTEGRITY:-}" ]]; then
            verify_integrity "${CYRUS_VERSION}" "${CYRUS_INTEGRITY}"
        else
            log "WARN: CYRUS_INTEGRITY unset — installing whatever the registry serves for ${CYRUS_VERSION}"
        fi
        # Scope warning, so nobody mistakes this for a pinned closure: the
        # integrity hash covers the cyrus-ai tarball only. 11 of its 17 direct
        # dependencies are caret ranges, and ~278 packages resolve here by
        # semver at this moment. Set cyrus.lockfileConfigMap to close that.
        log "WARN: transitive dependencies resolve by semver — only the cyrus-ai tarball is pinned"
        log "installing cyrus-ai@${CYRUS_VERSION} into ${NPM_CONFIG_PREFIX}"
        npm install -g --no-fund --no-audit "cyrus-ai@${CYRUS_VERSION}"
    fi
    rm -f "${NPM_CONFIG_PREFIX}"/.cyrus-installed-* "${CYRUS_HOME}"/app/.cyrus-installed-*
    mkdir -p "$(dirname "${marker}")"
    touch "${marker}"
else
    log "cyrus-ai@${CYRUS_VERSION} already present"
fi

# --- 1b. language toolchains via mise ----------------------------------------
#
# One image instead of an image per language. Installed into the volume, so this
# is a first-boot cost only. Compiled runtimes mise would build from source (PHP)
# belong in a purpose-built image tag instead — see the README.

if [[ -n "${CYRUS_TOOLCHAINS:-}" ]]; then
    for tool in ${CYRUS_TOOLCHAINS}; do
        log "mise: ensuring ${tool}"
        mise use --global --yes "${tool}" || log "WARN: mise failed to install ${tool}"
    done
    mise reshim >/dev/null 2>&1 || true
fi

# --- 2. config.json ----------------------------------------------------------
#
# The chart mounts the rendered config at /config/config.json. It is copied,
# not symlinked: Cyrus watches this file and its config-updater package may
# rewrite it at runtime, which fails against a read-only ConfigMap mount.
# The ConfigMap is the source of truth — runtime edits are lost on restart.

if [[ -f /config/config.json ]]; then
    # Credentials are substituted in here, not stored in the ConfigMap.
    #
    # This exists because Cyrus has no env var for the Linear token: it is read
    # from config.linearWorkspaces[<id>].linearToken (cyrus-core
    # config-schemas.js, z.string(), required), and a repository without
    # linearWorkspaceId throws "is not linked to a Linear workspace" at every
    # webhook. Rendering that token into the ConfigMap would put a credential
    # in cleartext in git, so the ConfigMap carries ${LINEAR_OAUTH_TOKEN} and
    # the value arrives from the Secret via envFrom at boot.
    #
    # envsubst is given an explicit allowlist rather than free rein, so a `$`
    # in a prompt template or setup script is left alone.
    subst_vars="${CYRUS_CONFIG_SUBST_VARS:-}"
    if [[ -n "${subst_vars}" ]]; then
        shell_format=""
        for v in ${subst_vars}; do shell_format+="\${${v}}"; done
        log "rendering config.json (substituting: ${subst_vars})"
        envsubst "${shell_format}" < /config/config.json > "${CYRUS_HOME}/config.json"

        # An unset variable expands to empty, which Cyrus accepts as a valid
        # string and then fails on at the first API call. Fail here instead.
        for v in ${subst_vars}; do
            if grep -q "\${${v}}" /config/config.json && [[ -z "${!v:-}" ]]; then
                log "FATAL: config.json references \${${v}} but that variable is empty."
                log "       Check secrets.existingSecret contains the key ${v}."
                exit 1
            fi
        done
    else
        log "seeding config.json from ConfigMap"
        cp /config/config.json "${CYRUS_HOME}/config.json"
    fi
    chmod 0600 "${CYRUS_HOME}/config.json"
fi

if [[ -d /config/scripts ]]; then
    cp /config/scripts/* "${CYRUS_HOME}/scripts/" 2>/dev/null || true
    chmod +x "${CYRUS_HOME}"/scripts/* 2>/dev/null || true
fi

# --- 3. git / gh credentials -------------------------------------------------

git config --global user.name  "${GIT_AUTHOR_NAME:-Cyrus}"
git config --global user.email "${GIT_AUTHOR_EMAIL:-cyrus@users.noreply.github.com}"
git config --global init.defaultBranch main
# Worktrees live outside the repo dir; without this git refuses to operate on
# them when uid/gid ownership differs after a volume restore.
git config --global --add safe.directory '*'

if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    export GH_TOKEN="${GITHUB_TOKEN}"
    log "configuring git credentials for github.com via gh"
    gh auth setup-git --hostname "${GITHUB_HOST:-github.com}" || \
        log "WARN: gh auth setup-git failed; pushes may not authenticate"
fi

if [[ -n "${GITLAB_TOKEN:-}" ]]; then
    log "configuring git credentials for ${GITLAB_HOST:-gitlab.com}"
    # shellcheck disable=SC2016  # deliberate: the helper body is expanded by the
    # shell git spawns at credential time, not by this one.
    git config --global "credential.https://${GITLAB_HOST:-gitlab.com}.helper" \
        '!f() { echo username=oauth2; echo "password=${GITLAB_TOKEN}"; }; f'
fi

# --- 4. clone configured repositories ----------------------------------------
#
# CYRUS_REPOS is a space-separated list of name=url pairs, rendered by the
# chart. Existing clones are fetched, not reset — the agent may have local
# branches that are not pushed yet.

if [[ -n "${CYRUS_REPOS:-}" ]]; then
    for entry in ${CYRUS_REPOS}; do
        name="${entry%%=*}"
        url="${entry#*=}"
        dest="${CYRUS_HOME}/repos/${name}"
        if [[ -d "${dest}/.git" ]]; then
            log "fetching ${name}"
            git -C "${dest}" fetch --all --prune --quiet || log "WARN: fetch failed for ${name}"
        else
            log "cloning ${name} from ${url}"
            git clone --quiet "${url}" "${dest}" || log "WARN: clone failed for ${name}"
        fi
    done
fi

# --- 5. prune stale worktrees ------------------------------------------------
#
# Done here rather than in a CronJob: the volume is ReadWriteOnce, so a second
# pod mounting it would be unschedulable on most storage classes.

# Numeric guard: the chart passes this through as a string, so a values typo
# ("7d") used to reach `[[ ... -gt 0 ]]` and abort the entrypoint under set -e
# before cyrus ever started.
if [[ ! "${CYRUS_WORKTREE_MAX_AGE_DAYS:-0}" =~ ^[0-9]+$ ]]; then
    log "WARN: CYRUS_WORKTREE_MAX_AGE_DAYS='${CYRUS_WORKTREE_MAX_AGE_DAYS}' is not a number; skipping prune"
    CYRUS_WORKTREE_MAX_AGE_DAYS=0
fi

if [[ "${CYRUS_WORKTREE_MAX_AGE_DAYS:-0}" -gt 0 ]]; then
    log "pruning worktrees older than ${CYRUS_WORKTREE_MAX_AGE_DAYS} days"
    # Both paths: upstream's default is ~/.cyrus/worktrees (Application.js,
    # CYRUS_WORKTREES_DIR), while a config that sets workspaceBaseDir by hand
    # may use ~/.cyrus/workspaces. Pruning only the latter made a default-on
    # feature a silent no-op for anyone who used self-add-repo.
    find "${CYRUS_HOME}/worktrees" "${CYRUS_HOME}/workspaces" \
        -mindepth 2 -maxdepth 2 -type d \
        -mtime "+${CYRUS_WORKTREE_MAX_AGE_DAYS}" -exec rm -rf {} + 2>/dev/null || true
    for repo in "${CYRUS_HOME}"/repos/*/; do
        [[ -d "${repo}/.git" ]] && git -C "${repo}" worktree prune || true
    done
fi

log "starting cyrus ${CYRUS_VERSION} on port ${CYRUS_SERVER_PORT:-3456}"
exec cyrus "$@"
