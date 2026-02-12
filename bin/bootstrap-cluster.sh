#!/usr/bin/env bash
set -euo pipefail
# Idempotent cluster bootstrap. Re-run when adding new services.
#
# Usage: OP_SERVICE_ACCOUNT_TOKEN=<token> ./bin/bootstrap-cluster.sh
#
# Dependencies: kubectl, openssl, htpasswd (from apache2-utils)

KUBECTL="${KUBECTL:-kubectl}"
NAMESPACE_OP="onepassword-system"

# --- Dependency check ---
for cmd in openssl htpasswd; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: $cmd is required but not found." >&2
    [[ "$cmd" == "htpasswd" ]] && echo "  On Ubuntu: sudo apt-get install apache2-utils" >&2
    exit 1
  fi
done

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

# --- Helper: generate bcrypt hash ---
bcrypt_hash() {
  htpasswd -nbBC 11 '' "$1" | cut -d: -f2
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

# NATS: store both plaintext (for clients) and bcrypt hashes (for server config)
_nats_default_pw="$(openssl rand -base64 24)"
_nats_dynamo_pw="$(openssl rand -base64 24)"
ensure_secret default nats-credentials \
  --from-literal=NATS_DEFAULT_PASSWORD="$_nats_default_pw" \
  --from-literal=NATS_DEFAULT_PASSWORD_HASH="$(bcrypt_hash "$_nats_default_pw")" \
  --from-literal=NATS_DYNAMO_PASSWORD="$_nats_dynamo_pw" \
  --from-literal=NATS_DYNAMO_PASSWORD_HASH="$(bcrypt_hash "$_nats_dynamo_pw")"
unset _nats_default_pw _nats_dynamo_pw

ensure_secret default litellm-master-key \
  --from-literal=LITELLM_MASTER_KEY="sk-$(openssl rand -hex 24)"

ensure_secret default openwebui-secret-key \
  --from-literal=OPENWEBUI_SECRET_KEY="$(openssl rand -base64 32)"
