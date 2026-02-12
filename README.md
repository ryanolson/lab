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
| phoenix | `arizephoenix/phoenix:latest` | 6006 (NodePort 30060), 4317 (gRPC) | emptyDir (postgres-backed) |
| openwebui | `ghcr.io/open-webui/open-webui:main` | 8080 (NodePort 30080) | emptyDir |

**Dependencies:** postgres → phoenix → litellm → openwebui. litellm also depends on redis (cache). Phoenix collects LLM traces from litellm via the `arize_phoenix` callback.

## Secrets Management

Two-tier approach:

1. **1Password operator** — External API keys (Google, OpenRouter). Apps declare `OnePasswordItem` CRDs referencing items in the 1Password vault. The operator syncs them to K8s Secrets.
2. **Bootstrap script** (`bin/bootstrap-cluster.sh`) — Generates random passwords for cluster-internal services. Idempotent: skips existing secrets.

### NATS bcrypt authentication

NATS warns about plaintext passwords in its config. The solution uses an `include`-based split:

- **Main config** (ConfigMap, git-tracked): contains `include /etc/nats/auth/auth.conf`
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

## LiteLLM Model Configuration

The model list lives in `apps/litellm/litellm-config.yaml` (a plain YAML file, not a K8s manifest). Kustomize's `configMapGenerator` creates a hash-suffixed ConfigMap from it, so any edit triggers an automatic pod restart.

**To add or update models:**

1. Edit `apps/litellm/litellm-config.yaml` — add/modify entries under `model_list`
2. `git commit && git push`
3. Flux auto-reconciles: new ConfigMap hash → rolling pod restart
4. Force immediate: `flux reconcile kustomization apps-litellm --with-source`

## Observability (Arize Phoenix)

Phoenix provides a trace visualization UI for LLM requests at `http://<node-ip>:30060`.

LiteLLM sends traces via the built-in `arize_phoenix` callback (configured in `litellm-config.yaml`). Traces are stored in the `phoenix` postgres database.

**Verification:**

```bash
# Phoenix pod is running
kubectl get pods -l app=phoenix

# Phoenix database exists
kubectl exec -it postgres-0 -- psql -U postgres -c "\l" | grep phoenix

# Phoenix UI is accessible
curl -s -o /dev/null -w "%{http_code}" http://<node-ip>:30060/

# Traces are being collected (check trace count via GraphQL)
curl -s -X POST http://<node-ip>:30060/graphql \
  -H "Content-Type: application/json" \
  -d '{"query":"{ projects { edges { node { name traceCount } } } }"}'

# Send a test request through litellm and verify trace appears
LITELLM_KEY=$(kubectl get secret litellm-master-key -o jsonpath='{.data.LITELLM_MASTER_KEY}' | base64 -d)
curl http://<litellm-cluster-ip>:4000/v1/chat/completions \
  -H "Authorization: Bearer $LITELLM_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"<model-name>","messages":[{"role":"user","content":"hello"}],"max_tokens":10}'
```

## Adding a New App

1. Create `apps/<name>/` with manifests and a `kustomization.yaml`
2. Add the directory to `apps/kustomization.yaml` resources
3. For external secrets: add a `OnePasswordItem` referencing the 1Password vault item
4. For internal secrets: add an `ensure_secret` call in `bin/bootstrap-cluster.sh`
5. Commit and push — Flux picks it up automatically
