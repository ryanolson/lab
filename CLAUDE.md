# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

GitOps repository for Kubernetes clusters managed by Flux CD v2.7.5. All cluster state lives in git and is reconciled automatically. Designed as a reusable bootstrap repo — add a new overlay under `clusters/` for each environment.

## Architecture

**Flux reconciliation order:**
```
clusters/<cluster>/flux-system/  →  infrastructure.yaml  →  apps.yaml
                                    (prune: true, wait)     (dependsOn: infrastructure)
```

- `infrastructure/base/` — reusable components (storage, onepassword)
- `infrastructure/overlays/<cluster>/` — cluster-specific patches (NFS server/share)
- `apps/` — application manifests (postgres, redis, nats, etcd, litellm, openwebui)
- `clusters/<cluster>/` — Flux entrypoint, wires infrastructure + apps

Infrastructure uses base/overlay Kustomize pattern. Overlays reference base components and apply environment-specific patches.

## Services

| Service | Image | Notes |
|---------|-------|-------|
| postgres | `postgres:16` | Central database for litellm and openwebui. UID 1024 for NFS. |
| redis | `redis:7-alpine` | Cache backend for litellm. Password auth. |
| nats | `nats:2-alpine` | Message broker. Bcrypt auth via init container (see below). |
| etcd | `registry.k8s.io/etcd:3.5.16-0` | Key-value store. No auth. UID 1024 for NFS. |
| litellm | `ghcr.io/berriai/litellm:main-latest` | LLM proxy. Uses postgres, redis, external API keys. |
| openwebui | `ghcr.io/open-webui/open-webui:main` | Chat UI. Proxies through litellm. NodePort 30080. |

## Secrets Management

Two-tier approach:

1. **1Password operator** — external API keys only. Apps declare `OnePasswordItem` CRDs referencing items in the `Development` vault. The operator syncs them to K8s Secrets.
2. **Bootstrap script** (`bin/bootstrap-cluster.sh`) — generates random passwords for cluster-internal services. Idempotent: skips existing secrets. Requires `htpasswd` (from `apache2-utils`) for bcrypt hashing. Run with `OP_SERVICE_ACCOUNT_TOKEN=<token> ./bin/bootstrap-cluster.sh`.

Plain secret files (`*-secret.yaml`) are gitignored. Never commit raw secrets.

### NATS bcrypt auth pattern

NATS warns about plaintext passwords. The solution splits config into two files:

- **Main config** (ConfigMap, git-tracked): `include /etc/nats/auth/auth.conf`
- **Auth config** (emptyDir, runtime): init container reads `NATS_*_PASSWORD_HASH` env vars from the `nats-credentials` secret and writes `auth.conf` via `printf` (avoids shell `$` expansion of `$2a$...` hashes)

The bootstrap script stores both plaintext passwords (for client pods) and bcrypt hashes (for server config) in `nats-credentials`. Client pods consume the plaintext password via `secretKeyRef`.

## Synology NFS Constraints

The NAS uses `all_squash`, mapping **every** UID to 1024 and GID to 100 on disk. Containers that check file ownership (postgres, etcd) must run as UID 1024 via `securityContext.runAsUser: 1024`.

Two StorageClasses: `synology-nfs` (Retain) and `synology-nfs-ephemeral` (Delete).

## Common Commands

```bash
# Flux status
flux get kustomizations
flux get helmreleases -A

# Force reconciliation
flux reconcile kustomization flux-system --with-source
flux reconcile kustomization infrastructure
flux reconcile kustomization apps

# Check operator
kubectl get pods -n onepassword-system
kubectl get onepassworditems -A

# Postgres
kubectl exec -it postgres-0 -- psql -U postgres

# Bootstrap (run once per cluster, idempotent)
OP_SERVICE_ACCOUNT_TOKEN=<token> ./bin/bootstrap-cluster.sh
```

## Adding a New App

1. Create `apps/<name>/` with manifests and a `kustomization.yaml`
2. Add the directory to `apps/kustomization.yaml` resources
3. For external secrets: add a `OnePasswordItem` referencing the 1Password vault item
4. For internal secrets: add an `ensure_secret` line in `bin/bootstrap-cluster.sh`
5. Commit and push — Flux picks it up automatically
