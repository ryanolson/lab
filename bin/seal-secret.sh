#!/usr/bin/env bash
# seal-secret.sh — Create a SealedSecret from literal key=value pairs
#
# Usage:
#   ./bin/seal-secret.sh <secret-name> <namespace> <key=value> [key=value ...]
#
# Example:
#   ./bin/seal-secret.sh postgres-credentials default POSTGRES_PASSWORD=supersecret
#   ./bin/seal-secret.sh litellm-api-keys default GOOGLE_API_KEY=AIza...

set -euo pipefail

if [ $# -lt 3 ]; then
  echo "Usage: $0 <secret-name> <namespace> <key=value> [key=value ...]" >&2
  exit 1
fi

SECRET_NAME="$1"
NAMESPACE="$2"
shift 2

# Build --from-literal arguments
LITERAL_ARGS=()
for kv in "$@"; do
  LITERAL_ARGS+=(--from-literal="$kv")
done

KUBECTL="microk8s kubectl"

$KUBECTL create secret generic "$SECRET_NAME" \
  --namespace="$NAMESPACE" \
  --dry-run=client \
  -o yaml \
  "${LITERAL_ARGS[@]}" \
  | kubeseal \
      --controller-name=sealed-secrets-controller \
      --controller-namespace=kube-system \
      --format=yaml
