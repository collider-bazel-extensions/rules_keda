# rules_keda

Hermetic [KEDA](https://keda.sh/) (Kubernetes Event-Driven Autoscaling)
install for Bazel test compositions. Pure glue layer over
[`rules_kubectl`](https://github.com/collider-bazel-extensions/rules_kubectl) —
`keda_install` is a macro emitting a `kubectl_apply` target pre-configured
with KEDA's pinned manifest and the right wait shape (Deployments + CRDs).

```python
load("@rules_keda//:defs.bzl", "keda_install", "keda_health_check")

keda_install(name = "keda_install_bin")          # default ns: keda
keda_health_check(name = "keda_health_bin")
```

That's the whole API. KEDA scales Kubernetes Deployments / StatefulSets
/ Jobs based on event sources — Kafka consumer-group lag, Redis stream
length, Prometheus query results, AWS SQS queue depth, cron schedules,
and 60+ other built-in scalers. This rule set installs the operator +
metrics server + admission webhook ready for `ScaledObject` /
`ScaledJob` / `TriggerAuthentication` CRs (consumer-authored YAML —
see [`examples/`](examples/)).

**Pinned versions:** KEDA helm chart `2.19.0` (KEDA app `2.19.0`).
Smoke-fixture render — single replica per Deployment, CRDs included,
PodDisruptionBudgets / ServiceMonitors / NetworkPolicies off (they
require external CRDs or reduce smoke flexibility). The values file
is exported as `@rules_keda//config:keda-values.yaml` for inspection
/ extension.

**Supported platforms (v0.1):** any platform where rules_kubectl runs.
Validated on Linux x86\_64 in CI.

---

## Contents

- [Installation](#installation) (Bzlmod-only)
- [Quickstart](#quickstart)
- [Defining ScaledObjects](#defining-scaledobjects)
- [Macros](#macros)
- [Hermeticity exceptions](#hermeticity-exceptions)
- [Contributing](#contributing)

---

## Installation

```python
bazel_dep(name = "rules_keda", version = "0.1.0")
```

Bzlmod-only. Transitively pulls in
[`rules_kubectl`](https://github.com/collider-bazel-extensions/rules_kubectl).

---

## Quickstart

```python
load("@rules_itest//:itest.bzl", "itest_service", "service_test")
load("@rules_keda//:defs.bzl", "keda_install", "keda_health_check")
load("@rules_kind//:defs.bzl", "kind_cluster", "kind_health_check")
load("@rules_kubectl//:defs.bzl", "kubectl_apply")
load("@rules_shell//shell:sh_binary.bzl", "sh_binary")

# 1. Cluster.
kind_cluster(name = "cluster", k8s_version = "1.32")
kind_health_check(name = "cluster_health", cluster = ":cluster")
itest_service(name = "kind_svc", exe = ":cluster", health_check = ":cluster_health")

# 2. KEDA operator.
keda_install(name = "keda_install_bin")
keda_health_check(name = "keda_health_bin")
sh_binary(name = "keda_install_wrapper", srcs = ["install_wrapper.sh"], data = [":keda_install_bin"])
sh_binary(name = "keda_health_wrapper",  srcs = ["health_wrapper.sh"],  data = [":keda_health_bin"])

itest_service(
    name = "keda_svc",
    exe = ":keda_install_wrapper",
    deps = [":kind_svc"],
    health_check = ":keda_health_wrapper",
)

# 3. The actual ScaledObject — your YAML.
kubectl_apply(
    name = "scaledobjects_install_bin",
    manifests = ["my_scaledobjects.yaml"],
)
sh_binary(name = "so_install_wrapper", srcs = ["install_wrapper.sh"], data = [":scaledobjects_install_bin"])

itest_service(
    name = "scaledobjects_svc",
    exe = ":so_install_wrapper",
    deps = [":keda_svc"],   # waits for operator + CRDs before applying ScaledObject CRs
    # ...
)
```

`install_wrapper.sh` / `health_wrapper.sh` are ~20-line shims — see
`tests/install_wrapper.sh` for the canonical shape.

---

## Defining ScaledObjects

`rules_keda` deliberately does NOT ship a `keda_scaled_object` Bazel
rule. KEDA supports 60+ scaler types × multiple auth flavors each;
a v0.1 macro would either flatten everything (becomes a YAML
translator) or hide most scalers. **Author your CRs as YAML and
apply via `kubectl_apply`.**

The simplest pattern (and what `tests/smoke_test.sh` uses):

```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata: {name: cron-scaler, namespace: app}
spec:
  scaleTargetRef:
    kind: Deployment
    name: my-workload
  pollingInterval: 30   # default
  minReplicaCount: 0
  maxReplicaCount: 10
  triggers:
    - type: cron
      metadata:
        timezone: UTC
        start:  "0 8 * * *"     # 8am UTC every day
        end:    "0 18 * * *"    # 6pm UTC every day
        desiredReplicas: "10"
```

For real scalers (Kafka, Redis, Prometheus, SQS, etc.), see
[`examples/`](examples/).

---

## Macros

### `keda_install`

```python
keda_install(
    name = "keda_install_bin",
    namespace = "keda",         # default
    wait_timeout = "300s",      # default
)
```

Expands to a `kubectl_apply(...)` target that:

- Applies `@rules_keda//private/manifests:keda.yaml`.
- `create_namespace = True` (default `keda`).
- `server_side = True`.
- `wait_for_deployments = ["keda-operator", "keda-operator-metrics-apiserver", "keda-admission-webhooks"]`.
- `wait_for_crds = ["scaledobjects.keda.sh", "scaledjobs.keda.sh"]` —
  load-bearing: prevents downstream services from racing the CRD
  installer when applying `ScaledObject` / `ScaledJob` CRs.

Drops into `itest_service.exe`.

### `keda_health_check`

```python
keda_health_check(name = "keda_health_bin", namespace = "keda")
```

Drops into `itest_service.health_check`. Same wait shape with
`--timeout=0s`.

---

## Hermeticity exceptions

| Component | Status | Notes |
|---|---|---|
| KEDA manifest | Fully hermetic. URL + sha256 pinned in `tools/versions.bzl`; pre-rendered + committed. | Re-render via `bash tools/render_keda.sh <ver>`. |
| `kubectl` | Inherited from `rules_kubectl`. | |
| Target cluster | Out of scope. | |
| KEDA container images | Pulled at runtime by the cluster's nodes. `ghcr.io/kedacore/keda*`. | Future: pre-load via `kind_cluster.images`. |

---

## Contributing

PRs welcome. Conventions match the sibling rule sets:

- New rules need an analysis test in `tests/analysis_tests.bzl`.
- Bumping the pinned chart version: edit `tools/versions.bzl`, add a
  `helm_template + sh_binary` block in `tools/BUILD.bazel`, run
  `bash tools/render_keda.sh <new-version>`, commit.
- `MODULE.bazel.lock` is intentionally not committed.

### Help wanted

- macOS validation
- Kafka-lag scaler smoke (compose with [`rules_kafka`](https://github.com/collider-bazel-extensions/rules_kafka))
- Prometheus-query scaler smoke (compose with [`rules_mimir`](https://github.com/collider-bazel-extensions/rules_mimir))
- `ScaledJob` smoke (KEDA scales Jobs, not Deployments — different
  semantics around per-event Job creation)
- `TriggerAuthentication` smoke (auth credential refs for scalers
  needing API tokens / cluster role-binding / IAM-style auth)
- `cert-manager` integration for the admission webhook serving cert
  (the chart self-signs by default; production deployments often
  use `certManager.use: true`)
- HPA fallback config — what KEDA does when the trigger source is
  unreachable
