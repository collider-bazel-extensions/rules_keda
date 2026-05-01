#!/usr/bin/env bash
set -euo pipefail

SRC_BAZEL_BIN="${1:?usage: writeback.sh <bazel-bin source> <dest path under workspace>}"
DEST_REL="${2:?missing dest path}"

WORKSPACE="${BUILD_WORKSPACE_DIRECTORY:?BUILD_WORKSPACE_DIRECTORY not set; run via 'bazel run'}"

if [[ -z "${RUNFILES_DIR:-}" ]]; then
  if [[ -d "${0}.runfiles" ]]; then RUNFILES_DIR="${0}.runfiles"
  elif [[ -d "$(dirname "$0").runfiles" ]]; then RUNFILES_DIR="$(dirname "$0").runfiles"
  fi
  export RUNFILES_DIR
fi
RENDERED="${RUNFILES_DIR}/_main/${SRC_BAZEL_BIN}"
[[ -f "$RENDERED" ]] || { echo "writeback: missing rendered YAML at $RENDERED" >&2; exit 1; }

DEST="${WORKSPACE}/${DEST_REL}"
mkdir -p "$(dirname "$DEST")"

# Surgically strip the `keda-operator-auth-reader` RoleBinding. It's a
# RoleBinding hard-coded to `metadata.namespace: kube-system` (chart's
# `rbac.controlPlaneServiceAccountsNamespace` value, used so KEDA's
# metrics-apiserver can read the `extension-apiserver-authentication`
# ConfigMap that lives in kube-system — needed for aggregated-API-server
# auth between kube-apiserver and the metrics-apiserver, which only
# external-metrics scalers actually use). A multi-namespace manifest
# can't be applied through rules_kubectl's `-n <ns>` apply path —
# kubectl rejects with "the namespace from the provided object
# 'kube-system' does not match the namespace 'keda'." v0.1's cron-
# trigger smoke doesn't use external metrics (cron is operator-evaluated,
# no metrics-apiserver involvement), so dropping this RoleBinding
# loses functionality the smoke wouldn't have exercised anyway. v0.2
# adding external-metrics scalers will need to either split the
# manifest into per-namespace pieces or open a PR against rules_kubectl
# to allow applying multi-namespace YAML without -n.
python3 - "$RENDERED" "$DEST" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
with open(src) as f:
    text = f.read()

docs = text.split("\n---\n")
kept = []
for d in docs:
    # Match on resource name AND namespace AND kind so we don't
    # accidentally strip a future resource that shares one of them.
    if ("name: keda-operator-auth-reader" in d
            and "namespace: kube-system" in d
            and "kind: RoleBinding" in d):
        continue
    kept.append(d)
with open(dst, "w") as f:
    f.write("\n---\n".join(kept))
PY

SHA256=$(sha256sum "$DEST" | awk '{print $1}')
LINES=$(wc -l < "$DEST")
echo "writeback: wrote $DEST"
echo "  sha256: $SHA256"
echo "  lines:  $LINES"
