# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

OS2IoT-helm is a GitOps-managed Kubernetes deployment for OS2IoT using ArgoCD. It deploys an IoT platform stack including ChirpStack (LoRaWAN network server), Mosquitto (MQTT broker), Kafka, and supporting infrastructure.

## Architecture

**GitOps Flow**: All applications are defined in `applications/argo-cd-resources/values.yaml` and deployed via ArgoCD. The `applications/argo-cd-resources/templates/applications.yaml` template generates ArgoCD Application CRs from this list.

**Application Structure**: Each application lives in `applications/<app-name>/` with:
- `Chart.yaml` - Helm chart metadata and dependencies
- `values.yaml` - Default configuration values
- `templates/` - Kubernetes manifests as Helm templates
- `local-secrets/` - Plain secrets (gitignored), sealed before committing

**Namespace Isolation**: Each application deploys to its own namespace matching the app name.

## Applications (16 total)

### Infrastructure & GitOps
| Application | Description |
|-------------|-------------|
| `argo-cd` | GitOps orchestrator |
| `argo-cd-resources` | App-of-apps pattern, defines all ArgoCD Applications and Projects |
| `cluster-resources` | Hetzner CSI driver and StorageClasses (deployed to kube-system) |
| `traefik` | Ingress controller (3 replicas, LoadBalancer) |
| `cert-manager` | TLS certificate automation via Let's Encrypt |
| `sealed-secrets` | Encrypts secrets for Git storage (deployed in sealed-secrets namespace) |

### Storage & Databases
| Application | Description |
|-------------|-------------|
| `cloudnative-pg-operator` | PostgreSQL operator for managing PostgreSQL clusters |
| `redis-operator` | Redis cluster operator |
| `postgres` | Shared PostgreSQL cluster for ChirpStack, OS2IoT backend, and other apps |

### Message Brokers
| Application | Description |
|-------------|-------------|
| `mosquitto` | MQTT broker (Eclipse Mosquitto) for ChirpStack |
| `mosquitto-broker` | MQTT broker with PostgreSQL auth for OS2IoT devices (ports 8884/8885) |
| `kafka` | Confluent Kafka broker (depends on Zookeeper) |
| `zookeeper` | Coordination service for Kafka |

### IoT Platform
| Application | Description |
|-------------|-------------|
| `chirpstack` | LoRaWAN network server (depends on PostgreSQL, Redis, MQTT) |
| `chirpstack-gateway` | Gateway bridge for LoRaWAN packets |

## Application Dependencies & Sync Waves

ArgoCD deploys applications in waves to ensure dependencies are ready before dependent apps start.

| Wave | Applications | Purpose |
|------|--------------|---------|
| 0 | `cluster-resources` | CSI driver and StorageClasses (must be first) |
| 1 | `argo-cd`, `argo-cd-resources`, `traefik`, `cert-manager`, `sealed-secrets` | Core infrastructure |
| 2 | `cloudnative-pg-operator`, `redis-operator` | Operators (CRDs and webhooks) |
| 3 | `postgres` | Database cluster (needs operator webhook ready) |
| 4 | `mosquitto`, `zookeeper` | Message brokers |
| 5 | `chirpstack`, `chirpstack-gateway`, `kafka` | Apps depending on brokers/databases |
| 6 | `mosquitto-broker`, `os2iot-backend` | Apps depending on postgres |
| 7 | `os2iot-frontend` | Frontend (depends on backend) |

**Retry Policy:** All apps have automatic retry (5 attempts, 30s-5m exponential backoff) for transient failures like webhook unavailability.

### Dependency Graph

```
cluster-resources (storage)
    ↓
cloudnative-pg-operator, redis-operator
    ↓
postgres ← chirpstack, os2iot-backend, mosquitto-broker
redis-operator ← chirpstack (Redis instance)
mosquitto ← chirpstack, chirpstack-gateway
zookeeper ← kafka
```

