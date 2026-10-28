# cyrus-agent-k8s

Run [Cyrus](https://github.com/cyrusagents/cyrus), the AI coding agent for Linear, on Kubernetes: a runtime image
and a Helm chart for one stateful worker with git worktrees on a persistent volume behind a webhook.

Upstream ships an npm package for tmux, pm2 or systemd. As far as we know this is the only Kubernetes packaging.

> **Unofficial.** Not affiliated with Cyrus Agents. Packaging issues here, Cyrus issues
> [upstream](https://github.com/cyrusagents/cyrus/issues).
>
> This README, and most of the fixes under "What it handles for you", were written by Claude (Anthropic) in
> Claude Code while wiring Cyrus into a real Laravel monorepo with per-PR preview environments. Every trap listed
> there was hit, not imagined.

## What you get

| | |
|---|---|
| `ghcr.io/mixxor/cyrus-agent-k8s:vX.Y.Z` | node 24, git, gh, mise, Chromium, Debian bookworm |
| `ghcr.io/mixxor/cyrus-agent-k8s:vX.Y.Z-php` | the above plus PHP 8.5 and composer |
| `chart/cyrus` | StatefulSet, PVC, Service, Ingress (webhook paths only), NetworkPolicy, tokenless ServiceAccount |
| `litellm.enabled` | optional bundled LLM gateway, so the model credential stays out of the agent pod |

Images are cosign-signed with SLSA provenance and an SBOM, and contain **no Cyrus and no Anthropic code**: the
Claude Agent SDK is not licensed for redistribution, so the entrypoint installs `cyrus-ai@$CYRUS_VERSION` from npm
at start, into the volume, verified against `cyrus.integrity`. Upgrading Cyrus is a values change and a restart.

## What it handles for you

Each of these looks healthy while doing nothing:

- **Bind address.** Cyrus listens on `localhost` unless `CYRUS_HOST_EXTERNAL=true`. Set, and asserted in CI.
- **Webhook mode.** Upstream defaults to proxy mode (hosted relay, `Bearer $CYRUS_API_KEY`) and answers every
  self-hosted Linear delivery with 401. The chart sets direct mode (`cyrus.linearWebhookMode: direct`): Linear
  signature plus source-IP check. Asserted in CI.
- **Linear token expiry.** Access tokens live 24 h and every refresh rotates the refresh token. Cyrus persists the
  rotated pair; the entrypoint keeps it across restarts as long as the Secret still holds the seeded pair.
- **Supply chain.** `cyrus.integrity` pins the tarball; `cyrus.lockfileConfigMap` pins the ~280-package closure.
  CI fails if `cyrus.integrity` does not belong to `cyrus.version`, so a Renovate bump alone cannot crash-loop the pod.
- **Upgrades.** `volumeClaimTemplates` carry only selector labels, so chart or Cyrus version bumps never hit
  "Forbidden: updates to statefulset spec". Asserted in CI.
- **Blocking setup.** Cyrus runs `global_setup_script` through `execSync` with a hard 5-minute limit, freezing the
  whole server meanwhile. Liveness tolerates 7 minutes so the pod is not killed mid-setup.
- **Rollouts killing sessions.** Cyrus does not resume an interrupted session, so any restart loses the work in
  flight. A `preStop` hook waits while `GET /status` reports `busy` (up to `drain.timeoutSeconds`, 45 min) before
  SIGTERM. Webhooks do not get through meanwhile, see "Known limits".
- **OOM taking every session down.** One container holds all sessions, and on cgroup v2 an OOM kills all of it.
  `config.maxConcurrentSessions` (upstream, default here 3) queues the rest; size it to the memory limit.
- **Worktree pruning.** Worktrees in which nothing changed for `cyrus.worktreeMaxAgeDays` are removed at start,
  never with uncommitted changes.

## Quick start

**1. Linear OAuth app** (workspace settings → API → OAuth applications):
- callback URL `http://localhost:3456/callback` (for the bootstrap below)
- webhooks on, URL `https://<your-host>/linear-webhook`
- events: **Agent session events**, **Inbox notifications**, **Issues**

**2. Bootstrap the Linear tokens** once, on a laptop, against a throwaway home:

```bash
B="$(mktemp -d)" && echo '{"repositories":[]}' > "$B/config.json"
LINEAR_CLIENT_ID=... LINEAR_CLIENT_SECRET=... CYRUS_BASE_URL=http://localhost:3456 \
  npx -y cyrus-ai@0.2.73 --cyrus-home "$B" self-auth-linear
jq '.linearWorkspaces' "$B/config.json"   # workspace id, linearToken, linearRefreshToken
```

**3. Secret** (or create it with External Secrets, Sealed Secrets, ...):

```bash
kubectl -n cyrus create secret generic cyrus-secrets \
  --from-literal=CLAUDE_CODE_OAUTH_TOKEN=... \
  --from-literal=LINEAR_CLIENT_ID=... --from-literal=LINEAR_CLIENT_SECRET=... \
  --from-literal=LINEAR_WEBHOOK_SECRET=... \
  --from-literal=LINEAR_OAUTH_TOKEN=... --from-literal=LINEAR_REFRESH_TOKEN=... \
  --from-literal=GITHUB_TOKEN=...
```

`GITHUB_TOKEN`: a fine-grained token for **only** the repositories Cyrus works on, with Contents and Pull requests
write. No Workflows permission.

**4. Values and install:**

```yaml
image:
  tag: v0.1.2-php                 # set it; the chart-version default may not be published
cyrus:
  version: "0.2.73"
  baseUrl: https://cyrus.example.com
  gitAuthorName: Cyrus Agent
  gitAuthorEmail: cyrus-agent@noreply.example.com   # see "Git identity"
secrets:
  existingSecret: cyrus-secrets
repositories:
  my-app: https://github.com/acme/my-app.git
ingress:
  enabled: true
  host: cyrus.example.com
  tls: {enabled: true, secretName: cyrus-tls}
config:
  claudeDefaultModel: claude-opus-5-5
  linearWorkspaces:
    "<workspace-id>":
      linearToken: "${LINEAR_OAUTH_TOKEN}"            # substituted at start, never in the ConfigMap
      linearRefreshToken: "${LINEAR_REFRESH_TOKEN}"
  repositories:
    - id: my-app
      name: my-app
      repositoryPath: /home/cyrus/.cyrus/repos/my-app
      workspaceBaseDir: /home/cyrus/.cyrus/worktrees/my-app
      baseBranch: main
      githubUrl: https://github.com/acme/my-app
      isActive: true
      linearWorkspaceId: "<workspace-id>"
      teamKeys: ["ENG"]
```

```bash
helm install cyrus ./chart/cyrus -n cyrus --create-namespace -f my-values.yaml
```

Then delegate an issue to the Cyrus agent user in Linear, or `@`-mention it.

## Working with it

**Triggering.** Delegation or an `@`-mention starts a session. A reply in the agent thread continues it in the same
worktree and branch; unassigning stops it. Labels pick the prompt (`labelPrompts`) and repository (`routingLabels`),
they do not trigger.

**Rules for the agent → `claudeMd`.** Mounted as the user-level `CLAUDE.md` and loaded by every session. Prefer it to
`config.repositories[].appendInstruction`, which upstream only appends for some session types (not for
`@`-mentions or label-routed issues). Good content: your definition of done, "run targeted tests, CI runs the
suite", where to find preview URLs, the exact shape of the final Linear reply.

**Tool limits → `disallowedTools`.** `allowedTools` does not restrict anything: Cyrus registers a `canUseTool`
callback (for `AskUserQuestion`) that allows every tool not on the list. Deny rules are evaluated first, so hard
stops go into the repository entry:

```yaml
config:
  repositories:
    - id: my-app
      # ...
      disallowedTools:
        - Bash(gh pr merge:*)
        - Bash(gh api:*)
        - Bash(git push --force:*)
        - Bash(git push -f:*)
        - Bash(git push origin main:*)
```

Prefix matches catch accidents, not a determined agent (`bash -c`, scripts). Branch protection on GitHub is the real
lock.

**Worktree setup → `scripts` + `global_setup_script`.** Keep it under a minute: it blocks the whole server and is
killed at 5 minutes. Do the quick part synchronously (dependencies, `.env`, a seed database copied from the volume)
and detach slow steps (`setsid nohup … &`, e.g. `npm ci && npm run build`) with a marker the agent can wait on.

**Browser proof.** For screenshots of changed pages (and `linear_upload_file` to attach them), install
[agent-browser](https://github.com/vercel-labs/agent-browser) on the image's Chromium:

```yaml
toolchains: ["npm:agent-browser@0.40.0"]
cyrus:
  extraEnv:
    CYRUS_BROWSER_USE_ENABLED: "true"
    AGENT_BROWSER_EXECUTABLE_PATH: /usr/bin/chromium
    AGENT_BROWSER_ARGS: --no-sandbox,--disable-dev-shm-usage
    AGENT_BROWSER_SOCKET_DIR: /tmp/agent-browser
    AGENT_BROWSER_ALLOWED_DOMAINS: "*.example.com"
    XDG_DATA_HOME: /home/cyrus/.cyrus/share   # needed up to image v0.1.2
```

**Models.** Aliases (`opus`, `sonnet`) resolve to whatever the bundled Agent SDK knows; with cyrus-ai 0.2.67 `opus`
meant Opus 4.8. Set `claudeDefaultModel` / `claudeDefaultFallbackModel` explicitly. Linear labels `opus`, `sonnet`,
`haiku`, `fable` override per issue.

**Git identity.** Never use `<name>@users.noreply.github.com`: that address belongs to the GitHub user `<name>`
(`cyrus` is taken) and GitHub attributes the commits to them. Use a domain you control.

## Security

The pod runs model-generated shell commands, steered by issue text anyone in your workspace can write, with your
model and git tokens in its environment. The controls that hold are outside the process; read
[SECURITY.md](SECURITY.md).

- no ServiceAccount token, no RBAC; read-only root filesystem, uid 1000, no capabilities, `RuntimeDefault` seccomp
- NetworkPolicy: DNS plus public 80/443/22, RFC1918 and `169.254.0.0/16` denied (needs a CNI that enforces it)
- Ingress publishes only `/linear-webhook`, not `/api/update/*` or `/mcp`
- `llm.mode: gateway` keeps the real model credential out of the pod (`subscription` and `apiKey` do not); the pod
  refuses to start if `ANTHROPIC_API_KEY` or `CLAUDE_CODE_OAUTH_TOKEN` is in its Secret anyway

## Operations

- **Upgrading Cyrus:** bump `cyrus.version` **and** `cyrus.integrity` (`npm view cyrus-ai@<v> dist.integrity`) in
  one change; regenerate the lockfile if you use one.
- **Pod stuck in CrashLoopBackOff after a fix:** a StatefulSet does not replace a crash-looping pod on its own.
  Delete the pod once.
- **Charts older than the stable `volumeClaimTemplates`:** the first upgrade needs
  `kubectl delete statefulset <name> --cascade=orphan`; the pod and volume stay.
- **Logs to expect:** `integrity verified`, `keeping the Linear tokens Cyrus persisted`,
  `Registered POST /linear-webhook endpoint (direct mode)`.

## Known limits

- One replica (RWO volume, one webhook consumer). Several repositories: one Helm release, Linear app, git token and
  ingress host per repository.
- No webhook receiver during a rollout. The new pod starts only once the old one has drained. Linear retries a
  failed delivery after 1 min, 1 h and 6 h, so anything sent mid-drain arrives up to an hour late. Roll out when
  the agent is idle, or lower `drain.timeoutSeconds`.
- Sessions queued behind `config.maxConcurrentSessions` live in memory, do not count as `busy` for the drain, and
  are lost on restart.
- `config.json` is re-seeded from the ConfigMap on every start; runtime edits are lost (Linear tokens excepted).
- amd64 only. Worktrees are pruned at start, not on a schedule.
- Only the Claude runner and the Linear transport are exercised here. Codex/Cursor/Gemini runners and the
  GitHub/GitLab/Slack transports are untested; upstream's own sandbox does not get user namespaces under this
  pod security context.
- Tested with cyrus-ai 0.2.73. Upstream renames things often; read their changelog before bumping.

## Licence

Apache 2.0, see [LICENSE](LICENSE) and [NOTICE](NOTICE). Cyrus is Apache 2.0 and belongs to its authors;
`@anthropic-ai/claude-agent-sdk`, installed at runtime, is under Anthropic's Commercial Terms of Service.
