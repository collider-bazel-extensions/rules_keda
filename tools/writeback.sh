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
DEST_KUBESYS="${DEST%.yaml}-kubesys.yaml"
mkdir -p "$(dirname "$DEST")"

# Split the rendered manifest into two pieces by metadata.namespace:
#   - keda.yaml         — everything except the auth-reader RoleBinding
#                         (cluster-scoped resources + everything in
#                         the keda namespace)
#   - keda-kubesys.yaml — only the `keda-operator-auth-reader`
#                         RoleBinding, which is hard-coded to
#                         `namespace: kube-system` (chart's
#                         `rbac.controlPlaneServiceAccountsNamespace`,
#                         needed so KEDA's metrics-apiserver can read
#                         `extension-apiserver-authentication` from
#                         kube-system — used for aggregated-API-server
#                         auth between kube-apiserver and the
#                         metrics-apiserver).
#
# Why split: rules_kubectl's `kubectl_apply` passes a single `-n <ns>`
# flag and kubectl rejects multi-namespace YAML ("the namespace from
# the provided object 'kube-system' does not match the namespace
# 'keda'"). Applying as two separate `kubectl_apply` targets
# (one with `-n keda`, one with `-n kube-system`) sidesteps this.
# The metrics-apiserver Deployment crash-loops without the
# RoleBinding, so we can't just strip it — even cron-trigger smokes
# (which don't use external metrics) wait on the metrics-apiserver
# becoming Available.
python3 - "$RENDERED" "$DEST" "$DEST_KUBESYS" <<'PY'
import sys
src, dst_main, dst_kubesys = sys.argv[1], sys.argv[2], sys.argv[3]
with open(src) as f:
    text = f.read()

docs = text.split("\n---\n")
main_docs = []
kubesys_docs = []
for d in docs:
    # The auth-reader RoleBinding goes to kube-system; everything else
    # (cluster-scoped + keda-namespaced) goes to the main manifest.
    if ("name: keda-operator-auth-reader" in d
            and "namespace: kube-system" in d
            and "kind: RoleBinding" in d):
        kubesys_docs.append(d)
    else:
        main_docs.append(d)

with open(dst_main, "w") as f:
    f.write("\n---\n".join(main_docs))
with open(dst_kubesys, "w") as f:
    f.write("\n---\n".join(kubesys_docs))
PY

for f in "$DEST" "$DEST_KUBESYS"; do
  SHA256=$(sha256sum "$f" | awk '{print $1}')
  LINES=$(wc -l < "$f")
  echo "writeback: wrote $f"
  echo "  sha256: $SHA256"
  echo "  lines:  $LINES"
done
