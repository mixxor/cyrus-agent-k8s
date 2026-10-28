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

# --- 0. credential custody ---------------------------------------------------
#
# llm.mode=gateway exists to keep the real model credential out of this pod.
# envFrom injects every key of secrets.existingSecret, so a real key sitting
# next to the virtual one lands in the agent's environment anyway. The chart
# cannot see the Secret's keys at render time (`lookup` returns nothing under
# `helm template` and Argo CD), so it is checked here.

if [[ "${CYRUS_LLM_MODE:-}" == "gateway" ]]; then
    for v in ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN; do
        if [[ -n "${!v:-}" ]]; then
            log "FATAL: llm.mode is gateway, but ${v} is in the environment."
            log "       Remove it from secrets.existingSecret: envFrom hands every key to the agent."
            exit 1
        fi
    done
fi

# --- 1. install cyrus-ai (idempotent, version-stamped, integrity-checked) -----
#
# A version pin says "whatever the registry serves under 0.2.67". CYRUS_INTEGRITY
# pins the bytes: the tarball's advertised SRI hash is compared against the
# expected one, and then against the tarball actually downloaded, before
# anything is unpacked or executed. npm then installs that very file, not a
# second download.

tarball=/tmp/cyrus-ai.tgz

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

    curl -fsSL "${url}" -o "${tarball}"
    actual="sha512-$(openssl dgst -sha512 -binary "${tarball}" | openssl base64 -A)"

    if [[ "${actual}" != "${expected}" ]]; then
        rm -f "${tarball}"
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
            pkg="${tarball}"
        else
            log "WARN: CYRUS_INTEGRITY unset — installing whatever the registry serves for ${CYRUS_VERSION}"
            pkg="cyrus-ai@${CYRUS_VERSION}"
        fi
        # Scope warning, so nobody mistakes this for a pinned closure: the
        # integrity hash covers the cyrus-ai tarball only. 11 of its 17 direct
        # dependencies are caret ranges, and ~278 packages resolve here by
        # semver at this moment. Set cyrus.lockfileConfigMap to close that.
        log "WARN: transitive dependencies resolve by semver — only the cyrus-ai tarball is pinned"
        log "installing cyrus-ai@${CYRUS_VERSION} into ${NPM_CONFIG_PREFIX}"
        npm install -g --no-fund --no-audit "${pkg}"
        rm -f "${tarball}"
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
    #
    # Rendered to a side file first: the previous config.json is still needed
    # below, to carry over the Linear tokens Cyrus rotated at runtime.
    rendered="${CYRUS_HOME}/config.json.rendered"
    subst_vars="${CYRUS_CONFIG_SUBST_VARS:-}"
    if [[ -n "${subst_vars}" ]]; then
        shell_format=""
        for v in ${subst_vars}; do shell_format+="\${${v}}"; done
        log "rendering config.json (substituting: ${subst_vars})"
        envsubst "${shell_format}" < /config/config.json > "${rendered}"

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
        cp /config/config.json "${rendered}"
    fi

    # Linear OAuth access tokens live 24 hours, and every refresh ROTATES the
    # refresh token as well (https://linear.app/developers/oauth-2-0-authentication).
    # Cyrus refreshes on its own and writes the new pair into config.json — the
    # very file this block replaces. Re-seeding the Secret's pair on every start
    # would put back a refresh token Linear has already retired, and the pod
    # would lose Linear access on the first restart after a refresh, while
    # staying Ready and answering /version.
    #
    # So the pair Cyrus last persisted wins, as long as the Secret still holds
    # the pair that was seeded before it. A changed Secret (a fresh bootstrap)
    # wins over the volume: that is how an operator recovers from a dead token.
    seed_marker="${CYRUS_HOME}/state/linear-token-seed.sha256"
    seed_digest="$(jq -c '[(.linearWorkspaces // {}) | to_entries[]
        | [.key, .value.linearToken, .value.linearRefreshToken]]' "${rendered}" \
        | sha256sum | cut -d' ' -f1)"
    if [[ -f "${CYRUS_HOME}/config.json" && -f "${seed_marker}" \
          && "$(cat "${seed_marker}")" == "${seed_digest}" ]]; then
        if jq --slurpfile prev "${CYRUS_HOME}/config.json" '
                if .linearWorkspaces then
                  .linearWorkspaces |= with_entries(
                    .key as $id
                    | ($prev[0].linearWorkspaces[$id] // {}) as $p
                    | if ($p.linearToken // "") != "" and ($p.linearRefreshToken // "") != ""
                      then .value.linearToken = $p.linearToken
                         | .value.linearRefreshToken = $p.linearRefreshToken
                      else . end)
                else . end' "${rendered}" > "${rendered}.merged" 2>/dev/null; then
            mv "${rendered}.merged" "${rendered}"
            log "keeping the Linear tokens Cyrus persisted (Secret unchanged since they were seeded)"
        else
            rm -f "${rendered}.merged"
            log "WARN: previous config.json unreadable — seeding Linear tokens from the Secret"
        fi
    else
        log "seeding Linear tokens from the Secret"
    fi
    printf '%s\n' "${seed_digest}" > "${seed_marker}"
    mv "${rendered}" "${CYRUS_HOME}/config.json"
    chmod 0600 "${CYRUS_HOME}/config.json"
fi

if [[ -d /config/scripts ]]; then
    cp /config/scripts/* "${CYRUS_HOME}/scripts/" 2>/dev/null || true
    chmod +x "${CYRUS_HOME}"/scripts/* 2>/dev/null || true
fi

# --- 3. git / gh credentials -------------------------------------------------

git config --global user.name  "${GIT_AUTHOR_NAME:-Cyrus Agent}"
git config --global user.email "${GIT_AUTHOR_EMAIL:-cyrus-agent@example.invalid}"
git config --global init.defaultBranch main
# Worktrees live outside the repo dir; without this git refuses to operate on
# them when uid/gid ownership differs after a volume restore. --replace-all,
# not --add: the gitconfig is on the volume, and --add appended a line per start.
git config --global --replace-all safe.directory '*'

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

# Worktrees are found through git, not by directory depth. Cyrus puts one at
# <workspaceBaseDir>/<ISSUE-ID> (GitService.createSingleRepoWorktree): depth 2
# under ~/.cyrus/worktrees with a per-repo workspaceBaseDir, depth 1 with
# self-add-repo's default, where a fixed-depth find deleted directories INSIDE
# live worktrees. Only worktrees under ~/.cyrus/worktrees and
# ~/.cyrus/workspaces are candidates (upstream default and hand-set configs).
#
# "Untouched" means no entry in the worktree or its git metadata is newer than
# the cut-off. The worktree root's own mtime does not move when the agent edits
# app/Http/..., so it alone made an issue worked on for a week look abandoned.
#
# `git worktree remove` without --force refuses modified or untracked files,
# so uncommitted work is never deleted; ignored files (vendor/, node_modules/)
# do not count. Committed work lives on the branch in the main repository.
if [[ "${CYRUS_WORKTREE_MAX_AGE_DAYS:-0}" -gt 0 ]]; then
    days="${CYRUS_WORKTREE_MAX_AGE_DAYS}"
    log "pruning clean worktrees untouched for more than ${days} days"
    for repo in "${CYRUS_HOME}"/repos/*/; do
        [[ -d "${repo}/.git" ]] || continue
        git -C "${repo}" worktree prune || true
        while IFS= read -r wt; do
            case "${wt}" in
                "${CYRUS_HOME}/worktrees/"* | "${CYRUS_HOME}/workspaces/"*) ;;
                *) continue ;;
            esac
            gitdir="$(git -C "${wt}" rev-parse --absolute-git-dir 2>/dev/null)" || continue
            if [[ -n "$(find "${wt}" "${gitdir}" ! -mtime "+${days}" -print -quit 2>/dev/null)" ]]; then
                continue
            fi
            if git -C "${repo}" worktree remove "${wt}" 2>/dev/null; then
                log "removed stale worktree ${wt}"
            else
                log "WARN: keeping stale worktree ${wt}: uncommitted changes, or locked"
            fi
        done < <(git -C "${repo}" worktree list --porcelain | sed -n 's/^worktree //p')
    done
fi

log "starting cyrus ${CYRUS_VERSION} on port ${CYRUS_SERVER_PORT:-3456}"
exec cyrus "$@"
