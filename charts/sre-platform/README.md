# sre-platform

Helm chart for [SRE Platform](https://github.com/chrisleekr/sre-platform), an interactive incident investigation workspace.

The chart runs one versioned, digest-pinned image as four Deployments: API, dashboard, triage worker, and surface worker. A separate Helm hook Job applies database migrations before install and upgrade. An optional second hook Job registers the staff OIDC provider and initial platform administrators without creating an organisation or membership.

## Prerequisites

- Kubernetes with a Gateway API implementation, and a Gateway whose listeners carry the API and dashboard hosts, if this chart should create the public routes. HTTPRoute is `gateway.networking.k8s.io/v1`; a ListenerSet parent needs Gateway API v1.5.0 or later.
- PostgreSQL with the `vector` extension available. The migration account must be able to create the extension, create or alter the `app_user` login role, grant schema privileges, and apply row-level-security policy changes.
- A separate runtime DSN for `app_user`. The API and workers reject a superuser or `BYPASSRLS` runtime role.
- Valkey or Redis reachable from the workloads.
- A text-embeddings-inference compatible endpoint returning 1024-dimensional vectors.
- An OpenID Connect application for staff sign-in, configured by bootstrap below.
- A pre-existing Kubernetes Secret described below.

PostgreSQL, Valkey, embeddings, the identity provider, and their lifecycle remain operator-owned. The chart does not install or upgrade them.

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
| `SECRETS_MASTER_KEY` | API, workers, confidential bootstrap | Base64-encoded 32-byte AES key |
| `BOOTSTRAP_STAFF_CLIENT_SECRET` | Confidential bootstrap | Staff OIDC client secret, required for `client_secret_post` or `client_secret_basic` |

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

route:
  api:
    enabled: true
    parentRefs:
      - group: gateway.networking.k8s.io
        kind: Gateway
        name: public
        namespace: gateway-system
        sectionName: https
    hostnames: [api.sre.example.com]
  dashboard:
    enabled: true
    parentRefs:
      - group: gateway.networking.k8s.io
        kind: Gateway
        name: public
        namespace: gateway-system
        sectionName: https
    hostnames: [sre.example.com]

# Set the trusted right-most forwarded entries only when the edge sanitizes
# incoming forwarding data and the API cannot bypass the trusted proxy chain.
# config:
#   trustedProxyHops: 1
```

For a fresh installation, also enable the staff bootstrap declaration below. Register the exact dashboard `/auth/callback` URL with its OIDC application. The retired global `auth0` values and `AUTH0_*` environment are no longer rendered. Remove that block from downstream values; identity provider configuration lives in the database.

TLS is not a route concern, so `ingress.allowInsecure` and the per-route `tls` blocks are gone; the certificate belongs to the listener each route attaches to, supplied through `extraObjects` or managed outside the chart. The public URLs must still use `https://`, which the chart enforces, and `wss://` is still derived automatically for dashboard WebSockets. Redirecting plaintext HTTP to HTTPS remains gateway or edge policy either way: a listener's certificate says what to serve on 443, not what to do with a port-80 request.

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
    browserClientId: "replace-with-web-client-id"
    clientAuthentication: client_secret_post
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

For this confidential web application example, place `BOOTSTRAP_STAFF_CLIENT_SECRET` and the API's existing `SECRETS_MASTER_KEY` in `existingSecret` before syncing. The bootstrap Job references those keys without embedding their values. Missing keys prevent the Job from starting. Never generate a replacement encryption key for an existing installation.

Match `clientAuthentication` to the directory registration: `client_secret_post`, `client_secret_basic`, or `none` for a public PKCE client. The default is `none`, which requires neither credential key in the bootstrap Job. Register the exact dashboard URL followed by `/auth/callback` in the directory, and enable the standard `openid`, `email`, and `profile` scopes. Staff browser sessions use the provider stored in the database. A custom API audience is optional and is not required for browser sign-in.

The chart then renders a second `pre-install,pre-upgrade` hook Job at weight 1, after the migration Job at weight 0, because it writes to tables the migration creates. It uses the image's `ROLE=bootstrap` entrypoint and the administrative `DATABASE_URL`, and mounts no Kubernetes API token. A failed bootstrap Job fails the whole release, on upgrade as well as install. `bootstrap.activeDeadlineSeconds` bounds a failed attempt and `bootstrap.backoffLimit` bounds its retries; Helm's `--timeout` is a separate outer bound. With `migrations.enabled=false` there is no weight-0 hook, so the schema must already exist before this Job runs.

When bootstrap is enabled, the chart hashes both declarations into the `sre-platform.io/bootstrap-revision` annotation on its ordinary ConfigMap. This does not expose the values or restart a workload. It gives GitOps controllers a non-hook desired-state change, because adding or changing only a hook may not mark an otherwise synced application out of sync and therefore may not start the hook operation.

`issuer` and `subject` are the exact OIDC `iss` and `sub` claims. Read them from the provider rather than guessing. `browserClientId` is the OAuth client identifier; optional `audience` is the legacy API bearer audience. `emailClaim` defaults to `email`; browser sign-in requires the standard email claim and either verified email or mailbox verification. When `jwksUri` is empty, bootstrap discovers it from the issuer. For a new provider it also discovers the authorization and token endpoints even when `jwksUri` is explicit.

Quote identifiers that YAML could coerce, especially numeric- or boolean-looking subjects. A subject entry may carry optional email metadata and grants the platform-operator record immediately. An email-only entry creates a pending invitation; accepting it is a separate application operation. The chart rejects unknown keys, wrong container types, non-string scalar values, empty identities, duplicate subjects, duplicate email-only invitations, and collisions between the two administrator forms before reaching the cluster.

Bootstrap preserves an existing staff provider, except for a one-time discovery backfill of missing browser endpoints. Repeated administrator entries are idempotent. Removing an entry revokes nothing, and a subject removed from the database is granted again on the next upgrade while it remains in the values. An email-only invitation is accepted on a trusted matching sign-in through the installation provider.

Changing Helm values does not change an existing provider's authentication method or rotate a stored client secret. Bootstrap can fill a missing secret only when the stored issuer, client ID, and authentication method match the declaration. An existing public client must be changed through platform administration before switching the declaration to confidential authentication. If no administrator can sign in, arrange an explicit administrative recovery; do not delete the provider or reset the database. Changing Secret contents alone also does not alter the bootstrap-revision annotation, so explicitly sync when a missing credential has been supplied.

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

`config.trustedProxyHops` is the number of trusted right-most forwarded-address entries the API receives. Leave it at `0` when the API is reached directly. Behind a gateway, `0` intentionally treats the gateway socket as the caller, so public-request rate limits are shared by every client behind it. Set a nonzero count only when the edge proxy discards untrusted client-supplied forwarding data, downstream trusted proxies preserve or append the verified chain, and the API cannot be reached around that chain. If the gateway resolves the client and replaces the header with one verified address, use `1` regardless of upstream physical hops.

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
