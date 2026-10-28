# Security

Two separate problems live here. Conflating them is how people end up with a
signed image that leaks their API keys.

1. **Supply chain** — can you trust what this repo ships you?
2. **Credential exposure at runtime** — can the agent be talked into stealing
   your tokens?

The second is the harder one, and it is not solved by signing anything.

## 1. Supply chain

### What we do

| Control | Where |
|---|---|
| Base images pinned by digest, not tag | `Dockerfile` |
| `mise` installed from a pinned release, checksum-verified — not `curl \| sh` | `Dockerfile` |
| `cyrus-ai` tarball verified against a pinned SRI hash before install | `entrypoint.sh`, `cyrus.integrity` |
| Full closure pinned via `npm ci` against a lockfile (opt-in) | `cyrus.lockfileConfigMap` — see caveat below |
| SLSA provenance (`mode=max`) and SBOM attached as attestations | `.github/workflows/image.yaml` |
| Keyless cosign signatures on images and chart | same |
| Trivy gate on fixable HIGH/CRITICAL, **before** the image is pushed | same |
| Rendered-chart invariants asserted in CI | same |
| No Cyrus or Anthropic code baked into published images | by design |

### Verifying before you run it

```bash
cosign verify ghcr.io/mixxor/cyrus-agent-k8s:v0.1.0 \
  --certificate-identity-regexp '^https://github.com/mixxor/cyrus-agent-k8s/' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com

# SBOM and provenance are BuildKit in-toto attestation manifests in the OCI
# index — NOT cosign-attached artifacts. `cosign download sbom` and
# `cosign verify-attestation` look for cosign-written attestations and will
# report nothing found. Read them with buildx instead:
docker buildx imagetools inspect ghcr.io/mixxor/cyrus-agent-k8s:v0.1.0 \
  --format '{{ json .SBOM }}'
docker buildx imagetools inspect ghcr.io/mixxor/cyrus-agent-k8s:v0.1.0 \
  --format '{{ json .Provenance }}'
```

`cosign verify` covers the image index itself, which is what the tag resolves
to. The attestations are unsigned BuildKit artifacts riding in the same index —
they describe the build, and they are covered by the index digest, but they are
not independently cosign-signed.

Enforce it at admission with Kyverno or the sigstore policy-controller rather
than trusting yourself to run the above.

### Pinning `cyrus-ai` — and the closure under it

`cyrus.version` pins a *name*. `cyrus.integrity` pins the *bytes of one tarball*:

```bash
npm view cyrus-ai@0.2.67 dist.integrity
```

The entrypoint compares that hash against the registry's advertised integrity
**and** against the tarball it actually downloaded, refusing to install on any
mismatch.

**Be clear about what that does not cover.** `cyrus-ai` declares 17 direct
dependencies, 11 of them caret ranges, and installing it resolves ~278 packages
by semver at container start. That closure contains executables, not just
JavaScript: `@openai/codex-linux-x64`'s `codex`, `cloudflared`,
`@cursor/sdk-linux-x64`'s `cursorsandbox` and `rg`. Pinning the top tarball
while everything beneath it floats is the same error as signing an image and
declaring the supply chain handled — a strong control aimed at the wrong layer.

Set `cyrus.lockfileConfigMap` to close most of it. `npm ci` against a committed
lockfile resolves no npm package at runtime: the lockfile carries **277 locked
entries**, of which **249 materialise** on linux/amd64 (the rest are non-matching
platform variants).

**One named binary is still not pinned, and it is worth saying out loud.**
`cloudflared` is the only `hasInstallScript: true` entry in that lockfile, and
its postinstall is `node lib/cloudflared.js bin install latest` — a fetch of a
*floating* tag from GitHub releases at container start. Verified in a running
container: a 39 MB `cloudflared` whose version tracks whatever is current, not
anything the lockfile records. The Codex CLI, `cursorsandbox` and `rg` **are**
lockfile-pinned npm payloads; `cloudflared` is not.

If you do not use Cyrus's Cloudflare tunnel, that download is pure attack
surface. There is no chart switch for it yet; the options are to accept it, or
to build a derived image that runs the install with `--ignore-scripts` and
forgoes the tunnel.

A related latent break: these images ship npm 11, which only warns about
install scripts. npm 12 blocks them by default — when the Node base image bumps,
that postinstall silently stops running and `cloudflared` disappears.

```bash
mkdir /tmp/lock && cd /tmp/lock
echo '{"name":"cyrus-runtime","version":"1.0.0","private":true,
       "dependencies":{"cyrus-ai":"0.2.67"}}' > package.json
npm install --package-lock-only
kubectl create configmap cyrus-lockfile --from-file=package-lock.json
```

Regenerate it whenever you bump `cyrus.version`. A mismatch does not install the
wrong version silently — `npm ci` refuses (`lock file's
@openai/codex-linux-x64@0.144.6 does not satisfy …@0.137.0`) and the pod
CrashLoopBackOffs. It validates before deleting `node_modules`, so the previous
install survives and rolling `cyrus.version` back recovers cleanly.

Without a lockfile the entrypoint warns on every install, so the weaker posture
is never silent.

The tradeoff of runtime installation is explicit: you depend on npm being
reachable and honest at pod start. The integrity pin is what makes that
acceptable. If your threat model rules out runtime fetches entirely, build a
derived image with `cyrus-ai` baked in and keep it in your own registry — that is
your redistribution decision to make, not ours.

## 2. Credential exposure at runtime

**This is the part that matters, and it needs stating plainly.**

Cyrus runs a coding agent that executes model-generated shell commands. Those
commands run as child processes of the Cyrus process, so they inherit its
environment — including `CLAUDE_CODE_OAUTH_TOKEN`, `ANTHROPIC_API_KEY`,
`GITHUB_TOKEN`, and the Linear credentials.

