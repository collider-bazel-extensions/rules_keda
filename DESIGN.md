# rules_keda — design decisions

Hermetic [KEDA](https://keda.sh/) install for Bazel test compositions.
Same shape as `rules_argocd` / `rules_external_secrets` /
`rules_cloudnativepg` — operator + CRDs + smoke applies a CR and
asserts on operator-reconciled state.

## Decided

| # | Decision | Choice | Source |
|---|---|---|---|
| 1 | Bzlmod / WORKSPACE | **Bzlmod-only at v0.1.** | Sibling-family |
| 2 | Module / repo name | `rules_keda`. | Convention |
| 3 | Architecture | **Layered.** Two macros wrapping `kubectl_apply` / `kubectl_apply_health_check`. | rules_loki / rules_argocd / rules_external_secrets |
| 4 | Manifest provisioning | KEDA helm chart **pre-rendered** into `private/manifests/keda.yaml` via `rules_helm`. Committed. CRDs are in `templates/crds/` (rendered by default — no `--include-crds` needed). | rules_loki pattern |
| 5 | Single-version | One pinned chart (`2.19.0`, KEDA app `2.19.0`). | Pragmatic |
| 6 | Render mode | **Smoke fixture.** Default chart values + a few overrides: PodDisruptionBudgets off (single replica), ServiceMonitor off (no Prometheus Operator), NetworkPolicy off (default-allow keeps the smoke simple). README warns the values are not a production starting point. | Smoke pragmatic |
| 7 | Public surface | `keda_install`, `keda_health_check`. **No `keda_scaled_object` rule** — KEDA supports 60+ scaler types × multiple auth flavors each; v0.1 documents the YAML pattern + ships `examples/`. | Smaller surface |
| 8 | Namespace | `keda` (default, idempotent create). | Convention |
| 9 | Wait shape | 3 Deployments (`keda-operator`, `keda-operator-metrics-apiserver`, `keda-admission-webhooks`) + 2 CRDs (`scaledobjects.keda.sh`, `scaledjobs.keda.sh`). The CRD wait is load-bearing — same race-against-CRD-installer lesson rules_argocd / rules_cloudnativepg / rules_external_secrets taught. | KEDA-specific |
| 10 | Smoke trigger | **`cron` scaler** at v0.1. The cron trigger has no external dependency — KEDA evaluates a cron expression against wall-clock time and sets `desiredReplicas` based on whether we're "in window." Real KEDA workloads use Kafka / Redis / Prometheus / SQS / etc., but those add fixture pods that obscure the KEDA-specific assertion. | Standalone smoke |
| 11 | Smoke assertion | Apply a tiny Deployment (replicas=0). Apply a ScaledObject targeting it with a `cron` trigger whose window is "active right now" (computed dynamically — see "Cron window math" below). Poll `Deployment.status.readyReplicas` until it reaches `desiredReplicas` (default 2; ceiling 180s). Proves operator reconciler + admission webhook + metrics server + KEDA-managed HPA all work end-to-end. | Per the family's "exercise the functionality" rule |
| 12 | Cross-rule deps | `rules_kubectl` public dep. `rules_helm` + `rules_kind` + `rules_itest` + `rules_shell` dev-only. | rules_loki precedent |
| 13 | Naming | snake_case rules/macros, `MixedCaseInfo` providers (none in v0.1), `UPPER_SNAKE` constants. | All siblings |
| 14 | Update workflow | `bash tools/render_keda.sh <chart-version>` → thin shim. | rules_loki precedent |

## Why cron, not Kafka-lag

KEDA's "marquee" use case is event-driven scaling — Kafka consumer-group
lag, Redis stream length, Prometheus query results, SQS queue depth.
Any of those would make a more representative smoke. They also make
the smoke harder:

- **Kafka-lag**: needs `rules_kafka` (or equivalent) standing up a
  broker, a consumer Deployment running with a specific consumer group,
  the smoke producing messages to lag the consumer behind, then
  asserting the consumer Deployment scaled. Cross-rule composition
  + protobuf-ish data setup obscure the KEDA-specific signal.
- **Prometheus query**: needs Prometheus (or `rules_mimir`) + a
  metric source emitting predictable values. Same kind of
  fixture overhead.
- **SQS / cloud queues**: needs cloud credentials. Out of scope for a
  hermetic smoke.
- **`metrics-api`**: KEDA has an `external` scaler that polls an HTTP
  endpoint returning a JSON number. Could spin up a "fake metrics"
  HTTP server pod. Roughly the same complexity as cron, no real
  advantage.

The `cron` scaler exercises the whole KEDA chain — operator
reconciler + admission webhook + metrics server + HPA — without any
external fixture. It's the right v0.1 choice.

A v0.2 or follow-up rule set could add composed smokes:
- `rules_keda` × `rules_kafka` for Kafka-lag scaling
- `rules_keda` × `rules_mimir` for Prometheus-query scaling

## Cron window math

KEDA's `cron` scaler takes two cron expressions, `start` and `end`.
Its "in-window" determination uses the upcoming firing times: if the
*next* end-fire is sooner than the next start-fire, we're in window
(because start must have fired more recently than end for that to be
true). This means a smoke can be reliably "in window" by setting:

- `start` = "X * * * *" where X = (current_minute - 5) mod 60
- `end` = "Y * * * *" where Y = (current_minute + 25) mod 60

Both fire every hour, but at the time the smoke runs, "next end"
fires before "next start" → in window. Five minutes of head-room
before, 25 minutes after, gives plenty of buffer for slow runners.

Bash gotcha worth remembering: `(( (NOW + 25) % 60 ))` interprets
`08`/`09` as octal and fails ("value too great for base"). Use
`10#$NOW_MIN` to force base-10. Same trick rules_kafka's smoke
uses for hex-from-`/dev/urandom` byte counts.

## Webhook, cert-manager, and the chart's self-signed cert

KEDA's admission webhook validates `ScaledObject` / `ScaledJob` CRs
at apply time (catches conflicting trigger configs, references to
nonexistent target workloads, etc.). Webhook serving certs come from
one of three places:

1. **Chart-managed** (default): the chart generates a self-signed cert
   at install time via Helm's `genSelfSignedCert`. Works out of the
   box, but the cert isn't rotated automatically.
2. **cert-manager-managed**: `certManager.use: true` in chart values
   makes the chart emit `Certificate` / `Issuer` CRs that cert-manager
   reconciles into a Secret the webhook reads. Production-grade.
3. **External**: pre-create the Secret, point the chart at it via
   `certManager.useGeneratedCerts: false` + your secret name.

v0.1 uses the chart-managed self-signed path — no extra dependency
on `rules_certmanager`. A future smoke composing with rules_certmanager
would exercise the cert-manager path.

## v0.1.0 status

| Area | State |
|---|---|
| MODULE.bazel (Bzlmod-only) | done |
| `keda_install` + `keda_health_check` macros | done |
| Pinned KEDA chart 2.19.0 (rendered + committed) | done |
| `config/keda-values.yaml` (exported) | done |
| Maintainer render flow (`bash tools/render_keda.sh <ver>`) | done |
| Analysis test | done |
| Smoke (kind + KEDA + ScaledObject with cron trigger + scale-up assertion) | done |
| `examples/` (cron, Kafka-lag sketch, Prometheus-query sketch) | done |

## Deferred (not v0.1.0)

- **Kafka-lag composed smoke** (`rules_kafka` + `rules_keda`) — the
  canonical KEDA use case. v0.2 candidate.
- **Prometheus-query composed smoke** (`rules_mimir` + `rules_keda`) —
  scale based on a PromQL result. v0.2 candidate.
- **`ScaledJob` smoke** — KEDA scales Jobs (per-event Job creation),
  semantically different from ScaledObject's per-replica scaling.
- **`TriggerAuthentication` smoke** — auth credential refs for
  scalers needing API tokens / cluster role bindings / IAM identities.
- **cert-manager-managed webhook cert** — `certManager.use: true` +
  compose with rules_certmanager.
- **HPA fallback config** — what KEDA does when the trigger source
  is unreachable (`fallback.failureThreshold` / `fallback.replicas`).
- **Multi-tenant / `watchNamespace` smoke** — KEDA can be scoped to
  a single namespace via `watchNamespace`. Different shape.
- **Multi-version chart support** — single pin in v0.1.
