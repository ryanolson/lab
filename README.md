# lab

GitOps repository for a Kubernetes cluster managed by [Flux CD](https://fluxcd.io/) v2.7.5. All cluster state lives in git and is reconciled automatically.

## Architecture

Flux reconciles in dependency order:

```
clusters/<cluster>/flux-system/ → infrastructure.yaml → apps.yaml
                                  (prune: true, wait)   (dependsOn: infrastructure)
```

- **`infrastructure/base/`** — Reusable components (storage classes, 1Password operator)
- **`infrastructure/overlays/<cluster>/`** — Cluster-specific patches (NFS server/share)
- **`apps/`** — Application manifests (Kustomize)
- **`clusters/<cluster>/`** — Flux entrypoint, wires infrastructure + apps

Infrastructure uses a Kustomize base/overlay pattern. Overlays reference base components and apply environment-specific patches.

## Services

| Service | Image | Port | Storage |
|---------|-------|------|---------|
| postgres | `postgres:16` | 5432 | 10Gi PVC (`synology-nfs`, Retain) |
| redis | `redis:7-alpine` | 6379 | emptyDir |
| nats | `nats:2-alpine` | 4222 | emptyDir |
| etcd | `registry.k8s.io/etcd:3.5.16-0` | 2379 | 2Gi PVC (`synology-nfs-ephemeral`, Delete) |
| litellm | `ghcr.io/berriai/litellm:main-latest` | 4000 | none |
| openwebui | `ghcr.io/open-webui/open-webui:main` | 8080 (NodePort 30080) | emptyDir |

**Dependencies:** litellm uses postgres (database) and redis (cache). openwebui uses postgres and proxies LLM requests through litellm.

## Secrets Management

Two-tier approach:

1. **1Password operator** — External API keys (Google, OpenRouter). Apps declare `OnePasswordItem` CRDs referencing items in the 1Password vault. The operator syncs them to K8s Secrets.
2. **Bootstrap script** (`bin/bootstrap-cluster.sh`) — Generates random passwords for cluster-internal services. Idempotent: skips existing secrets.

### NATS bcrypt authentication

NATS warns about plaintext passwords in its config. The solution uses an `include`-based split:

- **Main config** (ConfigMap, git-tracked): contains `include /etc/nats-auth/auth.conf`
- **Auth config** (emptyDir, runtime-generated): an init container reads bcrypt hash env vars from the shared secret and writes `auth.conf` using `printf` (avoids shell `$` expansion of `$2a$...` hashes)

The bootstrap script generates both plaintext passwords (for client pods) and bcrypt hashes (for the NATS server) in a single `nats-credentials` secret.

**Client pod pattern** — any pod needing NATS access consumes the plaintext password:
```yaml
env:
  - name: NATS_PASSWORD
    valueFrom:
      secretKeyRef:
        name: nats-credentials
        key: NATS_DEFAULT_PASSWORD
  - name: NATS_URL
    value: "nats://default:$(NATS_PASSWORD)@nats-service:4222"
```

## Storage

Synology NFS at 192.168.1.5 with `all_squash` — every UID maps to 1024, GID to 100 on disk. Containers that check file ownership (postgres, etcd) must run as UID 1024 via `securityContext`.

| StorageClass | Reclaim Policy | Use Case |
|---|---|---|
| `synology-nfs` | Retain | Persistent data (postgres) |
| `synology-nfs-ephemeral` | Delete | Replaceable data (etcd) |

## Getting Started

```bash
# 1. Install Flux on the cluster
flux bootstrap github --owner=<org> --repository=lab --path=clusters/<cluster>

# 2. Run bootstrap to create internal secrets
OP_SERVICE_ACCOUNT_TOKEN=<token> ./bin/bootstrap-cluster.sh

# 3. Push and let Flux reconcile
git push
flux reconcile kustomization flux-system --with-source
```

Requires `htpasswd` (from `apache2-utils`) for NATS bcrypt hash generation.

## Adding a New App

1. Create `apps/<name>/` with manifests and a `kustomization.yaml`
2. Add the directory to `apps/kustomization.yaml` resources
3. For external secrets: add a `OnePasswordItem` referencing the 1Password vault item
4. For internal secrets: add an `ensure_secret` call in `bin/bootstrap-cluster.sh`
5. Commit and push — Flux picks it up automatically
