#!/usr/bin/env bash
#
# Render gate for the binance-trading-bot chart.
#
# The chart deploys upstream v1.0.0, which is a full rewrite: one image with
# ROLE=all|api|worker|study, Postgres+TimescaleDB and Redis/Valkey behind it.
# Most of what can go wrong there is invisible to `helm lint` and to a single
# `helm template` run, because the failure mode is a *conditional branch* that
# renders the wrong thing rather than failing to render: probes pointed at a
# loopback-bound admin port, migrations racing across replicas, a Service that
# leaks the unauthenticated /metrics endpoint, an alert rule whose metric the
# image never emits. This gate renders the chart across every branch and asserts
# the specific strings that prove each behaviour.
#
# It is both the start-state proof for the rewrite and the permanent CI gate.
#
# Dependencies: helm and bash/coreutils only. Deliberately no yq / jq / ct, none
# of which are guaranteed in the CI images this runs in.
#
# Run from the repo root:  bash scripts/check-binance-trading-bot-render.sh
#
# ---------------------------------------------------------------------------
# Render matrix (each fixture under ci/ is standalone so `ct` can install it):
#   R1 default       -f ci/ct-values.yaml
#   R2 split         -f ci/split-values.yaml
#   R3 external      -f ci/external-values.yaml
#   R4 ingress+netpol  ct-values + ingress on, webOrigin cleared (derive from host)
#   R5 observability -f ci/observability-values.yaml
#   R6 external OTLP ct-values + otlp.endpoint, no bundled Collector
#   R7 NEGATIVE      ct-values with webOrigin cleared and no ingress -> must FAIL
#   R8 lean          ct-values + persistence off + serviceAccount.create=false
#   R9 NEGATIVE      split + roles.worker.replicaCount=2 -> must FAIL
#   R10 ingress+TLS  R4 with ingress.tls set (the https half of webOrigin)
#   R11 explicit pw  ct-values + postgres.auth.password set
#   R12 NEGATIVE     ct-values + a reserved character in that password -> must FAIL
#   R13 NEGATIVE     ct-values + topology=splitt -> must FAIL
#   R14 NEGATIVE     ingress on, no tls, no allowInsecure -> must FAIL
#   R15 paused       split + roles.worker.replicaCount=0 (0 is honoured, not defaulted)
#   R16 byo secret   ct-values + existingSecret (chart Secret suppressed)
#   R17 no migrate   ct-values + migrations.enabled=false
#
# Resource-name contract asserted below (release "btb", fullname
# "btb-binance-trading-bot"). Workloads are always role-suffixed so the range
# over the role list stays uniform between topologies:
#   Deployment      <fullname>-{all|api|worker|study}
#   Service         <fullname>            (port 3000 only)
#   Service         <fullname>-admin      (metrics scrape target, opt-in)
#   ConfigMap       <fullname>
#   Secret          <fullname>            (AUTH_SECRET, DATABASE_URL, REDIS_URL)
#   Job             <fullname>-migrate    (pre-install,pre-upgrade hook)
#   PVC             <fullname>-backups
#   StatefulSet     <fullname>-postgres / <fullname>-valkey
#   Deployment/Service/ConfigMap  <fullname>-otel-collector
#   Ingress / NetworkPolicy / ServiceMonitor / PrometheusRule   <fullname>
# Probes reference admin ports numerically (9100 api-side, 9101 worker-side).
# ---------------------------------------------------------------------------
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
chart="$repo_root/charts/binance-trading-bot"
release="btb"
fullname="btb-binance-trading-bot"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

passed=0
failed=0
reasons=""

# ---------------------------------------------------------------- reporting --

note() { reasons="${reasons}${reasons:+; }$1"; }

# Close out one criterion. Exactly one PASS/FAIL line per Cn.
check() { # <id> <what>
  if [ -z "$reasons" ]; then
    printf 'PASS %s: %s\n' "$1" "$2"
    passed=$((passed + 1))
  else
    printf 'FAIL %s: %s -- %s\n' "$1" "$2" "$reasons"
    failed=$((failed + 1))
  fi
  reasons=""
}

# ------------------------------------------------------------- sub-assertions -
# Each appends to $reasons when it does not hold. An empty file (failed render)
# always fails a positive assertion rather than passing vacuously.

want() { # <file> <ere> <label>
  if [ ! -s "$1" ]; then
    note "$3: $(basename "$1") is empty"
  elif ! grep -qE "$2" "$1"; then
    note "$3: expected /$2/ in $(basename "$1")"
  fi
}

want_not() { # <file> <ere> <label>
  if [ ! -s "$1" ]; then
    note "$3: $(basename "$1") is empty"
  elif grep -qE "$2" "$1"; then
    note "$3: unexpected /$2/ in $(basename "$1")"
  fi
}

want_count() { # <file> <ere> <n> <label>
  local got
  # An empty file is a failed render, not a legitimate count of 0. Without this
  # a want_count of 0 would pass on a chart that does not render at all.
  if [ ! -s "$1" ]; then
    note "$4: $(basename "$1") is empty"
    return
  fi
  got=$(grep -cE "$2" "$1" 2>/dev/null || true)
  if [ "${got:-0}" != "$3" ]; then
    note "$4: expected $3 lines matching /$2/, found ${got:-0}"
  fi
}

# Absence over the whole chart source tree, not just a render.
want_not_in_tree() { # <dir> <ere> <label>
  local hits
  # A wrong path greps nothing and every absence assertion goes green, which is
  # eight assertions across C15 and C27 passing on a typo.
  if [ ! -d "$1" ]; then
    note "$3: $1 is not a directory"
    return
  fi
  hits=$(grep -rlEi "$2" "$1" 2>/dev/null || true)
  if [ -n "$hits" ]; then
    note "$3: /$2/ still present in $(echo "$hits" | tr '\n' ' ')"
  fi
}

# ------------------------------------------------------------ doc extraction -
# helm emits a multi-document stream. Assertions that must hold for one specific
# resource extract that document first, otherwise a match anywhere in the stream
# would satisfy them.

DOC=""
find_doc() { # <render> <kind> <name>  -> sets DOC, returns 0 when found
  local key
  key=$(printf '%s_%s_%s' "$(basename "$1" .yaml)" "$2" "$3" | tr -c 'A-Za-z0-9' '_')
  DOC="$tmp/doc_$key.yaml"
  : >"$DOC"
  awk -v k="kind: $2" -v n="  name: $3" -v out="$DOC" '
    BEGIN { kre = "(^|\n)" k "(\n|$)"; nre = "(^|\n)" n "(\n|$)" }
    function flush() {
      if (buf ~ kre && buf ~ nre) { printf "%s", buf > out; found = 1 }
      buf = ""
    }
    /^---[[:space:]]*$/ { flush(); next }
    { buf = buf $0 "\n" }
    END { flush(); exit (found ? 0 : 1) }
  ' "$1"
}

get_doc() { # <render> <kind> <name> <label>  -> sets DOC, notes when missing
  if find_doc "$1" "$2" "$3"; then
    return 0
  fi
  note "$4: no $2/$3 in $(basename "$1")"
  return 1
}

