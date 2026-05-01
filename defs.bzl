"""Public API for rules_keda."""

load("@rules_kubectl//:defs.bzl", "kubectl_apply", "kubectl_apply_health_check")

# KEDA's three core Deployments. Release name pinned to `keda` at
# maintainer-render time. The metrics server backs k8s
# `external.metrics.k8s.io` requests for HPA's external-metrics
# scaling decisions; the admission webhook validates ScaledObject /
# ScaledJob CRs at apply time; the operator reconciles the CRs into
# HPAs that drive the actual scaling.
_KEDA_DEPLOYS = [
    "keda-operator",
    "keda-operator-metrics-apiserver",
    "keda-admission-webhooks",
]
_KEDA_ROLLOUTS = []

# CRD wait. The smoke (and any consumer applying ScaledObjects in a
# downstream itest_service) MUST wait until the CRD is `Established`
# before applying CRs — otherwise `kubectl apply -f scaledobject.yaml`
# returns "no matches for kind 'ScaledObject'" race-against-installer.
# Same lesson rules_argocd / rules_external_secrets / rules_cloudnativepg
# learned. We wait on the most likely CR consumers will apply
# (ScaledObject + ScaledJob); the others (TriggerAuthentication,
# CloudEventSource, etc.) install in the same operation so by the time
# these two are Established the rest are too.
_KEDA_CRDS = [
    "scaledobjects.keda.sh",
    "scaledjobs.keda.sh",
]

def keda_install(
        name,
        namespace = "keda",
        wait_timeout = "300s",
        **kwargs):
    """Apply the pinned KEDA manifest into `namespace` and block until
    the operator + metrics server + admission webhook Deployments are
    Available AND the ScaledObject + ScaledJob CRDs are Established.

    Drops into `itest_service.exe`. Wait timeout 300s — KEDA images
    are small (~120MB combined for the three) and cluster startup
    dominates.
    """
    extra_deploys = kwargs.pop("wait_for_deployments", [])
    extra_rollouts = kwargs.pop("wait_for_rollouts", [])
    extra_crds = kwargs.pop("wait_for_crds", [])
    kubectl_apply(
        name = name,
        manifests = ["@rules_keda//private/manifests:keda.yaml"],
        namespace = namespace,
        create_namespace = True,
        server_side = True,
        wait_for_deployments = list(_KEDA_DEPLOYS) + list(extra_deploys),
        wait_for_rollouts = list(_KEDA_ROLLOUTS) + list(extra_rollouts),
        wait_for_crds = list(_KEDA_CRDS) + list(extra_crds),
        wait_timeout = wait_timeout,
        **kwargs
    )

def keda_health_check(
        name,
        namespace = "keda",
        **kwargs):
    """Readiness probe paired with `keda_install`."""
    extra_deploys = kwargs.pop("wait_for_deployments", [])
    extra_rollouts = kwargs.pop("wait_for_rollouts", [])
    extra_crds = kwargs.pop("wait_for_crds", [])
    kubectl_apply_health_check(
        name = name,
        namespace = namespace,
        wait_for_deployments = list(_KEDA_DEPLOYS) + list(extra_deploys),
        wait_for_rollouts = list(_KEDA_ROLLOUTS) + list(extra_rollouts),
        wait_for_crds = list(_KEDA_CRDS) + list(extra_crds),
        **kwargs
    )
