# sre-platform

Helm chart for [SRE Platform](https://github.com/chrisleekr/sre-platform), an interactive incident investigation workspace.

The chart runs one versioned, digest-pinned image as four Deployments: API, dashboard, triage worker, and surface worker. A separate Helm hook Job applies database migrations before install and upgrade. An optional second hook Job registers the staff OIDC provider and initial platform administrators without creating an organisation or membership.

## Prerequisites

- Kubernetes with an ingress controller if this chart should create the public routes.
- PostgreSQL with the `vector` extension available. The migration account must be able to create the extension, create or alter the `app_user` login role, grant schema privileges, and apply row-level-security policy changes.
- A separate runtime DSN for `app_user`. The API and workers reject a superuser or `BYPASSRLS` runtime role.
- Valkey or Redis reachable from the workloads.
- A text-embeddings-inference compatible endpoint returning 1024-dimensional vectors.
- An Auth0 custom API and Single Page Application.
- A pre-existing Kubernetes Secret described below.

PostgreSQL, Valkey, embeddings, Auth0, and their lifecycle remain operator-owned. The chart does not install or upgrade them.

The cluster CNI must enforce Kubernetes NetworkPolicy. The chart restricts API
and triage-worker egress to public addresses while excluding private,
link-local, CGNAT, and metadata address space. Whether pod-localhost and
resident-node traffic are also filtered is left to the CNI and varies between
implementations, so this policy reduces SSRF exposure but is not a complete
DNS-rebinding boundary. Cilium filters both, so under Cilium a Pod cannot reach
a component on its own node either. Deployments that
require that boundary must add tested application address pinning, an egress
proxy, or node-level controls. Add narrow `networkPolicy.privateEgress` rules
for private PostgreSQL, Valkey, embeddings, and connector endpoints. If a
cluster-level policy already supplies the required boundary, set
`networkPolicy.enabled=false` and
`networkPolicy.acknowledgeExternalPolicy=true` explicitly.

## Secret contract

Create the Secret before installing the chart. It must contain:

| Key | Consumer | Purpose |
| --- | --- | --- |
| `DATABASE_URL` | API, workers, migration, bootstrap | Owner/control-plane PostgreSQL DSN |
| `APP_DATABASE_URL` | API, workers | Restricted `app_user` PostgreSQL DSN |
| `APP_DB_PASSWORD` | Migration | Password applied to the `app_user` role |
| `VALKEY_URL` | API, workers | Valkey or Redis connection URL |
| `SECRETS_MASTER_KEY` | API, workers | Base64-encoded 32-byte AES key |

For an environment-only bootstrap before Platform Settings is configured, the
same Secret may also contain `ANTHROPIC_API_KEY`, `CLAUDE_CODE_OAUTH_TOKEN`, or
`OPENAI_API_KEY`. They are optional and are exposed only to the API and triage
worker so runtime reporting and execution agree. Model names and turn limits
are non-secret values under `llm`.

The password inside `APP_DATABASE_URL` must equal `APP_DB_PASSWORD`. A Secret can be created from a protected values source or secret controller. For a direct installation:

```sh
kubectl create namespace sre-platform

kubectl -n sre-platform create secret generic sre-platform-runtime \
  --from-literal=DATABASE_URL="$SRE_DATABASE_URL" \
  --from-literal=APP_DATABASE_URL="$SRE_APP_DATABASE_URL" \
  --from-literal=APP_DB_PASSWORD="$SRE_APP_DB_PASSWORD" \
  --from-literal=VALKEY_URL="$SRE_VALKEY_URL" \
  --from-literal=SECRETS_MASTER_KEY="$SRE_SECRETS_MASTER_KEY"
```

Generate the master key once and retain it across upgrades:

```sh
openssl rand -base64 32
```

Rotating `SECRETS_MASTER_KEY` makes previously stored connector and model credentials unreadable. Helm never reads, creates, displays, or rotates the runtime Secret. Because its content is outside the release, restart the API and worker Deployments after rotating one of its keys.

## Configure public origins

The dashboard and API need separate origins because both own root paths. A minimal values file is:

```yaml
existingSecret: sre-platform-runtime

public:
  dashboardUrl: https://sre.example.com
  apiUrl: https://api.sre.example.com
  # Optional. Shown when registration is closed or a workspace needs help.
  supportUrl: https://support.example.com/sre-platform
  # Optional, but these two values must be configured together.
  termsUrl: https://www.example.com/legal/terms
  termsVersion: "2026-09-05"

auth0:
  issuer: https://tenant.example.auth0.com/
  audience: https://api.sre.example.com/
  domain: tenant.example.auth0.com
  clientId: replace-with-public-spa-client-id

embeddings:
  url: http://embeddings.ai.svc.cluster.local:8080

networkPolicy:
  privateEgress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ai
          podSelector:
            matchLabels:
              app.kubernetes.io/name: embeddings
      ports:
        - protocol: TCP
          port: 8080

ingress:
  api:
    enabled: true
    className: nginx
    host: api.sre.example.com
    tls:
      - secretName: api-sre-example-tls
        hosts: [api.sre.example.com]
  dashboard:
    enabled: true
    className: nginx
    host: sre.example.com
    tls:
      - secretName: sre-example-tls
        hosts: [sre.example.com]

# Set the trusted right-most forwarded entries only when the edge sanitizes
# incoming forwarding data and the API cannot bypass the trusted proxy chain.
# config:
#   trustedProxyHops: 1
```

Add the dashboard origin to the Auth0 SPA's callback, logout, and web-origin allowlists. Use the same `auth0.audience` as the custom API identifier.

If TLS terminates before the Kubernetes ingress, set `ingress.allowInsecure=true`. That acknowledges the ingress objects have no local TLS section; the public URLs must still use `https://` and `wss://` is derived automatically for dashboard WebSockets.

## Install and upgrade

```sh
helm repo add chrisleekr https://chrisleekr.github.io/helm-charts
helm repo update

helm upgrade --install sre-platform chrisleekr/sre-platform \
  --namespace sre-platform \
  --values values.yaml \
  --timeout 10m \
  --wait
```

The migration Job is a `pre-install,pre-upgrade` hook. It uses the image's `ROLE=migrate` entrypoint, does not mount a Kubernetes API token, and must finish before workloads change. `migrations.activeDeadlineSeconds` bounds a failed attempt; Helm's `--timeout` is a separate outer bound.

Set `migrations.enabled=false` only when another deployment system runs the exact image migration before each rollout.

The chart's default image combines `Chart.appVersion` with the
automation-recorded `image.releaseDigest`. To test another image, set
`image.tag` and its matching `image.digest` together; a tag alone is rejected.

A tag that already embeds its digest, `<tag>@sha256:<64 hex>`, is accepted on
its own and rendered unchanged; `image.digest` must then stay empty. Continuous
delivery controllers that follow a mutable tag write this single-key form, so
the deployed reference stays immutable without a second value to keep in step.

## First-run bootstrap

A new deployment needs one staff OIDC provider and at least one platform administrator. Bootstrap creates only those installation-level records. It does not create an organisation or membership, and it does not itself make tenant-scoped API routes available to an identity without a membership.

Set `bootstrap.enabled=true` with the provider's public metadata and initial administrators:

```yaml
bootstrap:
  enabled: true
  staffProvider:
    displayName: Staff sign-in
    issuer: "https://tenant.example.auth0.com/"
    browserClientId: "replace-with-public-spa-client-id"
    audience: "https://api.sre.example.com/"
    emailClaim: email
    # Optional. Omit to use OIDC discovery.
    jwksUri: "https://tenant.example.auth0.com/.well-known/jwks.json"
  platformAdmins:
    # A subject grants operator access immediately.
    - subject: "directory-subject"
      email: "operator@example.com"
    # An email-only entry creates a pending invitation.
    - email: "invited@example.com"
```

The current runtime authenticates staff tokens through the `auth0` values. Set the bootstrap issuer, browser client ID, and audience to the same values as `auth0.issuer`, `auth0.clientId`, and `auth0.audience`. A separate staff provider becomes usable only with an application runtime that reads the installation provider from the database.

The chart then renders a second `pre-install,pre-upgrade` hook Job at weight 1, after the migration Job at weight 0, because it writes to tables the migration creates. It uses the image's `ROLE=bootstrap` entrypoint and the administrative `DATABASE_URL`, and mounts no Kubernetes API token. A failed bootstrap Job fails the whole release, on upgrade as well as install. `bootstrap.activeDeadlineSeconds` bounds a failed attempt and `bootstrap.backoffLimit` bounds its retries; Helm's `--timeout` is a separate outer bound. With `migrations.enabled=false` there is no weight-0 hook, so the schema must already exist before this Job runs.

When bootstrap is enabled, the chart hashes both declarations into the `sre-platform.io/bootstrap-revision` annotation on its ordinary ConfigMap. This does not expose the values or restart a workload. It gives GitOps controllers a non-hook desired-state change, because adding or changing only a hook may not mark an otherwise synced application out of sync and therefore may not start the hook operation.

`issuer` and `subject` are the exact OIDC `iss` and `sub` claims. Read them from the provider rather than guessing. `browserClientId` is the public OAuth client identifier; `audience` is the API audience. `emailClaim` defaults to `email`. When `jwksUri` is empty, bootstrap fetches the issuer's OIDC discovery document and requires its issuer to match exactly.

Quote identifiers that YAML could coerce, especially numeric- or boolean-looking subjects. A subject entry may carry optional email metadata and grants the platform-operator record immediately. An email-only entry creates a pending invitation; accepting it is a separate application operation. The chart rejects unknown keys, wrong container types, non-string scalar values, empty identities, duplicate subjects, duplicate email-only invitations, and collisions between the two administrator forms before reaching the cluster.

Bootstrap preserves an existing staff-provider row and performs no discovery or provider update on later runs. Repeated administrator entries are idempotent. Removing an entry revokes nothing, and a subject removed from the database is granted again on the next upgrade while it remains in the values. Provider changes, invitation acceptance, and revocation require explicit administrative operations; bootstrap never edits or revokes existing records.

These fields are public identity metadata, not credentials, so they are ordinary values rather than Secret keys. Anyone who can read the rendered Job can read them. Anyone who can change them can control staff sign-in or grant the highest authorisation tier, so review changes as access-control changes.

## Runtime configuration

The chart supplies deployment-wide fallback settings. After the first login, configure the active investigator runtime, provider, model, credential, turn limit, and custom pricing from Platform Settings. Connector credentials are entered through the product and encrypted with `SECRETS_MASTER_KEY`; they do not belong in Helm values.

In-app notifications require no deployment configuration. To provide an SMTP fallback before an
operator saves a durable setting, set `smtp.enabled=true` with `host`, `port`, `secure`, `from`, and
an optional `username`. Do not put an SMTP password in values or the runtime Secret. A platform
operator enters it in **Settings → Notification email**, where it is encrypted with
`SECRETS_MASTER_KEY`. Leave SMTP disabled when email copies are not required; the durable inbox
continues to work. A private SMTP endpoint also needs a narrow `networkPolicy.privateEgress` rule.

`config.registrationMode` defaults to `approval_required`. Set it to `open` only when any authenticated founder may provision a workspace without platform-administrator approval, or to `closed` when workspace creation must begin with an invitation. `public.supportUrl` gives people a safe next step when registration is closed or workspace access needs help. `public.termsUrl` and `public.termsVersion` are optional, but must be configured together so recorded acceptance identifies the exact terms.

`config.trustedProxyHops` is the number of trusted right-most forwarded-address entries the API receives. Leave it at `0` when the API is reached directly. Behind an ingress, `0` intentionally treats the ingress socket as the caller, so public-request rate limits are shared by every client behind it. Set a nonzero count only when the edge proxy discards untrusted client-supplied forwarding data, downstream trusted proxies preserve or append the verified chain, and the API cannot be reached around that chain. If the ingress resolves the client and replaces the header with one verified address, use `1` regardless of upstream physical hops.

`extraEnv` and `extraEnvFrom` exist for deployment integration such as cloud workload identity variables. They must not replace `ROLE`, `PORT`, the required Secret keys, the public-site values, `REGISTRATION_MODE`, or `TRUST_PROXY_HOPS`. The API renders public-site and security settings as explicit environment variables, so an opaque `extraEnvFrom` source cannot override them; a conflicting `extraEnv` entry fails chart validation.

Private connector access is a network-level privilege. Add the narrowest
`networkPolicy.privateEgress` peer and port for each approved destination. Do
not admit an entire private address range merely to make one connector work.

Name the address the CNI sees. `kube-proxy` rewrites a Service ClusterIP to the
backing endpoint before egress is evaluated, so an `ipBlock` naming a ClusterIP
never matches. Read the real destination from
`kubectl get endpoints <service> -n <namespace>`.

Running a Kubernetes connector against the cluster the platform is deployed into
is the one destination `privateEgress` cannot express under Cilium. Cilium
resolves a node address to a reserved identity, and CIDR selectors do not match
reserved identities unless `policy-cidr-match-mode` includes `nodes`, so no
`ipBlock` reaches the API server. Set `networkPolicy.apiServerEgress.enabled` to
render a CiliumNetworkPolicy that selects the API server by entity instead, with
`port` taken from `kubectl get endpoints kubernetes -n default`. It requires
Cilium and stays off by default.

## Health and scaling

| Component | Health contract |
| --- | --- |
| API | `/healthz` liveness and `/readyz` database readiness on port 3000 |
| Dashboard | `/healthz` on port 8080 |
| Triage worker | Process supervision; no synthetic HTTP probe |
| Surface worker | Process supervision; no synthetic HTTP probe |

Every component defaults to one replica and has independent resources. Increase replica counts only after verifying the connected provider and queue semantics for the deployment.