want_no_doc() { # <render> <kind> <name> <label>
  if [ ! -s "$1" ]; then
    note "$4: $(basename "$1") is empty"
  elif find_doc "$1" "$2" "$3"; then
    note "$4: unexpected $2/$3 in $(basename "$1")"
  fi
}

# -------------------------------------------------------------- secret values -
# Credentials render base64-encoded into the chart Secret, so string assertions
# on them have to decode first.

secret_value() { # <render> <key>  -> prints decoded value, empty when absent
  local raw
  # Scoped to the Secret document for the reason the header above gives: a key
  # such as DATABASE_URL appearing as a plain `value:` anywhere else in the
  # stream would win the head -1, base64 -d would fail on it, and the value
  # would read as missing.
  find_doc "$1" Secret "$fullname" || return 0
  # BRE and no -E, because busybox sed in the alpine/helm image predates it.
  raw=$(grep -E "^[[:space:]]+$2: " "$DOC" 2>/dev/null | head -1 |
    sed -e "s/^[[:space:]]*$2:[[:space:]]*//" -e 's/"//g' || true)
  [ -n "$raw" ] || return 0
  # base64 -d exists in both coreutils and busybox, so this runs unchanged in
  # the alpine/helm CI image.
  printf '%s' "$raw" | base64 -d 2>/dev/null || true
}

want_secret() { # <render> <key> <ere> <label>
  local v
  v=$(secret_value "$1" "$2")
  if [ -z "$v" ]; then
    note "$4: Secret key $2 missing or empty in $(basename "$1")"
  elif ! printf '%s' "$v" | grep -qE "$3"; then
    # Length, not value. Every value reachable here is a CI fixture today, but
    # this runs in public CI logs and a local run against real values would
    # otherwise print a live DATABASE_URL. The regex is a script literal and is
    # what a reader actually needs to debug.
    note "$4: Secret $2 (${#v} chars) did not match /$3/"
  fi
}

# ------------------------------------------------------------------- renders --

render() { # <name> <helm args...>  -> $tmp/<name>.yaml (emptied on failure)
  local name=$1
  shift
  if ! helm template "$release" "$chart" "$@" >"$tmp/$name.yaml" 2>"$tmp/$name.err"; then
    : >"$tmp/$name.yaml"
    printf 'RENDER FAILED %s: %s\n' "$name" "$(tr '\n' ' ' <"$tmp/$name.err" | cut -c1-300)" >&2
  fi
}

ci="$chart/ci"
render r1 -f "$ci/ct-values.yaml"
render r2 -f "$ci/split-values.yaml"
render r3 -f "$ci/external-values.yaml"
render r4 -f "$ci/ct-values.yaml" \
  --set webOrigin="" \
  --set ingress.enabled=true \
  --set ingress.className=nginx \
  --set 'ingress.hosts[0].host=btb.ci.example.com' \
  --set 'ingress.hosts[0].paths[0].path=/' \
  --set 'ingress.hosts[0].paths[0].pathType=Prefix' \
  --set ingress.allowInsecure=true \
  --set networkPolicy.enabled=true \
  --set-json 'networkPolicy.adminFrom=[{"namespaceSelector":{"matchLabels":{"kubernetes.io/metadata.name":"monitoring"}}}]'
# R10 is R4 with TLS, so the other half of the webOrigin scheme ternary is
# covered. Without it the scheme could be hardcoded and C17 would not notice.
render r10 -f "$ci/ct-values.yaml" \
  --set webOrigin="" \
  --set ingress.enabled=true \
  --set 'ingress.hosts[0].host=btb.ci.example.com' \
  --set 'ingress.hosts[0].paths[0].path=/' \
  --set 'ingress.hosts[0].paths[0].pathType=Prefix' \
  --set 'ingress.tls[0].secretName=btb-tls' \
  --set 'ingress.tls[0].hosts[0]=btb.ci.example.com'
# R5 carries a backend and two headers so the collector's otlphttp exporter, the
# header env-substitution and the headers Secret are all actually rendered.
render r5 -f "$ci/observability-values.yaml" \
  --set otlp.endpoint=https://otlp.vendor.example:4318 \
  --set 'otlp.headers=authorization=Bearer ci-token\,x-tenant=acme'
# R11 renders the explicit-password branch of the DSN, which no fixture reaches.
render r11 -f "$ci/ct-values.yaml" --set postgres.auth.password=safe-pw_1.2
render r6 -f "$ci/ct-values.yaml" \
  --set otlp.endpoint=http://otel-gateway.observability.svc:4318 \
  --set otlp.headers='authorization=Bearer ci-token'
render r8 -f "$ci/ct-values.yaml" \
  --set persistence.enabled=false \
  --set serviceAccount.create=false \
  --set serviceAccount.name=btb-preexisting
# R15 covers the one value where sprig's `default` would be wrong: 0 is a real
# request to stop a role, and `default` treats it as empty and would silently
# put the trading worker back to one replica.
render r15 -f "$ci/split-values.yaml" --set roles.worker.replicaCount=0
# R16 is the GitOps path the README points at, and it is all-or-nothing: the
# chart Secret is suppressed entirely, so a key the operator omits is set
# nowhere. Nothing else renders it, so without this the branch is untested.
render r16 -f "$ci/ct-values.yaml" --set existingSecret=btb-byo-secret
# R17 proves migrations.enabled=false drops the Job without re-enabling the
# entrypoint migration path that the Job exists to replace.
render r17 -f "$ci/ct-values.yaml" --set migrations.enabled=false

# R9 is the second negative render: the roles that run the live trading loop must
# refuse to scale rather than quietly double-trading. Asserting `replicas: 1` in
# R1/R2 only proves the default; this proves the pin is enforced.
if helm template "$release" "$chart" -f "$ci/split-values.yaml" \
  --set roles.worker.replicaCount=2 >"$tmp/r9.yaml" 2>"$tmp/r9.err"; then
  r9_rc=0
else
  r9_rc=$?
fi

# R12 proves the URL-safety guard fires. Without it the guard is untested code
# and the DSN corruption it exists to prevent ships silently.
if helm template "$release" "$chart" -f "$ci/ct-values.yaml" \
  --set 'postgres.auth.password=bad/pw?x' >/dev/null 2>"$tmp/r12.err"; then
  r12_rc=0
else
  r12_rc=$?
fi

# R13 proves the topology guard fires. A typo like "splitt" otherwise falls
# through the ternary in the roles helper and quietly deploys the all-in-one pod
# while the operator believes they asked for three.
if helm template "$release" "$chart" -f "$ci/ct-values.yaml" \
  --set topology=splitt >/dev/null 2>"$tmp/r13.err"; then
  r13_rc=0
else
  r13_rc=$?
fi