## Service Naming Convention

Services follow the pattern `{app-name}-svc`:
- `mosquitto-svc.mosquitto:1883`
- `kafka-svc.kafka:9092`
- `zookeeper-svc.zookeeper:2181`
- `mosquitto-broker-svc.mosquitto-broker:8884/8885`
- `postgres-cluster-rw.postgres:5432` (PostgreSQL read-write)
- `postgres-cluster-ro.postgres:5432` (PostgreSQL read-only)

## Hetzner Cloud / Cloudfleet Requirements

This deployment is designed for Kubernetes clusters running on **Hetzner Cloud** via **Cloudfleet.ai**.

### Prerequisites

1. **Hetzner API Token**: Required for the CSI driver to provision volumes
2. **Cloudfleet cluster**: Nodes must have the label `cfke.io/provider: hetzner`

### Storage Configuration

The `cluster-resources` application deploys the Hetzner CSI driver which provides:
- **StorageClass**: `hcloud-volumes` (default)
- **Volume binding**: `WaitForFirstConsumer`
- **Reclaim policy**: `Retain`

**Important limitations:**
- Hetzner volumes can only attach to Hetzner nodes
- `ReadWriteMany` is NOT supported (use `ReadWriteOnce`)
- Pods using Hetzner volumes must be scheduled on Hetzner nodes

### Setting up the Hetzner API Token

```bash
# Add the Hetzner Helm repo
helm repo add hcloud https://charts.hetzner.cloud
helm repo update

# Build dependencies
cd applications/cluster-resources
helm dependency build

# Create the secret in local-secrets/hcloud-token.yaml:
# apiVersion: v1
# kind: Secret
# metadata:
#   name: hcloud
#   namespace: kube-system
# type: Opaque
# stringData:
#   token: "YOUR_HETZNER_API_TOKEN"

# Seal the secret
kubeseal --format yaml \
  --controller-name=sealed-secrets \
  --controller-namespace=sealed-secrets \
  < local-secrets/hcloud-token.yaml > templates/hcloud-token-sealed-secret.yaml
```

## Common Commands

```bash
# Pre-create Hetzner Load Balancer (optional, for DNS setup before deployment)
hcloud context use <your-project>  # Switch to your Hetzner project first
hcloud load-balancer create --name os2iot-ingress --type lb11 --location fsn1
hcloud load-balancer describe os2iot-ingress -o format='{{.PublicNet.IPv4.IP}}'

# Bootstrap ArgoCD (first-time setup)
cd applications/argo-cd
helm dependency build
kubectl create namespace argo-cd
helm template argo-cd . -n argo-cd | kubectl apply -f -

# Install ArgoCD resources (after ArgoCD is running)
cd applications/argo-cd-resources
helm template argo-cd-resources . -n argo-cd | kubectl apply -f -

# Port-forward to ArgoCD UI
kubectl port-forward svc/argo-cd-argocd-server -n argo-cd 8443:443

# Get ArgoCD admin password
kubectl -n argo-cd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d; echo

# Seal a secret (requires kubeseal CLI and sealed-secrets controller)
kubeseal --format yaml \
  --controller-name=sealed-secrets \
  --controller-namespace=sealed-secrets \
  < local-secrets/secret.yaml > templates/sealed-secret.yaml

# Validate Helm templates locally
helm template <chart-name> applications/<chart-name>/
```

## Helm Template Conventions

**Hyphenated value keys**: When values.yaml uses hyphenated keys like `chirpstack-gateway:`, templates must use `index` function:
```yaml
# WRONG - hyphen interpreted as subtraction
{{ .Values.chirpstack-gateway.image.tag }}

# CORRECT - use index function
{{ index .Values "chirpstack-gateway" "image" "pullPolicy" }}

# PREFERRED - use camelCase in values.yaml
mosquittoBroker:
  image:
    tag: 'latest'
# Then use normal dot notation
{{ .Values.mosquittoBroker.image.tag }}
```

