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
_KEDA_CRDS = [
    "scaledobjects.keda.sh",
    "scaledjobs.keda.sh",
]

def keda_install(
        name,
        namespace = "keda",
        wait_timeout = "300s",
        **kwargs):
    """Apply KEDA to the cluster, in two pieces (see "Why two pieces"
    below). Composes via `itest_service.deps`:

        keda_install(name = "keda_install_bin")           # emits :keda_install_bin
                                                          # AND   :keda_install_bin_kubesys
        # In your tests/BUILD.bazel:
        itest_service(name = "keda_kubesys_svc",
                      exe = ":keda_install_bin_kubesys_wrapper",
                      deps = [":kind_svc"], ...)
        itest_service(name = "keda_svc",
                      exe = ":keda_install_wrapper",
                      health_check = ":keda_health_wrapper",
                      deps = [":keda_kubesys_svc"], ...)

    Why two pieces: the KEDA chart hard-codes a `keda-operator-auth-reader`
    RoleBinding to `metadata.namespace: kube-system` (so the metrics-
    apiserver can read kube-system's `extension-apiserver-authentication`
    ConfigMap — needed for aggregated-API-server auth between
    kube-apiserver and the metrics-apiserver). rules_kubectl's
    `kubectl_apply` passes a single `-n <ns>` flag and kubectl rejects
    multi-namespace YAML. Splitting into two `kubectl_apply` targets
    (one with `-n keda`, one with `-n kube-system`) sidesteps this.
    The metrics-apiserver Deployment crash-loops without the
    RoleBinding, so even cron-trigger smokes (which don't query
    external metrics) need it applied for the install wait to succeed.

    Drops into `itest_service.exe`. Wait timeout 300s — KEDA images
    are small (~120MB combined for the three) and cluster startup
    dominates.
    """
    extra_deploys = kwargs.pop("wait_for_deployments", [])
    extra_rollouts = kwargs.pop("wait_for_rollouts", [])
    extra_crds = kwargs.pop("wait_for_crds", [])

    # Piece 1: the auth-reader RoleBinding in kube-system. Tiny —
    # one resource. Doesn't create the kube-system namespace (it
    # always exists in any cluster). Paired health_check is a no-op
    # (no Deployments / rollouts / CRDs in this slice) — exits 0 as
    # soon as the install binary's apply completes.
    kubectl_apply(
        name = name + "_kubesys",
        manifests = ["@rules_keda//private/manifests:keda-kubesys.yaml"],
        namespace = "kube-system",
        create_namespace = False,
        server_side = True,
        wait_timeout = "60s",
        tags = kwargs.get("tags", []),
    )
    kubectl_apply_health_check(
        name = name + "_kubesys_health",
        namespace = "kube-system",
        tags = kwargs.get("tags", []),
    )

    # Piece 2: the bulk of KEDA — operator + metrics-apiserver +
    # admission-webhooks Deployments, the CRDs, RBAC, services, etc.
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