# R18-R20 prove the three guards added for the review round fire. Each protects
# against a failure that is silent at install time: a Pending pod the rollout
# calls healthy, a DeadlineExceeded with no diagnostic, and an alert set that
# matches no series.
for case in \
  "r18|--set topology=split" \
  "r19|--set migrations.databaseWaitSeconds=600 --set migrations.activeDeadlineSeconds=300" \
  "r20|--set metrics.prometheusRule.enabled=true --set metrics.serviceMonitor.enabled=false"; do
  nm=${case%%|*}
  # shellcheck disable=SC2086  # the flag string is a script literal, split on purpose.
  if helm template "$release" "$chart" -f "$ci/ct-values.yaml" ${case#*|} \
    >/dev/null 2>"$tmp/$nm.err"; then
    eval "${nm}_rc=0"
  else
    eval "${nm}_rc=\$?"
  fi
done

# R21 renders under a release name long enough to exhaust the 63-character
# budget, which is where every derived name used to collapse onto the same
# string. 50 characters plus "-binance-trading-bot" overruns it.
render_long=$tmp/r21.yaml
helm template a-very-long-release-name-that-eats-the-budget-here \
  "$chart" -f "$ci/ct-values.yaml" >"$render_long" 2>"$tmp/r21.err" ||
  printf 'RENDER FAILED r21: %s\n' "$(tr '\n' ' ' <"$tmp/r21.err" | cut -c1-300)" >&2

# R14 proves the cleartext-ingress guard fires: enabling ingress with no TLS and
# no explicit acknowledgement must not quietly derive an http:// WEB_ORIGIN.
if helm template "$release" "$chart" -f "$ci/ct-values.yaml" \
  --set webOrigin="" --set ingress.enabled=true \
  --set 'ingress.hosts[0].host=btb.ci.example.com' \
  --set 'ingress.hosts[0].paths[0].path=/' \
  --set 'ingress.hosts[0].paths[0].pathType=Prefix' \
  >/dev/null 2>"$tmp/r14.err"; then
  r14_rc=0
else
  r14_rc=$?
fi

# R7 is the negative render: no explicit webOrigin and no ingress to derive one
# from. A chart that emits a broken origin here ships a silently dead WebSocket
# and a silently dead CSRF check, so the render must fail loudly instead.
if helm template "$release" "$chart" -f "$ci/ct-values.yaml" --set webOrigin="" \
  >"$tmp/r7.yaml" 2>"$tmp/r7.err"; then
  r7_rc=0
else
  r7_rc=$?
fi

if helm lint "$chart" -f "$ci/ct-values.yaml" >"$tmp/lint.out" 2>&1; then
  lint_rc=0
else
  lint_rc=$?
fi

# The ConfigMap and Secret carry every env-var criterion (C5, C9, C22), but they
# only reach a pod through envFrom. Without this, deleting that block leaves all
# three criteria green while the pods receive nothing.
#
# The ref kind and the ref name are checked as a pair. Three independent greps
# would pass on a Deployment carrying `- configMapRef:` with the wrong name plus
# an unrelated `name: <fullname>` line elsewhere in the pod spec, which is the
# same coupling gap this script closes for the ServiceMonitor port names.
want_envfrom() { # <render> <deployment-name> <label>
  if get_doc "$1" Deployment "$2" "$3"; then
    for ref in configMapRef secretRef; do
      awk -v ref="- $ref:" -v want="name: $fullname" '
        index($0, ref) { seen = 1; next }
        seen { if (index($0, want)) { ok = 1 } ; seen = 0 }
        END { exit (ok ? 0 : 1) }
      ' "$DOC" || note "$3 envFrom: no $ref naming $fullname"
    done
  fi
}

# Counting probe paths cannot tell the three probes apart: swapping /readyz and
# /healthz between liveness and readiness leaves every count identical, and the
# result is a kubelet that restarts a pod which is merely waiting on Postgres.
# This walks the container spec and pins each path to the probe it sits under.
want_probe_pairing() { # <doc> <label>
  local got
  got=$(awk '
    /^[[:space:]]*(startup|readiness|liveness)Probe:$/ {
      probe = $1; sub(/:$/, "", probe); next
    }
    /^[[:space:]]*path: / && probe != "" { printf "%s=%s ", probe, $2; probe = "" }
  ' "$1")
  if [ "$got" != "startupProbe=/readyz readinessProbe=/readyz livenessProbe=/healthz " ]; then
    note "$2 probes: expected startup+readiness on /readyz and liveness on /healthz, got '$got'"
  fi
}

r1="$tmp/r1.yaml"
r2="$tmp/r2.yaml"
r3="$tmp/r3.yaml"
r4="$tmp/r4.yaml"
r5="$tmp/r5.yaml"
r6="$tmp/r6.yaml"
r8="$tmp/r8.yaml"
r10="$tmp/r10.yaml"
r11="$tmp/r11.yaml"
r15="$tmp/r15.yaml"
r16="$tmp/r16.yaml"
r17="$tmp/r17.yaml"
readme="$chart/README.md"

# ----------------------------------------------------------------- assertions -

# C1 - a bare Pod has no rollout and no rescheduling, so a drained node ends the
# bot with nothing to restart it.
want_not "$r1" '^kind: Pod$' "R1"
want_not "$r2" '^kind: Pod$' "R2"
check C1 "no bare Pod resources remain; every workload is a managed controller"

# C2
if [ "$lint_rc" -ne 0 ]; then
  note "helm lint exited $lint_rc: $(tr '\n' ' ' <"$tmp/lint.out")"
fi
check C2 "helm lint with ci/ct-values.yaml exits 0"

# C3 - default topology is a single all-in-one Deployment.
want_count "$r1" '^kind: Deployment$' 1 "R1"
if get_doc "$r1" Deployment "$fullname-all" "R1"; then
  want "$DOC" '^[[:space:]]*- name: ROLE$' "R1 all"
  want "$DOC" '^[[:space:]]*value: "all"$' "R1 all"
  want "$DOC" '^[[:space:]]*replicas: 1$' "R1 all"
  want "$DOC" '^[[:space:]]*type: Recreate$' "R1 all"
fi
if [ "$r13_rc" -eq 0 ]; then
  note "R13: topology=splitt rendered instead of failing; the guard is cosmetic"
elif ! grep -qi 'topology must be' "$tmp/r13.err"; then
  note "R13: render failed but stderr never names the valid topologies: $(tr '\n' ' ' <"$tmp/r13.err")"
fi
check C3 "default renders exactly one Deployment with ROLE=all, replicas 1, strategy Recreate"

# C4 - split topology fans out to three roles; the worker stays single-replica
# because upstream has no distributed lock for it.
want_count "$r2" '^kind: Deployment$' 3 "R2"
if get_doc "$r2" Deployment "$fullname-api" "R2"; then
  want "$DOC" '^[[:space:]]*value: "api"$' "R2 api"
  # split-values.yaml sets roles.api.replicaCount=2 to exercise the per-role
  # override. Asserting the rendered number is what makes that fixture mean
  # something: without it the override could be ignored and R2 stays green.
  want "$DOC" '^[[:space:]]*replicas: 2$' "R2 api"
fi
# 0 must survive as 0. sprig's `default` treats it as empty, so the obvious
# implementation would round a paused worker back up to a running one, which
# for this role means live orders the operator believed were stopped.
if get_doc "$r15" Deployment "$fullname-worker" "R15"; then
  want "$DOC" '^[[:space:]]*replicas: 0$' "R15 worker"
fi
if get_doc "$r2" Deployment "$fullname-study" "R2"; then
  want "$DOC" '^[[:space:]]*value: "study"$' "R2 study"
fi
if get_doc "$r2" Deployment "$fullname-worker" "R2"; then
  want "$DOC" '^[[:space:]]*value: "worker"$' "R2 worker"
  want "$DOC" '^[[:space:]]*replicas: 1$' "R2 worker"
  want "$DOC" '^[[:space:]]*type: Recreate$' "R2 worker"
fi
if [ "$r9_rc" -eq 0 ]; then
  note "R9: roles.worker.replicaCount=2 rendered instead of failing; the pin is cosmetic"
elif ! grep -qi 'double-trading' "$tmp/r9.err"; then
  note "R9: render failed but stderr never explains double-trading: $(tr '\n' ' ' <"$tmp/r9.err")"
fi
check C4 "topology=split renders api/worker/study; worker pinned to replicas 1 + Recreate and rejects a scale-up"

# C5 - admin servers default to 127.0.0.1 upstream, which the kubelet cannot reach.
want "$r1" '^[[:space:]]*ADMIN_HOST: "?0\.0\.0\.0"?$' "R1"
want "$r1" '^[[:space:]]*WORKER_ADMIN_HOST: "?0\.0\.0\.0"?$' "R1"
want "$r2" '^[[:space:]]*ADMIN_HOST: "?0\.0\.0\.0"?$' "R2"
want "$r2" '^[[:space:]]*WORKER_ADMIN_HOST: "?0\.0\.0\.0"?$' "R2"
# Those keys live in the ConfigMap, which only reaches a pod through envFrom.
want_envfrom "$r1" "$fullname-all" "R1 all"
for role in api worker study; do
  want_envfrom "$r2" "$fullname-$role" "R2 $role"
done
check C5 "ADMIN_HOST and WORKER_ADMIN_HOST are 0.0.0.0 so kubelet probes reach the admin ports"

# C6 - startup + readiness on /readyz, liveness on /healthz, all on the role's
# admin port (9100 api-side, 9101 worker-side), referenced numerically.
if get_doc "$r1" Deployment "$fullname-all" "R1"; then
  want_count "$DOC" '^[[:space:]]*path: /readyz$' 2 "R1 all"
  want_count "$DOC" '^[[:space:]]*path: /healthz$' 1 "R1 all"
  want_count "$DOC" '^[[:space:]]*port: 9100$' 3 "R1 all"
  want_probe_pairing "$DOC" "R1 all"
fi
if get_doc "$r2" Deployment "$fullname-api" "R2"; then
  want_count "$DOC" '^[[:space:]]*port: 9100$' 3 "R2 api"
  want_probe_pairing "$DOC" "R2 api"
fi
if get_doc "$r2" Deployment "$fullname-worker" "R2"; then
  want_count "$DOC" '^[[:space:]]*port: 9101$' 3 "R2 worker"
  want_probe_pairing "$DOC" "R2 worker"
fi
if get_doc "$r2" Deployment "$fullname-study" "R2"; then
  want_count "$DOC" '^[[:space:]]*port: 9101$' 3 "R2 study"
  want_probe_pairing "$DOC" "R2 study"
fi
check C6 "probes target /readyz (startup+readiness) and /healthz (liveness) on the role admin port"

# C7 - the admin ports serve unauthenticated /metrics and /readyz, so the
# primary Service must not carry them.
if get_doc "$r1" Service "$fullname" "R1"; then
  want "$DOC" '^[[:space:]]*port: 3000$' "R1 service"
  want_not "$DOC" '9100' "R1 service"
  want_not "$DOC" '9101' "R1 service"
fi
check C7 "primary Service exposes port 3000 only, never 9100/9101"

# C8
if get_doc "$r4" NetworkPolicy "$fullname" "R4"; then
  want "$DOC" '^[[:space:]]*- Ingress$' "R4 netpol policyTypes"
  want "$DOC" '^[[:space:]]*port: 9100$' "R4 netpol"
  want "$DOC" '^[[:space:]]*port: 9101$' "R4 netpol"
  want "$DOC" '^[[:space:]]*port: 3000$' "R4 netpol"
  want "$DOC" 'kubernetes\.io/metadata\.name: monitoring' "R4 netpol"
  # The 3000 rule must have no `from`, or "stays open" is false: a peer list on
  # that rule would make the port reachable only from the admin sources.
  awk '
    /^[[:space:]]*- from:/ { infrom = 1; next }
    /^[[:space:]]*- ports:/ { infrom = 0; next }
    /port: 3000/ && infrom { bad = 1 }
    END { exit (bad ? 1 : 0) }
  ' "$DOC" || note "R4 netpol: port 3000 sits under a from: peer list, so it is not open to all"
fi
check C8 "networkPolicy.enabled admits the admin ports only from configured sources, port 3000 stays open"

# C9 - migrations run in the image entrypoint and race across replicas, so they
# move to a hook Job and every app pod opts out.
if get_doc "$r1" Job "$fullname-migrate" "R1"; then
  want "$DOC" 'helm\.sh/hook"?:[[:space:]]*pre-install,pre-upgrade' "R1 migrate job"
  want "$DOC" 'migrate\.js' "R1 migrate job"
fi
want "$r1" '^[[:space:]]*SKIP_MIGRATIONS: "?1"?$' "R1"
want "$r2" '^[[:space:]]*SKIP_MIGRATIONS: "?1"?$' "R2"
# "every app workload" means the env actually lands in every pod, not that one
# ConfigMap holds the key.
want_envfrom "$r1" "$fullname-all" "R1 all"
for role in api worker study; do
  want_envfrom "$r2" "$fullname-$role" "R2 $role"
done
# migrations.enabled=false hands the operator ownership of running them; it does
# NOT hand the job back to the image entrypoint. Dropping SKIP_MIGRATIONS here
# would restore exactly the concurrent-boot race the hook exists to remove.
want_no_doc "$r17" Job "$fullname-migrate" "R17"
want "$r17" '^[[:space:]]*SKIP_MIGRATIONS: "?1"?$' "R17"
check C9 "pre-install,pre-upgrade migration Job renders and every app workload sets SKIP_MIGRATIONS=1"

# C10
if get_doc "$r1" Job "$fullname-migrate" "R1"; then
  want "$DOC" '^[[:space:]]*initContainers:$' "R1 migrate job"
  want "$DOC" 'pg_isready' "R1 migrate job"
fi
# The external-database branch is the one that most needs the wait, and it is
# also the one where the init container's image comes from a stanza the
# operator may believe is unused once postgres.enabled is false.
if get_doc "$r3" Job "$fullname-migrate" "R3"; then
  want "$DOC" '^[[:space:]]*initContainers:$' "R3 migrate job"
  want "$DOC" 'pg_isready' "R3 migrate job"
fi
# Both containers carry requests. A LimitRange that requires them rejects the
# pod, and per the template's own note a rejected pod is not a pod failure, so
# backoffLimit never trips and the install hangs to Helm's timeout.
if get_doc "$r1" Job "$fullname-migrate" "R1"; then
  want_count "$DOC" '^[[:space:]]*resources:$' 2 "R1 migrate job"
fi
check C10 "migration Job waits for the database via an init container"

# C11 - TimescaleDB is the schema's persistence layer, not an optional add-on.
if get_doc "$r1" StatefulSet "$fullname-postgres" "R1"; then
  want "$DOC" 'timescale/timescaledb' "R1 postgres"
  want "$DOC" '^[[:space:]]*volumeClaimTemplates:$' "R1 postgres"
  # Without it the kubelet liveness-kills the container partway through initdb
  # plus the TimescaleDB extension setup, and the restart repeats the same work.
  want "$DOC" '^[[:space:]]*startupProbe:$' "R1 postgres"
fi
want_secret "$r1" DATABASE_URL "@$fullname-postgres[.:]" "R1"
# The explicit-password branch of the DSN, which no fixture otherwise reaches.
want_secret "$r11" DATABASE_URL ':safe-pw_1\.2@' "R11"
# ...and the guard that keeps a reserved character from silently relocating it.
if [ "$r12_rc" -eq 0 ]; then
  note "R12: a reserved character in postgres.auth.password rendered instead of failing"
elif ! grep -qi 'percent-encoding' "$tmp/r12.err"; then
  note "R12: render failed but stderr never explains the URL-safety rule: $(tr '\n' ' ' <"$tmp/r12.err")"
fi
check C11 "bundled Postgres renders a TimescaleDB StatefulSet with a PVC and DATABASE_URL targets its Service"

# C12
want_no_doc "$r3" StatefulSet "$fullname-postgres" "R3"
want_secret "$r3" DATABASE_URL 'pg\.ci\.example\.com:5432' "R3"
check C12 "postgres.enabled=false renders no Postgres and uses externalDatabase"

# C13
want_no_doc "$r3" StatefulSet "$fullname-valkey" "R3"
want_secret "$r3" REDIS_URL 'redis\.ci\.example\.com:6379' "R3"
if get_doc "$r1" StatefulSet "$fullname-valkey" "R1"; then
  want "$DOC" '^[[:space:]]*volumeClaimTemplates:$' "R1 valkey"
  # Valkey answers LOADING while it reads an RDB back, so an unguarded liveness
  # probe restarts it partway and the load starts over.
  want "$DOC" '^[[:space:]]*startupProbe:$' "R1 valkey"
  # The snapshot goes to the mounted volume, not the container layer. It is the
  # image WORKDIR that makes that true by default, which nothing else here
  # would notice changing.
  want "$DOC" '^[[:space:]]*- /data$' "R1 valkey"
fi
want_secret "$r1" REDIS_URL "$fullname-valkey[.:]" "R1"
check C13 "valkey.enabled=false uses externalRedis; enabled renders the bundled Valkey with persistence"

# C14 - upstream's zod schema rejects an AUTH_SECRET shorter than 32 chars.
# Cross-upgrade persistence needs a live cluster, so only the `lookup` mechanism
# itself is checkable here.
generated=$(secret_value "$r1" AUTH_SECRET)
if [ "${#generated}" -lt 32 ]; then
  note "R1: generated AUTH_SECRET is ${#generated} chars, expected >= 32"
fi
want_secret "$r3" AUTH_SECRET '^ci-external-auth-secret-0123456789abcdef$' "R3"
if [ -f "$chart/templates/secret.yaml" ]; then
  # Anchored on the call, not the bare word: `lookup` also appears in the
  # explanatory comment above it, so the loose pattern passed vacuously.
  want "$chart/templates/secret.yaml" \
    'lookup "v1" "Secret" \.Release\.Namespace' "secret.yaml (upgrade persistence, not renderable offline)"
  want "$chart/templates/secret.yaml" 'hasKey \$prior "AUTH_SECRET"' "secret.yaml (upgrade persistence, not renderable offline)"
else
  note "templates/secret.yaml missing"
fi
# existingSecret is the GitOps path, and it replaces the chart Secret rather
# than merging with it. Assert both halves: the chart Secret is gone, and every
# consumer follows the operator's name instead of still pointing at a Secret
# that no longer renders.
want_no_doc "$r16" Secret "$fullname" "R16"
if get_doc "$r16" Deployment "$fullname-all" "R16"; then
  want "$DOC" '^[[:space:]]*name: btb-byo-secret$' "R16 all"
fi
if get_doc "$r16" Job "$fullname-migrate" "R16"; then
  want_count "$DOC" '^[[:space:]]*name: btb-byo-secret$' 2 "R16 migrate job"
fi
check C14 "AUTH_SECRET auto-generates at >= 32 chars, persists via cluster lookup, explicit value wins"

# C15
want_not_in_tree "$chart" 'chrislee\.kr' "chart tree"
want "$r1" 'image: "?chrisleekr/binance-trading-bot:' "R1"
if [ -f "$readme" ]; then
  want "$readme" 'https://github\.com/chrisleekr/binance-trading-bot' "README (documentation-only clause)"
else
  note "README.md missing"
fi
check C15 "no chrislee.kr host anywhere, default image is chrisleekr/binance-trading-bot, docs point at the public repo"

# C16 - the event stream is a long-lived WebSocket, so the proxy timeouts matter.
if get_doc "$r4" Ingress "$fullname" "R4"; then
  want "$DOC" '^[[:space:]]*number: 3000$' "R4 ingress"
  want_not "$DOC" '9100' "R4 ingress"
  want_not "$DOC" '9101' "R4 ingress"
  want "$DOC" 'proxy-read-timeout' "R4 ingress"
  want "$DOC" 'proxy-send-timeout' "R4 ingress"
fi
check C16 "ingress routes only to Service port 3000 with WebSocket-safe timeouts"

# C17 - R4 proves the fallback resolves from the ingress host; R7 proves the
# unresolvable case fails loudly instead of emitting a broken origin.
# Scheme pinned per branch: R4 has no TLS so it must derive http, R10 has TLS so
# it must derive https. `https?` would have passed either way and left the whole
# ternary uncovered.
want "$r4" 'WEB_ORIGIN: "?http://btb\.ci\.example\.com"?' "R4"
want "$r10" 'WEB_ORIGIN: "?https://btb\.ci\.example\.com"?' "R10"
if [ "$r14_rc" -eq 0 ]; then
  note "R14: ingress with no TLS rendered instead of failing; the cleartext guard is cosmetic"
elif ! grep -qi 'cleartext' "$tmp/r14.err"; then
  note "R14: render failed but stderr never mentions cleartext: $(tr '\n' ' ' <"$tmp/r14.err")"
fi
if [ "$r7_rc" -eq 0 ]; then
  note "R7: render succeeded with no webOrigin and no ingress; expected a non-zero exit"
elif ! grep -qi 'weborigin' "$tmp/r7.err"; then
  note "R7: render failed but stderr never mentions webOrigin: $(tr '\n' ' ' <"$tmp/r7.err")"
fi
check C17 "an unresolvable webOrigin fails the render with an actionable message"

# C18 - the image runs as 1000:1000 and needs nothing writable but /backups and
# /tmp (HOME=/tmp).
if get_doc "$r1" Deployment "$fullname-all" "R1"; then
  want "$DOC" '^[[:space:]]*runAsNonRoot: true$' "R1 all"
  want "$DOC" '^[[:space:]]*runAsUser: 1000$' "R1 all"
  want "$DOC" '^[[:space:]]*runAsGroup: 1000$' "R1 all"
  want "$DOC" '^[[:space:]]*fsGroup: 1000$' "R1 all"
  want "$DOC" '^[[:space:]]*readOnlyRootFilesystem: true$' "R1 all"
  want "$DOC" '^[[:space:]]*- ALL$' "R1 all"
  want "$DOC" '^[[:space:]]*emptyDir:' "R1 all"
  want "$DOC" '^[[:space:]]*mountPath: /tmp$' "R1 all"
fi
# R8 is the serviceAccount.create=false branch the header comment advertises.
want_no_doc "$r8" ServiceAccount "$fullname" "R8"
if get_doc "$r8" Deployment "$fullname-all" "R8"; then
  want "$DOC" '^[[:space:]]*serviceAccountName: btb-preexisting$' "R8 all"
fi
check C18 "pods run non-root 1000:1000 with fsGroup, read-only rootfs, dropped capabilities and an emptyDir at /tmp"

# C19 - must clear the removed chart's 0.1.x for ct check-version-increment and
# the release.yml tag gate. A floor, not a pin: binance-trading-bot-sync.yml
# bumps both fields on every upstream release, so pinning the exact versions
# here would fail every sync PR it opens.
if [ -f "$chart/Chart.yaml" ]; then
  want "$chart/Chart.yaml" '^version: [1-9][0-9]*\.[0-9]+\.[0-9]+$' "Chart.yaml"
  want "$chart/Chart.yaml" '^appVersion: "v[1-9][0-9]*\.[0-9]+\.[0-9]+"$' "Chart.yaml"
else
  note "Chart.yaml missing"
fi
check C19 "Chart.yaml version and appVersion are >= 1.0.0, clearing the removed 0.1.x chart"

# C20 - grep-level only; renovate-config-validator is a separate CI step.
renovate="$repo_root/renovate.json"
syncwf="$repo_root/.github/workflows/binance-trading-bot-sync.yml"
if [ -f "$renovate" ]; then
  want "$renovate" 'timescale/timescaledb' "renovate.json"
  want "$renovate" 'valkey/valkey' "renovate.json"
  want "$renovate" 'otel/opentelemetry-collector-contrib' "renovate.json"
  # One owner for appVersion. The sync workflow bumps it together with the
  # Artifact Hub changelog it builds from the upstream release notes; a Renovate
  # manager on the same field opens a second PR for the same version, and the
  # workflow's idempotency check only recognises its own branch name.
  want_not "$renovate" 'charts/binance-trading-bot/Chart' "renovate.json"
  want_not "$renovate" 'chrisleekr/binance-trading-bot' "renovate.json"
else
  note "renovate.json missing"
fi
if [ -f "$syncwf" ]; then
  want "$syncwf" '\.appVersion = strenv' "binance-trading-bot-sync.yml"
else
  note "binance-trading-bot-sync.yml missing"
fi
# "validates strict" is half the criterion, and it is the half that catches a
# schema-invalid renovate.json. The greps above pass on a file the validator
# would reject, so assert CI actually runs it in strict mode. The invocation
# lives in its own reusable workflow, same as the per-chart gates.
lintwf="$repo_root/.github/workflows/lint.yml"
renovatewf="$repo_root/.github/workflows/lint-renovate.yml"
if [ -f "$renovatewf" ]; then
  want "$renovatewf" 'renovate-config-validator --strict' "lint-renovate.yml"
else
  note "lint-renovate.yml missing"
fi
# A reusable workflow nothing calls never runs, which would satisfy the grep
# above while the gate is dead. Assert lint.yml both calls it and rolls its
# result into "lint" -- the job id the branch ruleset requires. Without the
# needs edge a failing gate would not block the merge.
if [ -f "$lintwf" ]; then
  want "$lintwf" 'uses: \./\.github/workflows/lint-renovate\.yml' "lint.yml"
  want "$lintwf" '^ *needs: \[.*renovate.*\]' "lint.yml"
else
  note "lint.yml missing"
fi
check C20 "renovate.json tracks the bundled datastore images and leaves appVersion to the sync workflow"

# C21 - this script is the branch matrix, so the criterion is that CI runs it.
# On GitHub the per-chart gates live in reusable workflows, so the invocation is
# in lint-binance-trading-bot.yml rather than lint.yml.
for wf in "$repo_root/.github/workflows/lint-binance-trading-bot.yml" "$repo_root/.gitlab/ci/lint-binance-trading-bot.yml"; do
  if [ -f "$wf" ]; then
    # The invocation, not a mention: anchored to the step keyword of each CI
    # dialect (run: on GitHub, a list item on GitLab) so neither a comment naming
    # the script nor a commented-out step satisfies "CI runs the gate".
    want "$wf" '^[[:space:]]*(run:|-)[[:space:]]+bash scripts/check-binance-trading-bot-render\.sh' \
      "$(basename "$wf")"
  else
    note "$(basename "$wf") missing"
  fi
done
# A reusable workflow nothing calls never runs, which would satisfy the greps
# above while the gate is dead. Assert lint.yml both calls it and rolls its
# result into "lint" -- the job id the branch ruleset requires. Without the
# needs edge a failing gate would not block the merge.
if [ -f "$lintwf" ]; then
  want "$lintwf" 'uses: \./\.github/workflows/lint-binance-trading-bot\.yml' "lint.yml"
  want "$lintwf" '^ *needs: \[.*binance_trading_bot.*\]' "lint.yml"
else
  note "lint.yml missing"
fi
# Same dead-wiring hole on the GitLab side: an include file nothing includes is
# never parsed, so the invocation grep above would pass while the gate is dead.
glci="$repo_root/.gitlab-ci.yml"
if [ -f "$glci" ]; then
  want "$glci" 'local: \.gitlab/ci/lint-binance-trading-bot\.yml' ".gitlab-ci.yml"
else
  note ".gitlab-ci.yml missing"
fi
# Wired and reachable are different things. Everything above proves the gate is
# called; these prove a change to the gate still triggers the call. Drop this
# script from either host's path filter and the greps above stay green while a
# script-only PR silently stops running it.
if [ -f "$lintwf" ]; then
  want "$lintwf" "^[[:space:]]*'scripts/check-binance-trading-bot-render\.sh'" \
    "lint.yml changes filter"
fi
want "$repo_root/.gitlab/ci/lint-binance-trading-bot.yml" \
  '^[[:space:]]*- scripts/check-binance-trading-bot-render\.sh$' \
  "lint-binance-trading-bot.yml changes filter"
check C21 "CI runs this branch-matrix gate on both GitHub and GitLab"

# C22 - api and worker share BACKUP_DIR, hence the RWX note in the docs.
get_doc "$r1" PersistentVolumeClaim "$fullname-backups" "R1" || true
# The mount is only a backup directory if the app is told to write there.
want "$r1" '^[[:space:]]*BACKUP_DIR: "?/backups"?$' "R1"
if get_doc "$r1" Deployment "$fullname-all" "R1"; then
  want "$DOC" '^[[:space:]]*mountPath: /backups$' "R1 all"
  # ...and only persistent if the volume is the claim rather than an emptyDir.
  want "$DOC" "^[[:space:]]*claimName: $fullname-backups\$" "R1 all"
fi
want_not "$r8" '^kind: PersistentVolumeClaim$' "R8"
# persistence off keeps BACKUP_DIR and the mount, swapping the claim for an
# emptyDir, which is what the README promises and what stops the api 500ing on
# a missing directory.
want "$r8" '^[[:space:]]*BACKUP_DIR: "?/backups"?$' "R8"
if get_doc "$r8" Deployment "$fullname-all" "R8"; then
  want "$DOC" '^[[:space:]]*mountPath: /backups$' "R8 all"
  want_not "$DOC" "claimName: $fullname-backups" "R8 all"
fi
# In split topology the claim is shared by exactly the two roles that use it.
# study consumes backtest jobs and writes no dumps, so handing it the same RWO
# claim would wedge a third pod on Multi-Attach for nothing.
if get_doc "$r2" Deployment "$fullname-api" "R2"; then
  want "$DOC" "^[[:space:]]*claimName: $fullname-backups\$" "R2 api"
fi
if get_doc "$r2" Deployment "$fullname-worker" "R2"; then
  want "$DOC" "^[[:space:]]*claimName: $fullname-backups\$" "R2 worker"
fi
if get_doc "$r2" Deployment "$fullname-study" "R2"; then
  want_not "$DOC" "claimName: $fullname-backups" "R2 study"
  want "$DOC" '^[[:space:]]*mountPath: /backups$' "R2 study"
fi
if [ -f "$readme" ]; then
  want "$readme" 'ReadWriteMany' "README (documentation-only clause)"
else
  note "README.md missing"
fi
check C22 "persistence mounts a PVC at BACKUP_DIR and the split-topology sharing requirement is documented"

# C23
if get_doc "$r5" PrometheusRule "$fullname" "R5"; then
  want "$DOC" '^apiVersion: monitoring\.coreos\.com/v1$' "R5 prometheusrule"
  want "$DOC" '^[[:space:]]*for: 7m$' "R5 prometheusrule"
  want "$DOC" '^[[:space:]]*severity: critical$' "R5 prometheusrule"
  # Anchored to the expression it tunes: a bare '900' matches any digits
  # anywhere in the document and would survive the threshold reverting to the
  # hardcoded default.
  want "$DOC" '^[[:space:]]*expr: max\(binance_api_weight\{btb_release="[^"]+"\}\) > 900$' "R5 prometheusrule"
  want "$DOC" 'CiExtraRule' "R5 prometheusrule"
fi
want_no_doc "$r1" PrometheusRule "$fullname" "R1"
check C23 "PrometheusRule renders with values-tunable thresholds/for/severity and an additionalRules passthrough"

# C24 - /metrics lives on the admin port only, so scraping needs its own Service.
want "$r5" '^kind: ServiceMonitor$' "R5"
if get_doc "$r5" Service "$fullname-admin" "R5"; then
  # Both ports, or the worker and study roles silently stop being scraped.
  want "$DOC" '^[[:space:]]*port: 9100$' "R5 admin service"
  want "$DOC" '^[[:space:]]*port: 9101$' "R5 admin service"
  want "$DOC" '^[[:space:]]*clusterIP: None$' "R5 admin service"
  # A ServiceMonitor finds its Service by label and its endpoints by port NAME.
  # Asserting only that both objects exist leaves that coupling untested: rename
  # the port or drop the component label and Prometheus discovers zero targets
  # while every assertion here stays green.
  want "$DOC" '^[[:space:]]*app\.kubernetes\.io/component: admin$' "R5 admin service"
  want "$DOC" '^[[:space:]]*- name: admin$' "R5 admin service"
  want "$DOC" '^[[:space:]]*- name: worker-admin$' "R5 admin service"
fi
if get_doc "$r5" ServiceMonitor "$fullname" "R5"; then
  want_count "$DOC" '^[[:space:]]*path: /metrics$' 2 "R5 servicemonitor"
  want "$DOC" '^[[:space:]]*app\.kubernetes\.io/component: admin$' "R5 servicemonitor"
  want "$DOC" '^[[:space:]]*- port: admin$' "R5 servicemonitor"
  want "$DOC" '^[[:space:]]*- port: worker-admin$' "R5 servicemonitor"
fi
if get_doc "$r5" NetworkPolicy "$fullname" "R5"; then
  want "$DOC" 'kubernetes\.io/metadata\.name: monitoring' "R5 netpol"
fi
want_not "$r1" '^kind: ServiceMonitor$' "R1"
want_no_doc "$r1" Service "$fullname-admin" "R1"
check C24 "serviceMonitor.enabled renders the ServiceMonitor plus its admin Service and netpol source; off renders neither"

# C25
if get_doc "$r5" Deployment "$fullname-otel-collector" "R5"; then
  want "$DOC" '^[[:space:]]*containerPort: 4318$' "R5 collector deployment"
fi
if get_doc "$r5" Service "$fullname-otel-collector" "R5"; then
  # The app is pointed at :4318 below, so the Service has to answer there.
  want "$DOC" '^[[:space:]]*port: 4318$' "R5 collector service"
fi
if get_doc "$r5" ConfigMap "$fullname-otel-collector" "R5"; then
  want "$DOC" 'tail_sampling' "R5 collector config"
  # The forwarding path: real exporter, and header values arriving by env
  # substitution rather than sitting in this world-readable ConfigMap.
  # otlp_http, not the otlphttp alias the collector logs as deprecated.
  want "$DOC" '^[[:space:]]*otlp_http:$' "R5 collector config"
  want_not "$DOC" '^[[:space:]]*otlphttp:$' "R5 collector config"
  want "$DOC" 'authorization: "\$\{env:OTLP_HEADER_AUTHORIZATION\}"' "R5 collector config"
  want_not "$DOC" 'ci-token' "R5 collector config"
fi
if get_doc "$r5" Secret "$fullname-otel-collector-headers" "R5"; then
  want "$DOC" '^[[:space:]]*OTLP_HEADER_AUTHORIZATION:' "R5 collector headers"
  want "$DOC" '^[[:space:]]*OTLP_HEADER_X_TENANT:' "R5 collector headers"
fi
# The receivers are unauthenticated and the exporter spends the operator's
# vendor token, so the collector carries its own policy.
if get_doc "$r5" NetworkPolicy "$fullname-otel-collector" "R5"; then
  want "$DOC" '^[[:space:]]*port: 4317$' "R5 collector netpol"
  want "$DOC" '^[[:space:]]*port: 4318$' "R5 collector netpol"
  want "$DOC" '^[[:space:]]*- podSelector:$' "R5 collector netpol"
fi
want "$r5" "OTEL_EXPORTER_OTLP_ENDPOINT: \"?http://$fullname-otel-collector:4318\"?" "R5"
check C25 "otelCollector.enabled renders the Collector Deployment/ConfigMap/Service and points the app at it"

# C26 - upstream treats an empty endpoint as disabled, so unset must stay unset.
want "$r6" 'OTEL_EXPORTER_OTLP_ENDPOINT: "?http://otel-gateway\.observability\.svc:4318"?' "R6"
want "$r6" 'OTEL_EXPORTER_OTLP_HEADERS' "R6"
want_no_doc "$r6" Deployment "$fullname-otel-collector" "R6"
# The criterion is "no OTEL env vars", not "no endpoint": naming one key would
# let a stray OTEL_EXPORTER_OTLP_HEADERS or OTEL_SDK_DISABLED through, and
# upstream treats the presence of these at all as tracing being configured.
want_not "$r1" 'OTEL_' "R1"
check C26 "external otlp.endpoint is wired without a Collector; neither configured emits no OTEL env vars"

# C27 - grep of the v1.0.0 sources returns zero hits for these names, so an alert
# built on them can never fire.
for metric in binance_weight_used_1m tick_failures_total tick_total \
  bullmq_queue_wait_jobs pg_pool_idle pg_pool_total binance_ws_disconnects_total; do
  want_not_in_tree "$chart" "$metric" "chart tree"
done
# The absence half above only proves no known-bad name is used. These four are
# every metric the shipped alerts actually name, each verified against the
# v1.0.0 sources: worker_members_{ready,total} are Gauges in
# apps/worker/src/boot/member-registry.ts, otel_dropped_spans_total and
# pino_dropped_logs_total are Counters in packages/observability/src/index.ts,
# and all four register on the registry admin-server.ts serves at /metrics.
# Asserting presence keeps a rename or a typo from turning an alert into one
# that reads as permanently healthy.
if get_doc "$r5" PrometheusRule "$fullname" "R5"; then
  want "$DOC" 'expr: max\(binance_api_weight\{' "R5 prometheusrule"
  want "$DOC" 'expr: worker_members_ready\{.*\} < worker_members_total\{' "R5 prometheusrule"
  want "$DOC" 'increase\(otel_dropped_spans_total\{.*\}\[' "R5 prometheusrule"
  want "$DOC" 'increase\(pino_dropped_logs_total\{.*\}\[' "R5 prometheusrule"
  # Every built-in expression is scoped, and the label is the one the
  # ServiceMonitor stamps. An expression that lost its matcher would fire on
  # another release's identically named metrics; a matcher naming a label
  # nothing applies would go permanently silent, which is worse.
  sel=$(grep -cE 'expr: .*btb_release="'"$fullname"'"' "$DOC" || true)
  [ "$sel" = 4 ] || note "R5 prometheusrule: $sel of 4 built-in expressions scoped to btb_release=\"$fullname\""
fi
if get_doc "$r5" ServiceMonitor "$fullname" "R5"; then
  want "$DOC" "^[[:space:]]*- targetLabel: btb_release\$" "R5 servicemonitor"
  want "$DOC" "^[[:space:]]*replacement: \"$fullname\"\$" "R5 servicemonitor"
fi
if [ -f "$readme" ]; then
  if ! grep -qiE 'no alert coverage' "$readme"; then
    note "README (documentation-only clause): expected a 'no alert coverage' section in README.md"
  fi
else
  note "README.md missing"
fi
check C27 "no alert references a metric the v1.0.0 image never emits; the weight rule uses binance_api_weight"

# C28 - the 63-character budget. componentName used to truncate after appending
# the suffix, so a long release name dropped the suffix entirely and postgres,
# valkey, backups and migrate all resolved to the same string: a duplicate
# resource at install time, and a DSN pointing at whichever Service won.
if [ -s "$render_long" ]; then
  names=$(grep -E '^  name: ' "$render_long" | sed 's/^  name: //' | sort -u)
  over=$(printf '%s\n' "$names" | awk 'length($0) > 63')
  [ -z "$over" ] && : || note "R21: derived names over 63 characters: $(echo "$over" | tr '\n' ' ')"
  # The four suffixed components must stay four distinct names.
  suffixed=$(printf '%s\n' "$names" | grep -cE -- '-(postgres|valkey|backups|migrate)$' || true)
  [ "$suffixed" = 4 ] ||
    note "R21: $suffixed of 4 suffixed component names survived truncation"
else
  note "R21: long-release-name render produced nothing"
fi
check C28 "derived component names stay distinct and within 63 characters under a long release name"

# C29 - three guards for misconfigurations that are silent at install time. Each
# has to fail AND say why: a render that fails with an opaque template error
# sends the operator to the chart source rather than to their values file.
if [ "$r18_rc" -eq 0 ]; then
  note "R18: topology=split with the default ReadWriteOnce backups claim rendered instead of failing"
elif ! grep -q 'ReadWriteMany' "$tmp/r18.err"; then
  note "R18: render failed but stderr never names ReadWriteMany: $(tr '\n' ' ' <"$tmp/r18.err" | cut -c1-200)"
fi
if [ "$r19_rc" -eq 0 ]; then
  note "R19: databaseWaitSeconds >= activeDeadlineSeconds rendered instead of failing"
elif ! grep -q 'activeDeadlineSeconds' "$tmp/r19.err"; then
  note "R19: render failed but stderr never names activeDeadlineSeconds: $(tr '\n' ' ' <"$tmp/r19.err" | cut -c1-200)"
fi
if [ "$r20_rc" -eq 0 ]; then
  note "R20: scoped alerts rendered without the ServiceMonitor that applies the label they match"
elif ! grep -q 'serviceMonitor' "$tmp/r20.err"; then
  note "R20: render failed but stderr never names serviceMonitor: $(tr '\n' ' ' <"$tmp/r20.err" | cut -c1-200)"
fi
check C29 "render-time guards reject a split-topology RWO claim, a wait longer than the Job deadline, and unmatchable scoped alerts"

# -------------------------------------------------------------------- summary -

total=$((passed + failed))
printf '\n%s/%s assertions failed\n' "$failed" "$total"
# A criterion deleted rather than fixed still leaves "0 failed" behind, so pin
# the count: the acceptance list is exactly 29 and the gate covers all of them.
if [ "$total" -ne 29 ]; then
  printf 'FAIL gate: expected 29 criteria, ran %s\n' "$total" >&2
  exit 1
fi
[ "$failed" -eq 0 ]