The input driving that agent is a Linear issue title, description and comment
thread, plus whatever is in the repository it checks out. All of that is
attacker-influenced in any organisation where more than one person can file an
issue.

So: **assume anything in the pod's environment is readable by anyone who can get
text in front of the agent.** `allowedTools` narrows the shell but does not close
it — `Bash(php:*)` runs `php -r 'echo getenv("GITHUB_TOKEN");'` just as well as
`printenv` would. Mounting secrets as files instead of env vars moves the problem
without solving it: the process needs the value, and the agent runs inside the
process.

The control that actually works is **the network**, not the process. A token that
cannot leave the cluster is a token that cannot be sold.

### Layered mitigations, strongest first

**Egress allowlist.** The chart's default NetworkPolicy blocks RFC1918 and the
metadata endpoint but permits general egress on 80/443/22 — enough to reach
Anthropic, Linear and GitHub, and equally enough to POST a token to a pastebin.
For anything sensitive, replace it: deny direct egress and force traffic through
a proxy that allowlists `api.anthropic.com`, `api.linear.app`, `github.com`,
`registry.npmjs.org` and your own hosts.

```yaml
networkPolicy:
  publicEgress:
    enabled: false          # remove the 0.0.0.0/0 rule entirely
  extraEgress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: egress-proxy
      ports:
        - port: 3128
          protocol: TCP
cyrus:
  extraEnv:
    # Upstream reads PROXY_URL. HTTP_PROXY/HTTPS_PROXY are NOT enough on their
    # own: Node's fetch/undici ignores them, so Cyrus's own API calls would go
    # direct while only curl/git/npm subprocesses honoured the proxy.
    PROXY_URL: http://squid.egress-proxy.svc.cluster.local:3128
    HTTPS_PROXY: http://squid.egress-proxy.svc.cluster.local:3128
    HTTP_PROXY: http://squid.egress-proxy.svc.cluster.local:3128
    NO_PROXY: localhost,127.0.0.1
```

> **Do not do this by emptying `blockedCIDRs`.** That deletes the `except:`
> list from the `0.0.0.0/0` rule and makes the policy strictly *more*
> permissive — RFC1918 and the metadata endpoint become reachable on 80/443/22.
> `publicEgress.enabled: false` is the switch that removes the rule.

Cyrus additionally has a built-in `sandbox` config — egress filtering with
domain allow/deny rules and TLS interception, applied inside the agent process.
Use both; they fail differently.

**Keep the real model key out of the pod.** Set `llm.mode: gateway` and either
enable the bundled LiteLLM dependency or point `llm.gateway.baseUrl` at one you
already run. The gateway holds the real Anthropic credential; the pod holds a
virtual key. A stolen virtual key works only from inside your cluster, and you
revoke it without touching the real one. This is the single highest-value change
if you run Cyrus on repos that matter. Keep the real key out of
`secrets.existingSecret` too: `envFrom` injects every key, so in gateway mode
the entrypoint refuses to start if `ANTHROPIC_API_KEY` or
`CLAUDE_CODE_OAUTH_TOKEN` is present.

Two things to be clear about:

- **Passthrough is not custody.** LiteLLM's `forward_client_headers_to_llm_api`
  forwards a Claude Max OAuth token from the client to Anthropic. The token still
  lives in the pod. You get cost attribution and guardrails; you do not get the
  credential out of reach. Gateway custody of a *subscription* token is community
  territory with a known upstream issue
  ([BerriAI/litellm#29190](https://github.com/BerriAI/litellm/issues/29190)) —
  use an API key at the gateway if custody is the goal.
- **"One pod, so one seat" does not quite hold.** Cyrus creates a worktree and an
  agent session per delegated issue and runs them concurrently, up to
  `config.maxConcurrentSessions` (3 by default in this chart). So a single pod is
  not equivalent to a single person using Claude Code — it is one process driving
  N concurrent sessions. That matters both for how you size the pod
  and for whether a per-seat subscription is the honest licence for it. Not legal
  advice; just do not reason from "it is only one pod".

**Short-lived git credentials.** Prefer a GitHub App installation token (1 hour,
per-repository) over a long-lived PAT. If it must be a PAT, make it fine-grained,
single-repository, `Contents` + `Pull requests` write only. The token's reach is
the blast radius — a token that can push to every repo in the org is a token the
agent can push to every repo in the org.

**Narrow `allowedTools`.** `"safe"` excludes Bash entirely, which also excludes
running tests, so most people need a scoped list instead. Scope it to the
commands the repo's workflow genuinely needs and no more.

**Do not co-locate with production secrets.** Run this in a namespace, and
ideally a cluster, that holds nothing you would mind the agent reading. The
default `automountServiceAccountToken: false` plus the NetworkPolicy assume you
did not give it a reason to look.

### What the chart does by default

- `automountServiceAccountToken: false`, no Role, no RoleBinding
- NetworkPolicy denying RFC1918 and `169.254.0.0/16`
- `readOnlyRootFilesystem: true`, non-root uid 1000, all capabilities dropped,
  `RuntimeDefault` seccomp
- Ingress publishes only the webhook paths — not `/api/update/*` (which rewrites
  config and env), not `/mcp/cyrus-tools`, not `/approval` or `/callback`

Those `/api/update/*` routes verify a Bearer token and **fail closed** when no
API key is configured (`verifyAuth` returns false on a missing key), so they are
not an open door upstream. They are simply not something the internet needs.

## Reporting

Security issues in *this packaging* — the chart, image or entrypoint: open a
GitHub security advisory on this repository.

Security issues in Cyrus itself: report to
[cyrusagents/cyrus](https://github.com/cyrusagents/cyrus), not here.
