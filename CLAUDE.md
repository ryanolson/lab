# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

GitOps repository for a single-node MicroK8s cluster ("lanai" at 192.168.1.237), managed by Flux CD v2.7.5. All cluster state lives in git and is reconciled automatically.

## Architecture

**Flux reconciliation order:**
```
clusters/lanai/flux-system/  →  infrastructure.yaml  →  apps.yaml
                                (prune: true, wait)     (dependsOn: infrastructure)
```

- `infrastructure/base/` — reusable components (storage, onepassword)
- `infrastructure/overlays/lanai/` — cluster-specific patches (NFS server/share)
- `apps/` — application manifests (postgres, litellm)
- `clusters/lanai/` — Flux entrypoint, wires infrastructure + apps

Infrastructure uses base/overlay Kustomize pattern. The lanai overlay directly references base components (`../../base/storage`, `../../base/onepassword`) and applies NFS patches.

## Secrets Management

Two-tier approach:

1. **1Password operator** — external API keys only. Apps declare `OnePasswordItem` CRDs referencing items in the `Development` vault. The operator syncs them to K8s Secrets.
2. **Bootstrap script** (`bin/bootstrap-cluster.sh`) — generates random passwords for cluster-internal services (postgres, etc.). Idempotent: skips existing secrets. Run with `OP_SERVICE_ACCOUNT_TOKEN=<token> ./bin/bootstrap-cluster.sh`.

Plain secret files (`*-secret.yaml`) are gitignored. Never commit raw secrets.

## Synology NFS Constraints

The NAS at 192.168.1.5 uses `all_squash`, mapping **every** UID to 1024 and GID to 100 on disk. Containers that check file ownership (like postgres) must run as UID 1024. This is why the postgres StatefulSet sets `securityContext.runAsUser: 1024`.

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
