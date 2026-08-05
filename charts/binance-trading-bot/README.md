# binance-trading-bot

Helm chart for [chrisleekr/binance-trading-bot](https://github.com/chrisleekr/binance-trading-bot), a self-hosted automated crypto trading bot.

Chart `1.x` targets upstream `v1.0.0`, which rewrote the application. It shares no data model with what chart `0.x` deployed, so there is no upgrade path: install it fresh.

## Install

```sh
helm repo add chrisleekr https://chrisleekr.github.io/helm-charts
helm install btb chrisleekr/binance-trading-bot \
  --set webOrigin=https://bot.example.com
```

`webOrigin` is the only value with no usable default. Upstream's `WEB_ORIGIN` is an exact-origin allowlist with no wildcard support, and it gates CORS, Better Auth CSRF and the WebSocket upgrade. Get it wrong and the app installs cleanly but the dashboard never connects. Leave it empty and the chart takes the first `ingress.hosts` entry; with neither, the render fails rather than guessing.

Binance API keys are not chart configuration. They are stored per account through the dashboard after you log in.

## Topology

`<fullname>` below is `<release>-binance-trading-bot`, or just `<release>` when the release name already contains the chart name. `fullnameOverride` replaces it.

| `topology` | Deployments | Notes |
| --- | --- | --- |
| `all` (default) | `<fullname>-all` | api, live worker and study in one process |
| `split` | `<fullname>-api`, `<fullname>-worker`, `<fullname>-study` | one role per Deployment |

The roles that run the live trading loop are fixed at one replica: `worker` in `split` mode, and `all` in the default mode, which runs the worker in-process. Upstream has no distributed lock, so a second replica places every order twice. Asking for more fails the render with that explanation rather than deploying it. Zero is honoured, not defaulted away: `roles.worker.replicaCount: 0` stops the trading loop while the rest of the release keeps running, which is how you pause without uninstalling. Only values above 1 fail. Scale the read path instead: `topology=split` plus `roles.api.replicaCount`.

In `split` mode the api and the worker mount the same `BACKUP_DIR` claim: the worker writes database dumps, the api lists and serves them. Set `persistence.accessModes` to `ReadWriteMany` and use a storage class that supports it, or the second pod will not schedule.

`persistence.enabled=false` does not unset `BACKUP_DIR`. The mount stays and becomes an `emptyDir`, so dumps still write, they just die with the pod. That keeps the api from 500ing on a directory that does not exist.

## Ports

| Port | Exposure | Serves |
| --- | --- | --- |
| 3000 | primary Service, ingress | API, dashboard, WebSocket, `/healthz` |
| 9100 | none by default | api admin: `/healthz`, `/readyz`, `/metrics` |
| 9101 | none by default | worker admin: same three paths |

The admin ports are unauthenticated, and the chart sets `ADMIN_HOST` and `WORKER_ADMIN_HOST` to `0.0.0.0` because the kubelet cannot probe a listener bound to loopback. Keeping them off the Service hides them from DNS, not from the pod network. Set `networkPolicy.enabled=true` and list the peers allowed to reach them:

```yaml
networkPolicy:
  enabled: true
  adminFrom:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: monitoring
```

`adminFrom` empty means no peer may reach the admin ports at all. Whether kubelet probe traffic is subject to the policy depends on the CNI, so verify probes still pass after enabling it.

The policy selects the application pods only. The bundled Postgres and Valkey are deliberately left unselected, and therefore unisolated: selecting them would require also allowing the migration Job, the api, the worker and the study consumer through, and a mistake there breaks the release instead of the metrics endpoint. Both listen with a password. If you need them isolated too, write a second policy against `app.kubernetes.io/component: postgres` / `valkey`.

The bundled OTel Collector gets its own policy, keyed on `otelCollector.enabled` rather than on `networkPolicy.enabled`: its OTLP receivers accept spans from anyone and it forwards them with your vendor token, so turning the Collector on protects it either way. It admits 4317/4318 from this release's own pods and nothing else.

Enabling `ingress` with an empty `ingress.tls` fails the render. Without a certificate on the rule the dashboard and its session cookie go over cleartext HTTP, and the derived `webOrigin` would be `http://`. If TLS terminates in front of this ingress, set `ingress.allowInsecure=true` to acknowledge it — and set `webOrigin` to the `https://` origin yourself, because the fallback reads the scheme from `ingress.tls` and would still give you `http://`.

## Migrations

The image runs migrations from its entrypoint on every boot, and concurrent pods race on the migrations table. The chart runs them once in a `pre-install,pre-upgrade` hook Job and sets `SKIP_MIGRATIONS=1` on every app workload. Setting `migrations.enabled=false` does not re-enable the entrypoint path: it means you take ownership of running them yourself.

The app ConfigMap and Secret carry the same hook annotations at a lower weight, because plain release resources are applied after `pre-install` hooks and the Job reads both through `envFrom`. Consequence: `helm uninstall` leaves them behind, and a reinstall picks the same credentials back up. For the same ordering reason the Job names no ServiceAccount — the chart's own is a plain release resource that does not exist yet when the hook runs, and a pod naming a missing ServiceAccount is rejected by admission. The Job never calls the Kubernetes API and mounts no token.

`helm install --timeout` defaults to 5m0s and applies to each hook Job, so the whole pre-install chain — image pull, PVC bind, `initdb`, the wait-for-database loop, then the migration — has to fit in 300s. The chart's defaults (`databaseWaitSeconds: 120`, `activeDeadlineSeconds: 240`) sit inside that. On a slow cluster or a distant external database, raise both **and** pass a larger `--timeout`; raising them alone just moves the failure to Helm, which abandons a Job that may still be running and leaves the hook-owned Secret behind.

## Datastores

Bundled by default: a TimescaleDB StatefulSet and a Valkey StatefulSet, both single-replica with their own PVC. TimescaleDB is not optional, the schema depends on it.

The Postgres StatefulSet is a `pre-install,pre-upgrade,pre-rollback` hook so it exists before the migration Job runs, which has three consequences worth knowing before you rely on it:

- `helm upgrade` recreates the StatefulSet rather than patching it, so the database pod restarts. The PVC is retained by `volumeClaimTemplates`, so data survives.
- `helm uninstall` leaves the StatefulSet, its Service and its PVC behind for you to delete.
- `postgres.persistence.size` is fixed at install time. Raising it renders cleanly and does nothing, because the recreated StatefulSet reattaches the existing PVC at its original size instead of raising the usual validation error. Resize the PVC directly.

Run a managed database with `postgres.enabled=false` to avoid all three. Note that `postgres.image` is still used even then: it supplies `pg_isready` for the migration Job's wait-for-database init container.

To use your own, supply a full DSN and switch the bundled one off:

```yaml
postgres:
  enabled: false
externalDatabase:
  url: postgresql://user:pass@pg.example.com:5432/btb?sslmode=require
valkey:
  enabled: false
externalRedis:
  url: redis://:pass@redis.example.com:6379/0
```

`TICK_PERSIST_TIMEOUT_MS` defaults to 300 here rather than upstream's 100. Upstream tuned that number for local SSD; on network-replicated CSI the degraded persist path otherwise becomes the steady state.

## Secrets

`auth.secret` must be at least 32 characters or the app refuses to boot. Leave it empty and the chart generates one, then reads it back from the cluster on every upgrade so sessions survive. That read uses `lookup`, which returns nothing during a server-side diff, so GitOps setups should manage the Secret themselves and point `existingSecret` at it. It must contain `AUTH_SECRET`, `DATABASE_URL`, `REDIS_URL`, plus `POSTGRES_PASSWORD` and `VALKEY_PASSWORD` when the bundled datastores are enabled, plus `OTEL_EXPORTER_OTLP_HEADERS` when `otlp.headers` is set without the bundled collector. `existingSecret` replaces the chart's Secret rather than merging with it, so a key you leave out is not set anywhere — a missing OTLP auth header drops every trace with nothing failing.

## Observability

All off by default; the ServiceMonitor and PrometheusRule need the Prometheus Operator CRDs.

- `metrics.serviceMonitor.enabled` renders a ServiceMonitor and the separate headless admin Service it scrapes. Both admin ports are declared on that Service, and a pod only joins the subset for a port it actually binds, so no role is scraped on a port it does not serve.
- `metrics.prometheusRule.enabled` renders alert rules. Thresholds, `for` durations and severities are values-tunable, and `additionalRules` is appended verbatim for operator-owned rules.
- `otelCollector.enabled` renders an OpenTelemetry Collector with tail sampling and points the app at it. Tail sampling needs a collector because the in-process head sampler decides before a trace finishes and cannot preferentially keep the ones that failed or ran slow.
- `otlp.endpoint` alone exports straight to an external backend. Both unset means no OTEL environment variables are set at all, which is how upstream treats tracing being disabled.

### No alert coverage today

The alert rules upstream ships name several metrics that no code path in `v1.0.0` exports, so those alerts can never fire. This chart omits them rather than shipping alerts that read as permanently healthy, and corrects the Binance request-weight rule to the metric name the image really emits, `binance_api_weight`.

That leaves these failure modes with **no alert coverage** in this chart:

- Trading tick failures and tick throughput collapse.
- Queue backlog growth in BullMQ.
- Database connection pool exhaustion.
- Dropped Binance market-data WebSocket connections.

Watch them through logs and the dashboard until the application exports metrics for them, then add rules through `metrics.prometheusRule.additionalRules`.

## Values

See [values.yaml](values.yaml); every key is documented inline.
