#!/usr/bin/env bash
# Same shape as install_wrapper.sh but for the kube-system slice of
# the keda manifest. See defs.bzl `keda_install` docstring for why
# the install is split.
set -euo pipefail

CLUSTER_NAME="cluster"

if [[ -z "${RUNFILES_DIR:-}" ]]; then
  if [[ -d "${0}.runfiles" ]]; then RUNFILES_DIR="${0}.runfiles"
  elif [[ -d "$(dirname "$0").runfiles" ]]; then RUNFILES_DIR="$(dirname "$0").runfiles"
  fi
  export RUNFILES_DIR
fi
INSTALL_BIN="${RUNFILES_DIR}/_main/tests/keda_install_bin_kubesys.sh"
[[ -x "$INSTALL_BIN" ]] || { echo "wrapper: keda_install_bin_kubesys not at $INSTALL_BIN" >&2; exit 1; }

env_file="$TEST_TMPDIR/${CLUSTER_NAME}.env"
deadline=$(( $(date +%s) + 60 ))
while [[ ! -f "$env_file" ]]; do
  if (( $(date +%s) >= deadline )); then
    echo "kubesys_install_wrapper: kind env file never appeared at $env_file" >&2
    exit 1
  fi
  sleep 1
done

set -a
# shellcheck disable=SC1090
source "$env_file"
set +a

exec "$INSTALL_BIN"
