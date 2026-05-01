#!/usr/bin/env bash
# Apply a Deployment + ScaledObject with a `cron` trigger window that's
# active right now, then wait for KEDA to scale the Deployment up.
# Strategy:
#
#   1. Apply a tiny Deployment (`busybox` `sleep`) at replicas=0 in a
#      smoke namespace. This is the workload KEDA will scale.
#   2. Apply a ScaledObject targeting that Deployment with a `cron`
#      trigger whose window started ~5 minutes ago and ends ~25
#      minutes from now (UTC). Construct the cron strings dynamically
#      so the smoke is always "currently in window" regardless of
#      wall-clock when CI fires.
#      desiredReplicas: 2.
#   3. Poll the Deployment's `.status.readyReplicas` until it reaches
#      2 (default ceiling: 120s).
#
# Proves: KEDA operator reconciler + admission webhook (validates the
# ScaledObject) + metrics server + the underlying HPA all wired.
# The cron scaler has no external dependency — keeps the v0.1 smoke
# standalone. Composed smokes (Kafka-lag, Prometheus-query, etc.) are
# v0.2.
set -euo pipefail

CLUSTER_NAME="cluster"
env_file="$TEST_TMPDIR/${CLUSTER_NAME}.env"
[[ -f "$env_file" ]] || { echo "missing kind env file" >&2; exit 1; }
# shellcheck disable=SC1090
source "$env_file"

KCTL=("$KUBECTL" --kubeconfig="$KUBECONFIG")

NS="smoke"
WORKLOAD="cron-target"
SCALED="cron-scaler"
DESIRED=2

# ---- compute cron window ----------------------------------------------------
# `start` cron fires every hour at minute (NOW - 5). `end` cron fires
# every hour at minute (NOW + 25). KEDA's cron scaler considers us
# "in window" when nextEnd < nextStart — i.e., end will fire before
# start fires again, meaning start fired more recently than end.
# Five minutes of head-room means the smoke is solidly inside the
# window even on a slow runner.
#
# `10#$VAR` forces base-10 arithmetic (bash treats `08`/`09` as octal
# without the prefix → `value too great for base` errors when minute
# is 08 or 09).
NOW_MIN=$(date -u +%M)
START_MIN=$(( (10#$NOW_MIN + 60 - 5) % 60 ))
END_MIN=$((  (10#$NOW_MIN + 25)     % 60 ))
echo "smoke_test: cron window — start='${START_MIN} * * * *' (UTC), end='${END_MIN} * * * *' (UTC)"

echo "smoke_test: applying Deployment '${WORKLOAD}' (replicas=0) + ScaledObject '${SCALED}'"
"${KCTL[@]}" apply -f - <<EOF
---
apiVersion: v1
kind: Namespace
metadata:
  name: ${NS}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${WORKLOAD}
  namespace: ${NS}
spec:
  replicas: 0
  selector:
    matchLabels:
      app: ${WORKLOAD}
  template:
    metadata:
      labels:
        app: ${WORKLOAD}
    spec:
      containers:
        - name: sleep
          image: busybox:1.37
          command: ['sh', '-c', 'sleep 86400']
          resources:
            requests:
              cpu: 5m
              memory: 8Mi
---
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: ${SCALED}
  namespace: ${NS}
spec:
  scaleTargetRef:
    kind: Deployment
    name: ${WORKLOAD}
  pollingInterval: 5
  cooldownPeriod: 30
  minReplicaCount: 0
  maxReplicaCount: ${DESIRED}
  triggers:
    - type: cron
      metadata:
        timezone: UTC
        start: "${START_MIN} * * * *"
        end: "${END_MIN} * * * *"
        desiredReplicas: "${DESIRED}"
EOF

echo "smoke_test: waiting for Deployment '${WORKLOAD}' to reach readyReplicas=${DESIRED}"
deadline=$(( $(date +%s) + 180 ))
ready=0
while (( $(date +%s) < deadline )); do
  ready=$("${KCTL[@]}" -n "$NS" get deploy "$WORKLOAD" \
      -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  ready=${ready:-0}
  if (( ready >= DESIRED )); then
    break
  fi
  sleep 3
done

if (( ready < DESIRED )); then
  echo "smoke_test: FAIL — Deployment never reached ${DESIRED} ready replicas (last seen: ${ready})" >&2
  echo "---- ScaledObject status ----" >&2
  "${KCTL[@]}" -n "$NS" get scaledobject "$SCALED" -o yaml >&2 || true
  echo "---- HPA (KEDA-managed) ----" >&2
  "${KCTL[@]}" -n "$NS" get hpa -o yaml >&2 || true
  echo "---- KEDA operator logs (tail) ----" >&2
  "${KCTL[@]}" -n keda logs deploy/keda-operator --tail=80 >&2 || true
  exit 1
fi

echo "smoke_test: OK — KEDA's cron trigger scaled '${WORKLOAD}' to ${ready} replicas"
