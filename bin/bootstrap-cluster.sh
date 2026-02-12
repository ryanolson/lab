#!/usr/bin/env bash
set -euo pipefail
# Idempotent cluster bootstrap. Re-run when adding new services.
#
# Usage: OP_SERVICE_ACCOUNT_TOKEN=<token> ./bin/bootstrap-cluster.sh

KUBECTL="${KUBECTL:-kubectl}"
NAMESPACE_OP="onepassword-system"

# --- Helper: create secret only if it doesn't exist ---
ensure_secret() {
  local ns="$1" name="$2"; shift 2
  if $KUBECTL get secret "$name" -n "$ns" &>/dev/null; then
    echo "Secret $ns/$name already exists, skipping"
    return
  fi
  $KUBECTL create secret generic "$name" -n "$ns" "$@"
  echo "Created secret $ns/$name"
}

# --- 1Password operator SA token ---
$KUBECTL create namespace "$NAMESPACE_OP" --dry-run=client -o yaml | $KUBECTL apply -f -
ensure_secret "$NAMESPACE_OP" op-service-account-token \
  --from-literal=token="${OP_SERVICE_ACCOUNT_TOKEN:?Set OP_SERVICE_ACCOUNT_TOKEN}"

# --- Internal service secrets (random, cluster-local) ---
ensure_secret default postgres-credentials \
  --from-literal=POSTGRES_PASSWORD="$(openssl rand -base64 24)"

ensure_secret default redis-credentials \
  --from-literal=REDIS_PASSWORD="$(openssl rand -base64 24)"

ensure_secret default nats-credentials \
  --from-literal=NATS_DEFAULT_PASSWORD="$(openssl rand -base64 24)" \
  --from-literal=NATS_DYNAMO_PASSWORD="$(openssl rand -base64 24)" \
  --from-literal=NATS_DYNAMO_TOKEN="$(openssl rand -base64 32)"

ensure_secret default etcd-credentials \
  --from-literal=ETCD_ROOT_PASSWORD="$(openssl rand -base64 24)"

ensure_secret default litellm-master-key \
  --from-literal=LITELLM_MASTER_KEY="sk-$(openssl rand -hex 24)"

ensure_secret default openwebui-secret-key \
  --from-literal=OPENWEBUI_SECRET_KEY="$(openssl rand -base64 32)"
