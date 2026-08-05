# cyrus-agent-k8s

Run [Cyrus](https://github.com/cyrusagents/cyrus) — the AI coding agent for Linear, GitHub, GitLab and Slack — on Kubernetes.

Upstream ships as an npm package meant to live under tmux, pm2 or systemd on a machine you own. This repo provides the missing pieces for a cluster: a runtime image, and a Helm chart that treats Cyrus as what it is — a single stateful worker holding git worktrees on a persistent volume behind a webhook endpoint.

> **Unofficial.** Not affiliated with, endorsed by, or supported by Cyrus Agents. Issues with *this packaging* belong here; issues with Cyrus itself belong [upstream](https://github.com/cyrusagents/cyrus/issues).

## What you get

| | |
|---|---|
| `ghcr.io/mixxor/cyrus-agent-k8s:vX.Y.Z` | node 24, git, gh CLI, mise, headless Chromium, on Debian bookworm |
| `ghcr.io/mixxor/cyrus-agent-k8s:vX.Y.Z-php` | the above plus PHP 8.5 and composer, for Laravel/Symfony repos |
| `chart/cyrus` | StatefulSet, PVC, Service, Ingress, NetworkPolicy, tokenless ServiceAccount |
| `chart/cyrus` + `litellm.enabled` | optional bundled LLM gateway, so the model credential never enters the agent pod |

Images are signed with cosign and carry SLSA provenance and an SBOM. See [SECURITY.md](SECURITY.md) for verification, and for the credential-exposure threat model that matters more than any of it.

The chart is dependency-free and secret-manager agnostic: it consumes one existing Kubernetes `Secret`. Create it with kubectl, External Secrets Operator, Sealed Secrets, Vault Agent, SOPS — the chart neither knows nor cares.

### The images contain no Cyrus and no Anthropic code

`cyrus-ai` depends on `@anthropic-ai/claude-agent-sdk`, which is **not** open source — its licence field reads `SEE LICENSE IN README.md`, and that README points at [Anthropic's Commercial Terms of Service](https://www.anthropic.com/legal/commercial-terms). Those terms govern *use*; they do not grant redistribution rights. So this image ships the OS toolchain only, and `entrypoint.sh` installs `cyrus-ai@$CYRUS_VERSION` from the public npm registry at container start, into the persistent volume, as the operator running it.

Three consequences worth knowing:

- Nothing here redistributes code we lack the right to redistribute.
- Upgrading Cyrus is `cyrus.version: 0.2.68` plus a pod restart — no image rebuild.
- First boot takes a couple of minutes. Subsequent restarts reuse the volume.

### Pinning the runtime fetch

`cyrus.integrity` holds the SRI hash of the `cyrus-ai` tarball, and the entrypoint refuses to install on a mismatch. **That pins exactly one package.** `cyrus-ai` has 17 direct dependencies, 11 of them caret ranges, and installing it resolves ~278 packages by semver at container start — including the executables that actually run your code: the Codex CLI, `cloudflared`, `cursorsandbox`, `rg`. Pinning the top tarball while its closure floats is the same mistake as signing an image and calling the supply chain solved.

To pin the closure, set `cyrus.lockfileConfigMap`. The entrypoint then runs `npm ci` against your lockfile, so every package comes from it at its recorded integrity hash and nothing resolves at runtime:

```bash
mkdir /tmp/lock && cd /tmp/lock
echo '{"name":"cyrus-runtime","version":"1.0.0","private":true,
       "dependencies":{"cyrus-ai":"0.2.67"}}' > package.json
npm install --package-lock-only          # ~132K, 278 packages, 277 with integrity
kubectl create configmap cyrus-lockfile --from-file=package-lock.json
```

```yaml
cyrus:
  version: "0.2.67"
  lockfileConfigMap: cyrus-lockfile      # regenerate whenever you bump version
```

Without it the entrypoint logs `WARN: transitive dependencies resolve by semver` on every install, so the weaker posture is never silent.

## One release per repository

Upstream's answer to multiple repositories is one instance with `routingLabels` and multi-repo routing. That works, and on a single VM it is the only option. On Kubernetes the unit of deployment is cheap, so the better shape is **a Helm release per repository**:

```bash
helm install cyrus-frontend ./chart/cyrus -f frontend.yaml -n cyrus-frontend
helm install cyrus-api      ./chart/cyrus -f api.yaml      -n cyrus-api
```

What that buys, none of which the single-instance model can give you:

- **Blast radius.** One git token per agent, scoped to one repository. This README says a token that can push to every repo in the org is a token the agent can push to every repo in the org — a release per repo is the only way to actually honour that.
- **Per-team toolchains.** The Laravel repo takes `-php`, the Go repo takes a derived image. No combinatorial image, no shared `toolchains` list that has to satisfy everyone.
- **Per-agent spend.** One LiteLLM virtual key per release, so budgets and audit land on the right cost centre without any extra bookkeeping.
- **Independent failure.** The one-replica limit below stops being a limit when the unit of scaling is the release.

**The cost, and you must plan for it:** each release needs **its own Linear OAuth application and its own Linear agent user**, plus its own `cyrus.baseUrl` and ingress host. Copy a release, change only the namespace, and both pods answer the same webhook and both start a session on the same issue. That is a duplicated-work bug that looks like a chart bug.

## Quick start

```bash
kubectl create namespace cyrus

kubectl -n cyrus create secret generic cyrus-secrets \
  --from-literal=CLAUDE_CODE_OAUTH_TOKEN=... \
  --from-literal=LINEAR_CLIENT_ID=... \
  --from-literal=LINEAR_CLIENT_SECRET=... \
  --from-literal=LINEAR_WEBHOOK_SECRET=... \
  --from-literal=LINEAR_OAUTH_TOKEN=... \
  --from-literal=GITHUB_TOKEN=...

helm install cyrus ./chart/cyrus -n cyrus -f my-values.yaml
```

```yaml
# my-values.yaml
cyrus:
  version: "0.2.67"
  baseUrl: https://cyrus.example.com

secrets:
  existingSecret: cyrus-secrets

repositories:
  my-app: https://github.com/acme/my-app.git

ingress:
  enabled: true
  className: nginx
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
  host: cyrus.example.com
  tls:
    enabled: true
    secretName: cyrus-tls

config:
  # REQUIRED for Linear, and the single easiest thing to get wrong: Cyrus has
  # no env var for the Linear token. It reads it from here, and a repository
  # without linearWorkspaceId throws "is not linked to a Linear workspace" on
  # every webhook — while the pod stays Ready and /version returns 200.
  #
  # ${LINEAR_OAUTH_TOKEN} is substituted from your Secret at container start
  # (see configSubstVars), so no credential lands in the ConfigMap.
  linearWorkspaces:
    "your-linear-workspace-id":
      linearToken: "${LINEAR_OAUTH_TOKEN}"
  repositories:
    - id: my-app
      name: my-app
      repositoryPath: /home/cyrus/.cyrus/repos/my-app
      workspaceBaseDir: /home/cyrus/.cyrus/worktrees/my-app
      baseBranch: main
      githubUrl: https://github.com/acme/my-app
      isActive: true
      linearWorkspaceId: "your-linear-workspace-id"   # must match the key above
      teamKeys: ["ENG"]
      labelPrompts:
        debugger: { labels: ["Bug"] }
        builder:  { labels: ["Feature"] }
        scoper:   { labels: ["PRD"] }
```

Then point your Linear webhook at `https://cyrus.example.com/linear-webhook`.

## Bootstrap: getting the tokens

Cyrus's setup flow is interactive by design — a browser OAuth round trip. Do it once on a laptop, then move the results into your secret store.

1. Create a Linear OAuth application in your workspace settings. Note the client ID and secret, and set a webhook secret.
2. Install Cyrus locally: `npm install -g cyrus-ai` and run `cyrus`. Complete the Linear OAuth flow in the browser.
3. Read `~/.cyrus/config.json`. You need two things from it: the **workspace ID** (the key under `linearWorkspaces`) and its **`linearToken`**. The workspace ID is not a secret and goes in your values; the token goes in the Secret under the key `LINEAR_OAUTH_TOKEN`.

   That env var name is this chart's convention, **not** something Cyrus reads — upstream has no environment variable for the Linear token at all. The chart substitutes it into `config.json` at container start so the credential never has to sit in a ConfigMap. If you reference `${LINEAR_OAUTH_TOKEN}` in `config` and the Secret key is missing or empty, the entrypoint aborts rather than starting an agent that cannot talk to Linear.
4. For the model credential, either an `ANTHROPIC_API_KEY` (fully headless, metered) or a `CLAUDE_CODE_OAUTH_TOKEN` from a subscription plan. The latter is cheaper at volume but is generated interactively and **expires** — plan for a refresh, and monitor for it, because an expired token fails quietly at the next session rather than at startup.
5. Put them all in the Secret, and translate the repository stanzas from your local `config.json` into the chart's `config` value.

See [docs/SELF_HOSTING.md](https://github.com/cyrusagents/cyrus/blob/main/docs/SELF_HOSTING.md) and [docs/CONFIG_FILE.md](https://github.com/cyrusagents/cyrus/blob/main/docs/CONFIG_FILE.md) upstream for what each field means.

## How work reaches the agent

Labels do not trigger Cyrus. **Delegation does.** Cyrus registers as a Linear agent user and reacts to `AgentSessionEvent` webhooks:

| In Linear | Cyrus |
|---|---|
| Assign an issue to the Cyrus agent user, or `@`-mention it | starts a session — creates a git worktree, runs the agent |
| Reply in the agent session thread | continues the same session |
| Unassign, or move the issue to a terminal state | stops the session |

Labels do two *other* jobs, both in `config`:

- `routingLabels` — which repository handles the issue. Beats `projectKeys`, which beats `teamKeys`.
- `labelPrompts` — which mode (`debugger` / `builder` / `scoper`) and which tool permissions.

## Model credentials: three modes

The agent runs model-generated shell commands, and those inherit its environment. So the question is not "is my token encrypted at rest" — it is **where the credential lives**.

```yaml
llm:
  mode: apiKey    # subscription | apiKey | gateway
```

| Mode | Pod holds | Cost | If it leaks |
|---|---|---|---|
| `subscription` | `CLAUDE_CODE_OAUTH_TOKEN` | flat | re-run the browser OAuth flow; the seat itself was exposed |
| `apiKey` | `ANTHROPIC_API_KEY` | metered | revoke the key, issue another |
| `gateway` | a virtual key | metered | revoke one virtual key; the real credential was never in the pod |

`gateway` also gets you per-session spend, budgets and an audit trail, because everything goes through one place.

### Bundled gateway

LiteLLM ships as an optional dependency — off by default, vendored into `chart/cyrus/charts/` so nothing has to resolve an OCI dependency at render time:

```yaml
llm:
  mode: gateway
litellm:
  enabled: true
  db:
    deployStandalone: true          # virtual keys and budgets need a database
  environmentSecrets:
    - litellm-secrets               # ANTHROPIC_API_KEY, PROXY_MASTER_KEY
  proxy_config:
    # One entry per name Cyrus can ask for. Cyrus selects a model per prompt
    # mode and per label, so a single `model_name: claude` entry makes the
    # gateway 404 on every request that is not literally "claude" — including
    # the aliases the config schema documents ("opus", "sonnet", "haiku") and
    # the concrete id the runner falls back to.
    model_list:
      - model_name: opus
        litellm_params: {model: anthropic/claude-opus-4-6, api_key: os.environ/ANTHROPIC_API_KEY}
      - model_name: sonnet
        litellm_params: {model: anthropic/claude-sonnet-4-5, api_key: os.environ/ANTHROPIC_API_KEY}
      - model_name: haiku
        litellm_params: {model: anthropic/claude-haiku-4-5, api_key: os.environ/ANTHROPIC_API_KEY}
      - model_name: claude-opus-4-6
        litellm_params: {model: anthropic/claude-opus-4-6, api_key: os.environ/ANTHROPIC_API_KEY}
    general_settings:
      master_key: os.environ/PROXY_MASTER_KEY
```

Check what your Cyrus version actually requests before trusting that list — `model_list` is a allowlist, and a
missing entry fails at the first session rather than at deploy time.

The chart wires `ANTHROPIC_BASE_URL` to the gateway Service and maps `LITELLM_VIRTUAL_KEY` from your Secret onto `ANTHROPIC_AUTH_TOKEN`, and opens a NetworkPolicy egress rule to it (the gateway sits in RFC1918 space, which the default policy denies). Point `llm.gateway.baseUrl` at an existing LiteLLM instead and leave `litellm.enabled: false`.

**On subscription tokens through a gateway:** LiteLLM can forward a Claude Max OAuth token via `forward_client_headers_to_llm_api`, but that is *passthrough* — the token still lives in the pod, so it buys observability, not custody. Gateway custody of a subscription token is community territory with a known upstream bug. If you want the credential out of the pod, use an API key at the gateway. Not legal advice, but a per-seat subscription driving an autonomous agent is a different shape from a person using their seat, and Cyrus runs concurrent sessions — see [SECURITY.md](SECURITY.md).

## Runners

Cyrus supports Claude, Codex, Cursor and Gemini runners. This chart is **runner-agnostic where upstream is** — it does not test four runners against every release, and the credential wiring below is Anthropic-shaped.

Verified by running `npm install -g cyrus-ai@0.2.67` inside the image and inspecting the result:

| Runner | Ships with the npm install? | Notes |
|---|---|---|
| Claude | yes (`@anthropic-ai/claude-agent-sdk`) | the tested path |
| Codex | **yes** — `@openai/codex-linux-x64` vendors a musl-static `codex` binary; `codex --version` → `codex-cli 0.144.6` | works with no image change |
| Cursor | binary ships (`@cursor/sdk-linux-x64`) | untested here |
| Gemini | pure JS, delegates to the Claude runner | untested here |

No compiler is present in these images and the install completes cleanly, so none of the four needs a native build step as packaged.

**Credentials are the catch, not the binary.** `llm.mode: gateway` gives you custody for the *Claude* runner, because it wires `ANTHROPIC_BASE_URL` and `ANTHROPIC_AUTH_TOKEN`. Codex authenticates against OpenAI with its own environment and its own flow (API key or ChatGPT subscription), so:

| Runner | Credential in pod | Gateway custody |
|---|---|---|
| Claude, `llm.mode: subscription` | `CLAUDE_CODE_OAUTH_TOKEN` | no |
| Claude, `llm.mode: apiKey` | `ANTHROPIC_API_KEY` | no |
| Claude, `llm.mode: gateway` | virtual key | **yes** |
| **Codex** | `OPENAI_API_KEY` via `secrets.existingSecret` | **no** — needs LiteLLM to front OpenAI too, and `codex` to honour `OPENAI_BASE_URL`. Unverified |

Put Codex credentials in your Secret and set `defaultRunner: "codex"` in `config`. Treat it as a documented path, not a guaranteed one.

## Browsers

Both images ship Chromium (`CHROME_BIN`, `PUPPETEER_EXECUTABLE_PATH`) plus the shared libraries headless browsers need — the ones whose absence produces a cryptic `libnss3.so` error rather than an honest "no browser installed".

Playwright is deliberately *not* pointed at that system Chromium: Playwright pins a browser build per version, and a mismatched one fails in expensive-to-diagnose ways. `PLAYWRIGHT_BROWSERS_PATH` points at the volume instead, so `npx playwright install chromium` fetches the build the repo expects, once, cached across every worktree. Put that line in your `global_setup_script` if the repo has browser tests.

## Bring your own toolchain

The agent has to build and test the code it changes, so the container needs that repository's toolchain. There is no plan to publish an image per ecosystem — that is a combinatorial trap (node+python? node 20 or 24? which PHP extensions?) and every published variant is another thing to patch. Three options instead, in the order most people should reach for them:

**1. Derive an image.** The recommended path, and about five lines:

```dockerfile
FROM ghcr.io/mixxor/cyrus-agent-k8s:v0.1.0
USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
      python3 python3-venv python3-pip && rm -rf /var/lib/apt/lists/*
USER 1000:1000
```

Push it to your own registry and set `image.repository`. You control what is in it, you patch on your own schedule, and you are not waiting on this repo to add your language.

**2. `toolchains`, via mise.** For teams without an image pipeline. Installed into the volume on first boot, no rebuild:

```yaml
toolchains:
  - python@3.13
  - go@1.23
```

Anything with a prebuilt release works well — node, python, go, ruby, java, rust, bun, deno, terraform. Runtimes mise compiles from source do not; that is why PHP gets a dedicated tag rather than a `toolchains` entry.

**3. Use the published `-php` tag** if your repo is Laravel or Symfony.

The two published images are reference points and the common cases, not an attempt at a matrix.

## Per-worktree setup

Cyrus creates a fresh git worktree per issue. A checkout alone is rarely a working app — dependencies are missing, and so is a database. `config.global_setup_script` runs on each new worktree; point it at a script mounted through the chart's `scripts` value.

The pattern that keeps this fast is a **seed database built once and copied thereafter**:

```yaml
scripts:
  worktree-setup.sh: |
    #!/usr/bin/env bash
    set -euo pipefail
    SEED="${CYRUS_HOME}/seed/database.sqlite"

    composer install --no-interaction --no-progress
    [ -f .env ] || { cp .env.example .env; php artisan key:generate --force; }

    if [ -f "$SEED" ]; then
      cp "$SEED" database/database.sqlite          # seconds
    else
      : > database/database.sqlite
      php artisan migrate --seed --force           # minutes, once
      mkdir -p "$(dirname "$SEED")"
      cp database/database.sqlite "$SEED"
    fi

    npm ci --ignore-scripts && npm run build

config:
  global_setup_script: /home/cyrus/.cyrus/scripts/worktree-setup.sh
```

The composer and npm caches also live on the volume, so the second worktree onwards installs from cache.

## Security

Read [SECURITY.md](SECURITY.md) before running this on anything that matters. The short version:

The pod executes model-generated shell commands, driven by Linear issue text that anyone in your workspace can write. Those commands inherit the process environment, which holds your model token and your git token. **Signing the image does not help with that** — the control that works is egress, not process isolation. SECURITY.md covers the allowlist-proxy and LLM-gateway patterns that do help.

Chart defaults:

- **No ServiceAccount token** (`automountServiceAccountToken: false`), and no Role or RoleBinding. Cyrus never talks to the Kubernetes API.
- **NetworkPolicy** allowing public egress on 80/443/22 plus DNS, while denying RFC1918 and `169.254.0.0/16` — so a stray command reaches neither the API server, nor a neighbouring pod, nor the cloud metadata endpoint. Requires a CNI that enforces policy; verify yours does. This is *not* sufficient against deliberate exfiltration; see SECURITY.md.
- **Read-only root filesystem**, non-root uid 1000, all capabilities dropped, `RuntimeDefault` seccomp. Every write goes to the volume or the `/tmp` emptyDir.
- **Ingress publishes only the webhook paths.** The same port also serves `/api/update/*` (which rewrites config and env), `/mcp/cyrus-tools`, `/approval` and `/callback`. Those fail closed without a configured API key, but the internet has no business reaching them.

Two things the chart cannot do for you:

- **Scope the git token.** Give it access to the repositories Cyrus works on and nothing else. A token that can push to every repo in the org is a token the agent can push to every repo in the org.
- **Constrain the tools.** `allowedTools` in `config` decides what the agent may run. `"safe"` excludes Bash entirely, which also excludes running the test suite; a scoped list is the usable middle ground:

  ```yaml
  allowedTools:
    - Read
    - Edit
    - Write
    - Glob
    - Grep
    - Task
    - TodoWrite
    - Bash(git:*)
    - Bash(gh:*)
    - Bash(composer:*)
    - Bash(php:*)
    - Bash(npm:*)
  ```

## Values

| Key | Default | Notes |
|---|---|---|
| `llm.mode` | `apiKey` | `subscription` \| `apiKey` \| `gateway` — where the model credential lives |
| `litellm.enabled` | `false` | deploy the bundled LLM gateway |
| `cyrus.version` | `0.2.67` | npm version installed at start |
| `cyrus.integrity` | pinned | SRI hash of the tarball; install refuses on mismatch |
| `cyrus.baseUrl` | — | **required**; Linear posts to `${baseUrl}/linear-webhook` |
| `cyrus.worktreeMaxAgeDays` | `7` | pruned on pod start; `0` disables |
| `toolchains` | `[]` | mise toolchains installed into the volume, e.g. `python@3.13` |
| `repositories` | `{}` | `name: https clone URL` |
| `ingress.paths` | webhooks only | do not widen to `/` without reading SECURITY.md |
| `config` | `{}` | rendered verbatim to `~/.cyrus/config.json` |
| `scripts` | `{}` | mounted to `~/.cyrus/scripts/`, made executable |
| `secrets.existingSecret` | `""` | mounted with `envFrom` |
| `persistence.size` | `40Gi` | repos + one worktree per issue + caches |
| `networkPolicy.enabled` | `true` | see Security |
| `ingress.*` | disabled | standard chart ingress block |

Full list with comments in [chart/cyrus/values.yaml](chart/cyrus/values.yaml).

## Gotcha worth knowing

Cyrus binds to `localhost` unless `CYRUS_HOST_EXTERNAL=true`
([`WorkerService.ts`](https://github.com/cyrusagents/cyrus/blob/main/apps/cli/src/services/WorkerService.ts): `isExternalHost ? "0.0.0.0" : "localhost"`).
In a pod that means the Service, the Ingress and the kubelet's probes all fail while the logs cheerfully say
`Edge worker started successfully`. The chart and image both set it, and CI asserts the rendered manifest still
does — but if you write your own manifests, this is the one that will cost you an afternoon.

That flag has a second effect worth knowing: it also switches **webhook source-IP validation on**
(`ipValidationEnabled = env === "true" || (env !== "false" && isExternalHost)`), which checks the caller against
each provider's published ranges. Behind an Ingress the pod sees the controller's address rather than Linear's —
but Cyrus builds Fastify with `trustProxy: true` and reads `request.ip`, so the real client IP comes from
`X-Forwarded-For`, which Traefik and ingress-nginx set by default. It works; verify your ingress sets the header
before assuming it. `cyrus.webhookIpValidation: "false"` is the escape hatch, and fixing the header
(`externalTrafficPolicy: Local`, or PROXY protocol) is the better fix. Since `trustProxy: true` trusts the
leftmost XFF entry, treat this as defence in depth behind the webhook signature, not as authentication.

## Upstream's own sandbox

Cyrus ships an egress-filtering sandbox of its own (`sandbox.enabled`, with a `networkPolicy.preset: "trusted"`
allowlist of 201 domains and per-domain header injection). On Linux it prechecks for `socat`, `bubblewrap` and
unprivileged user namespaces. Both binaries are in these images so the precheck can pass.

**It is not verified under this chart's pod security context.** `bubblewrap` wants unprivileged user namespaces,
and `allowPrivilegeEscalation: false` plus `RuntimeDefault` seccomp plus a read-only root filesystem is exactly
the posture where it tends not to get them. If you enable it, expect to relax something, and treat the chart's
NetworkPolicy as the control that actually holds until you have proven otherwise.

Its filesystem rules are also worth checking against your setup script: sessions run with `denyRead: ["~/"]`, and
this chart puts both the setup scripts (`~/.cyrus/scripts/`) and the seed database (`~/.cyrus/seed/`) inside that
denied home directory. Setup scripts appear to run outside the session sandbox, but confirm rather than assume.

## Known limits

- **One replica.** Worktrees are local state on a ReadWriteOnce volume, and two replicas would both answer the same webhook. Scale by giving the agent a bigger node, not more pods.
- **`config.json` is re-seeded on every start.** The ConfigMap is the source of truth, so anything `cyrus-config-updater` writes at runtime is lost on restart. That is the right trade for GitOps and the wrong one if you expect to edit config from the Cyrus UI.
- **amd64 only.** The `-php` image builds against packages.sury.org; an arm64 build under QEMU is slow and currently has no consumer. PRs welcome.
- **Worktree pruning happens at startup**, not on a schedule, because a CronJob would need to mount the same RWO volume.
- **Concurrency is unbounded.** Cyrus starts a session per delegated issue and runs them in parallel, with no documented cap. Size the pod for your delegation rate, not for one session, and do not assume one pod equals one seat.

## Support policy

**Tested against `cyrus-ai` 0.2.67. The chart pins a version and does not track `main`.**

Upstream ships roughly weekly and renames things while doing it — `self-auth` → `self-auth-linear`, `ALLOWED_TOOLS` → `LINEAR_ALLOWED_TOOLS`, `defaultAllowedTools` → `linearAllowedTools`. A `cyrus.version` bump is a values change you make deliberately, after reading their changelog. If this README has drifted from the version you are pinning, the README is the stale part, not the chart.

Known drift not yet reflected here: per-repo `cyrus-setup.sh` / `cyrus-teardown.sh` hooks (now more idiomatic than the chart's `global_setup_script` for repo-specific setup), `CYRUS_REPOS_DIR` / `CYRUS_WORKTREES_DIR` as a cleaner alternative to hardcoded paths in `config`, `CYRUS_ENABLE_WARM_SESSIONS`, and the GitHub/GitLab/Slack transports — the chart publishes their webhook paths but only Linear is documented.

## Licence

Apache 2.0 — see [LICENSE](LICENSE) and [NOTICE](NOTICE).

Cyrus itself is Apache 2.0 and belongs to its authors. `@anthropic-ai/claude-agent-sdk`, pulled in at runtime, is governed by Anthropic's Commercial Terms of Service. Nothing here is legal advice; if redistribution rights matter to your deployment, read both for yourself.
