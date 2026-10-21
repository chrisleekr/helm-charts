# edge-proxy

Deploys [Edge Proxy](https://github.com/chrisleekr/edge-proxy): the edge, a reverse proxy that enforces policy between your CDN and the load balancer or gateway that routes your services, and admin, which manages that policy. Point your CDN or tunnel at the edge Service and set `config.upstreamURL` to your gateway; the edge forwards every request there with `Host` unchanged and never routes itself. Admin is internal and is never on the request path.

Postgres and Valkey are external by default. `postgres.cnpg.enabled` creates a [CloudNativePG](https://cloudnative-pg.io/docs/1.30/) `Cluster` (the operator must be installed) and `valkey.enabled` adds the project-maintained [Valkey chart](https://github.com/valkey-io/valkey-helm). A fresh install needs no manual step: `bootstrap` generates the Secrets, creates the first admin and publishes a starter policy.

## What it renders

| Object | Purpose |
|---|---|
| ConfigMap `<release>-edge-proxy` | The deployment config (`config.*`), loaded by both edge and admin. Admin validates policy against it, so they must agree |
| Deployment and Service `<release>-edge-proxy-edge` | Port `http` 8080 for traffic, `internal` 9090 for `/livez`, `/readyz` and `/metrics` |
| PodDisruptionBudget `<release>-edge-proxy-edge` | `maxUnavailable: 1` |
| ServiceAccount `<release>-edge-proxy` | Shared by edge and admin. No token is mounted: neither calls the Kubernetes API |
| Deployment and Service `<release>-edge-proxy-admin` | Port `http` 8081, one replica. Init container `migrate` runs `admin migrate` before admin starts; it is idempotent and serialised by an advisory lock |
| Cluster `<release>-edge-proxy-pg` | With `postgres.cnpg.enabled`. Database `edge_admin` owned by `edge_owner`, plus the runtime role `migrations.runtimeRole`. A ScheduledBackup with `postgres.cnpg.scheduledBackup` |
| Valkey Deployment and Service `<release>-valkey` | With `valkey.enabled`. No persistence, `maxmemory 100mb` with `volatile-ttl` eviction, and a NetworkPolicy that admits only the edge pods |
| Job `<release>-edge-proxy-bootstrap`, with its ServiceAccount, Role and RoleBinding | With `bootstrap.generateSecrets`. A `pre-install,pre-upgrade` hook (an Argo CD PreSync hook) that creates the Secrets below when they are missing. Its Role can create Secrets but not read them |
| DaemonSet `<release>-edge-proxy-log-shipper`, with its ConfigMap, ServiceAccount, ClusterRole and ClusterRoleBinding | With `logShipper.enabled` (the default). [Vector](https://vector.dev/docs/reference/configuration/sources/kubernetes_logs/) on the nodes that run edges reads only this release's edge pod logs from a read-only `/var/log/pods` and posts their access lines to admin, which builds **Routes** from them. It runs as root to read the log files, keeps read positions under `logShipper.dataDir` on the node, and its ClusterRole only lists and watches pods and nodes. A namespace that enforces the baseline Pod Security Standard refuses its hostPath mounts |
| `extraObjects` | Rendered through `tpl`, for objects such as a ListenerSet or Certificate |

## Before installing

1. **Postgres.** Either set `postgres.cnpg.enabled`, or create an owner role, a runtime role and a database as in the [install guide](https://github.com/chrisleekr/edge-proxy/blob/main/docs/deploy/index.md).
2. **Secrets.** With `bootstrap.generateSecrets` (the default) the hook creates these when they are missing and never changes an existing one:

   | Secret | Keys |
   |---|---|
   | `<release>-edge-proxy-edge-generated` | `EDGE_SERVICE_TOKEN` |
   | `<release>-edge-proxy-admin-generated` | `ADMIN_PASSWORD`, `AUDIT_HMAC_KEY_ID`, `AUDIT_HMAC_KEY`. Separate from the edge's, so an edge node never receives it |
   | `<release>-edge-proxy-pg-runtime` | With `postgres.cnpg.enabled` and no `runtimeRoleSecret`: the runtime role's `username` and `password` |
   | `<release>-edge-proxy-logs-generated` | With `logShipper.enabled` and no `logShipper.existingSecret`: `LOG_INGEST_TOKEN`, which lets the shipper post access lines to admin and nothing else |

   Helm does not own them, so they survive `helm uninstall`; delete them to start over. Back up `AUDIT_HMAC_KEY`: without it the audit chain cannot be verified.

   Each value below replaces the generated Secret for its component, and is required when `bootstrap.generateSecrets` is `false`:

   | Value | Keys |
   |---|---|
   | `migrations.existingSecret` | `MIGRATION_DATABASE_URL` (owner role). Not used with `postgres.cnpg.enabled`, which reads the operator's `<cluster>-app` Secret |
   | `postgres.cnpg.runtimeRoleSecret` | With `postgres.cnpg.enabled`: a `kubernetes.io/basic-auth` Secret, `username` equal to `migrations.runtimeRole`, labelled `cnpg.io/reload: "true"` |
   | `admin.existingSecret` | `AUDIT_HMAC_KEY_ID`, `AUDIT_HMAC_KEY`, optional `AUDIT_HMAC_PREVIOUS_KEYS`, and `DATABASE_URL` (runtime role) unless `postgres.cnpg.enabled` |
   | `edge.existingSecret` | `EDGE_SERVICE_TOKEN`, optional `INGRESS_SECRET_VALUES`, and optional `VALKEY_URL` unless `valkey.enabled` |
   | `logShipper.existingSecret` | With `logShipper.enabled`: `LOG_INGEST_TOKEN`, at least 32 characters and different from the edge token |

3. **Image tags.** Until Edge Proxy publishes a release, `appVersion` is the `0.0.0` placeholder and the render fails without `edge.image.tag` and `admin.image.tag`.

## Integrations

All off by default.

| Value | Renders |
|---|---|
| `networkPolicy.enabled` | Ingress policies. The edge's `http` port admits only `networkPolicy.edgeFrom` (required: what sends traffic to the edge, such as cloudflared). Without it, any pod inside `config.trustedProxies` could reach the edge and set its own client IP. `internal` admits `metricsFrom`; admin admits the edge pods and `adminFrom` |
| `istio.destinationRule.enabled` | A DestinationRule with `idleTimeout: 60s`, below the edge's `IDLE_TIMEOUT` (75s). Istio's default is 1h, so it reuses connections the edge has closed, and those requests fail with 503 |
| `metrics.serviceMonitor.enabled`, `metrics.prometheusRule.enabled` | Scraping of the edge's `/metrics`, and the alerts from the [monitoring guide](https://github.com/chrisleekr/edge-proxy/blob/main/docs/operate/monitoring.md) scoped to this release's edges. The rules require the ServiceMonitor |
| `route.admin.enabled` | An HTTPRoute to admin, with optional `filters` (see `values.yaml` for the Istio `X-Forwarded-For` filter that sign-in throttling needs) |
| `route.admin.oauth2Proxy.enabled` | An Istio `CUSTOM` AuthorizationPolicy in the gateway's namespace that sends admin's hosts through an ext_authz provider such as oauth2-proxy |

## Availability

- Edge pods spread across zones and then nodes (`ScheduleAnyway`). Set `edge.topologySpreadConstraints` to replace this, or `[]` to turn it off.
- Readiness is `/readyz` and liveness is `/livez`, with no startup probe. A pod waiting for its first policy while admin is down is healthy, so it is kept out of the Service rather than restarted.
- The snapshot cache is an `emptyDir`, so it survives a container restart but not a new pod. For edges that must start while admin is down, mount a bootstrap file with `edge.extraVolumes` and `edge.extraVolumeMounts`, set `BOOTSTRAP_PATH` in `edge.env`, and refresh it well inside `BOOTSTRAP_MAX_AGE` (7 days) using the [export API](https://github.com/chrisleekr/edge-proxy/blob/main/docs/deploy/index.md#where-an-edge-gets-its-policy).
- `GOMEMLIMIT` is set to about 90% of each memory limit; change them together. Admin also sets `GOMAXPROCS: "2"`, which bounds concurrent sign-in hashes (19 MiB each, computed before authentication) under its memory limit.
- The bundled Postgres holds policy history and the audit chain. Configure WAL archiving through `postgres.cnpg.plugins` (the [Barman Cloud plugin](https://cloudnative-pg.io/docs/1.30/backup)) and a `postgres.cnpg.scheduledBackup`.

## First install

With the defaults, admin accepts the edges' `EDGE_SERVICE_TOKEN` without a token being created in the UI. Only while its database is empty, it also:

- creates the user `bootstrap.adminUsername` (`admin`) with `ADMIN_PASSWORD` from the generated Secret;
- publishes the starter policy: no rules, every request forwarded to `config.upstreamURL`, and a per-IP backstop of 100 requests a second (burst 200).

The edges load that policy and become ready. Read the password with the command `NOTES.txt` prints:

```bash
kubectl get secret <release>-edge-proxy-admin-generated -o jsonpath='{.data.ADMIN_PASSWORD}' | base64 -d
```

Changing the password in admin does not update the Secret.

With `bootstrap.generateSecrets: false` the edge token is created in admin, so the edge cannot start until admin runs:

1. Install with `edge.existingSecret` naming a Secret that does not exist yet. Admin starts; edge pods wait in `ContainerCreating`.
2. Create the first admin user: `kubectl exec -i deploy/<release>-edge-proxy-admin -c admin -- /admin create-user <username> admin`, with the password on the first line of stdin. `NOTES.txt` prints the exact command.
3. Sign in, create an edge token and publish a first policy.
4. Create the edge Secret with `EDGE_SERVICE_TOKEN`. The edge pods start and become ready once they load the policy.

## Configuration

| Value | Default | Description |
|---|---|---|
| `config.clientIPSource` | (required) | `cloudfront`, `cloudflare`, `header:<Name>:ip`, `header:<Name>:ip_port`, `xff` or `remote_addr` |
| `config.trustedProxies` | `""` | IPs or CIDRs of the CDN or load balancer in front of the edge. Required unless `remote_addr` |
| `config.upstreamURL` | (required) | `http(s)://host[:port][/path]` of the load balancer or gateway that routes your services. Over https the request's host is the TLS server name |
| `config.viewerHeaders` | `""` | `field=Header,...`; empty uses the client-IP preset |
| `config.ingressSecretHeader` | `""` | Header carrying a CDN-added secret; values go in the edge Secret |
| `config.allowRegex` | `false` | Allows the `matches` operator in rules |
| `edge.replicas` | `2` | Also rendered as `EXPECTED_REPLICAS` |
| `edge.env`, `admin.env` | `GOMEMLIMIT` (and admin `GOMAXPROCS`) | Extra environment variables, for example `MAX_STREAMS`. Maps merge, so the defaults stay |
| `edge.extraVolumes`, `edge.extraVolumeMounts`, `admin.extraVolumes`, `admin.extraVolumeMounts` | `[]` | For a bootstrap file or a password blocklist |
| `edge.topologySpreadConstraints` | `null` (zone and node spread) | `[]` disables |
| `serviceAccount.create`, `.name`, `.annotations` | `true`, release fullname, `{}` | |
| `edge.resources` | requests `50m`/`64Mi`, limit `256Mi` | No CPU limit. Raise the memory limit with `MAX_STREAMS` |
| `admin.trustedProxies` | `""` | `ADMIN_TRUSTED_PROXIES`, admin's own HTTPS proxy |
| `admin.resources` | requests `25m`/`64Mi`, limit `128Mi` | |
| `bootstrap.generateSecrets` | `true` | Generate missing Secrets in a hook Job |
| `bootstrap.adminUsername` | `admin` | First admin, created only while admin has no users |
| `bootstrap.publishStarterPolicy` | `true` | Publish the starter policy while no version exists |
| `bootstrap.image` | `curlimages/curl`, pinned by digest | The hook Job's image; it needs `sh`, `tr`, `head`, `base64` and `curl` |
| `logShipper.enabled` | `true` | Ship edge access lines to admin for **Routes** |
| `logShipper.image` | `timberio/vector`, pinned by digest | The shipper's image |
| `logShipper.nodeSelector`, `logShipper.tolerations` | the edge's | Where the shipper runs; it must run on every node that runs an edge |
| `logShipper.dataDir` | `/var/lib/edge-proxy-log-shipper` | Node directory for read positions; the release's namespace and name are appended |
| `migrations.enabled` | `true` | Run `admin migrate` in an init container before admin starts |
| `migrations.runtimeRole` | `edge_app` | The role admin connects as |
| `postgres.cnpg.enabled` | `false` | Create a CloudNativePG `Cluster`. Admin connects to `<cluster>-rw` with `PGUSER`/`PGPASSWORD` from the runtime role Secret |
| `postgres.cnpg.instances`, `.storage.size`, `.storage.storageClass`, `.imageName` | `1`, `1Gi`, default class, operator default | |
| `postgres.cnpg.plugins`, `.scheduledBackup` | `[]`, `{}` | Passed to `Cluster.spec.plugins` and a `ScheduledBackup` spec |
| `extraObjects` | `[]` | Extra manifests, rendered through `tpl` |
| `valkey.enabled` | `false` | Add Valkey; the edge's `VALKEY_URL` points at it. Other `valkey.*` values go to the [subchart](https://github.com/valkey-io/valkey-helm/tree/main/valkey) |

Every other variable is described in the [edge](https://github.com/chrisleekr/edge-proxy/blob/main/docs/deploy/edge.md) and [admin](https://github.com/chrisleekr/edge-proxy/blob/main/docs/deploy/admin.md) references and can be set through `edge.env` or `admin.env`.
