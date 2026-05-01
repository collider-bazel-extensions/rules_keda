#!/usr/bin/env bash
# Same shape as health_wrapper.sh but for the kube-system slice.
set -euo pipefail

CLUSTER_NAME="cluster"

if [[ -z "${RUNFILES_DIR:-}" ]]; then
  if [[ -d "${0}.runfiles" ]]; then RUNFILES_DIR="${0}.runfiles"
  elif [[ -d "$(dirname "$0").runfiles" ]]; then RUNFILES_DIR="$(dirname "$0").runfiles"
  fi
  export RUNFILES_DIR
fi
HEALTH_BIN="${RUNFILES_DIR}/_main/tests/keda_install_bin_kubesys_health.sh"
[[ -x "$HEALTH_BIN" ]] || { echo "wrapper: keda_install_bin_kubesys_health not at $HEALTH_BIN" >&2; exit 1; }

env_file="$TEST_TMPDIR/${CLUSTER_NAME}.env"
[[ -f "$env_file" ]] || exit 1

set -a
# shellcheck disable=SC1090
source "$env_file"
set +a

exec "$HEALTH_BIN"