## Secrets Management

Secrets are stored as SealedSecrets. Workflow:
1. Create plain secret YAML in `local-secrets/` (gitignored)
2. Seal with kubeseal to `templates/<name>-sealed-secret.yaml`
3. Commit only the sealed version

Example:
```bash
cd applications/<app-name>
kubeseal --format yaml \
  --controller-name=sealed-secrets \
  --controller-namespace=sealed-secrets \
  < local-secrets/my-secret.yaml > templates/my-sealed-secret.yaml
```

## Adding New Applications

1. Create `applications/<app-name>/` with Chart.yaml, values.yaml, templates/
2. Add ArgoCD project in `applications/argo-cd-resources/templates/projects/<app-name>.yaml`
3. Add entry to `applications/argo-cd-resources/values.yaml` under `apps:`

Example project file:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: <app-name>
  namespace: argo-cd
spec:
  destinations:
  - name: in-cluster
    namespace: <app-name>
    server: https://kubernetes.default.svc
  clusterResourceWhitelist:
  - group: ''
    kind: Namespace
  namespaceResourceWhitelist:
  - group: '*'
    kind: '*'
  sourceRepos:
  - {{ .Values.repoUrl }}
```

Example apps entry:
```yaml
- name: <app-name>
  project: <app-name>
  namespace: <app-name>
  automated: true
```

## Pending Tasks

- **Seal postgres secrets**: The postgres application requires sealed secrets to be generated:
  ```bash
  cd applications/postgres
  kubeseal --format yaml \
    --controller-name=sealed-secrets \
    --controller-namespace=sealed-secrets \
    < local-secrets/chirpstack-user-secret.yaml > templates/chirpstack-user-sealed-secret.yaml
  kubeseal --format yaml \
    --controller-name=sealed-secrets \
    --controller-namespace=sealed-secrets \
    < local-secrets/chirpstack-user-secret-for-chirpstack-ns.yaml > ../chirpstack/templates/postgres-cluster-chirpstack-sealed-secret.yaml
  ```

- **mosquitto-broker database configuration**: The `mosquitto-broker` chart requires connection to the shared PostgreSQL database for MQTT authentication. Update `applications/mosquitto-broker/values.yaml`:
  ```yaml
  mosquittoBroker:
    database:
      host: "postgres-cluster-rw.postgres"
      port: "5432"
      username: "<mqtt-db-user>"
      password: "<mqtt-db-password>"
      name: "os2iot"
  ```
  The broker queries the `iot_device` table for MQTT client authentication.

- **OS2IoT backend database**: Add a Database CR and role to the postgres application for the OS2IoT backend:
  ```yaml
  # In applications/postgres/templates/os2iot-database.yaml
  apiVersion: postgresql.cnpg.io/v1
  kind: Database
  metadata:
    name: os2iot
  spec:
    name: os2iot
    owner: os2iot
    cluster:
      name: postgres-cluster
  ```

- **OS2IoT backend**: The main OS2IoT application chart needs to be created, connecting to the shared postgres database.

## Accessing the Frontend

**CRITICAL:** To access the OS2IoT frontend in local development, you MUST port-forward BOTH services simultaneously:

```bash
# Terminal 1: Backend API (required for frontend to work)
kubectl port-forward -n os2iot-backend svc/os2iot-backend-svc 3000:3000

# Terminal 2: Frontend UI
kubectl port-forward -n os2iot-frontend svc/os2iot-frontend-svc 8081:8081
```

**Why both?**
- Frontend config: `baseUrl: "http://localhost:3000/api/v1/"`
- Browser makes requests from `localhost:8081` to `localhost:3000`
- Without both port-forwards, CORS errors occur and login fails
- Both must be running simultaneously for the application to function

**Default login credentials:**
- Email: `global-admin@os2iot.dk`
- Password: `hunter2`
- **Change password immediately after first login!**

Then open: http://localhost:8081
