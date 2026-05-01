# Examples

Reference `ScaledObject` shapes for KEDA. Apply them after `keda_install`
has the operator + CRDs running.

| File | Use case | Exercised by smoke? |
|---|---|---|
| [`cron.yaml`](cron.yaml) | Time-of-day scaling. The simplest scaler — no external dependency, just a cron schedule. What `tests/smoke_test.sh` uses. | Yes |
| [`kafka_lag.yaml`](kafka_lag.yaml) | Scale a consumer Deployment based on Kafka consumer-group lag. The canonical KEDA use case. Sketch — needs a real Kafka cluster (e.g. via `rules_kafka`). | No |
| [`prometheus_query.yaml`](prometheus_query.yaml) | Scale based on the result of a Prometheus query. Useful for scaling on application-specific metrics (request rate, queue depth via histograms, etc.). Sketch — needs a Prometheus-compatible API (e.g. `rules_mimir`). | No |
| [`scaled_job.yaml`](scaled_job.yaml) | `ScaledJob` (not ScaledObject) — KEDA creates a Job per event. Useful for batch / "one-shot per message" workloads. | No |

## Things this directory deliberately does NOT show

- **Cloud queue scalers** (AWS SQS, Azure Service Bus, GCP PubSub) —
  each backend has its own auth flow and out-of-cluster credentials
  don't belong in a hermetic example.
- **`TriggerAuthentication` / `ClusterTriggerAuthentication` CRs** —
  needed for scalers requiring API tokens, IAM roles, etc. Same
  authentication-credential reasoning as the cloud-queue case.
- **HPA fallback config** — `fallback.failureThreshold` /
  `fallback.replicas` for graceful degradation when the trigger
  source is unreachable. Production concern; not v0.1 example
  material.
- **`paused` / `pause-replicas` annotation** — temporarily disables
  KEDA's reconciliation of a ScaledObject. Operational, not a
  smoke-shape concern.
