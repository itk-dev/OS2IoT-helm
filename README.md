# OS2IoT Helm Deployment

OS2IoT is an open-source IoT device management platform developed by [OS2](https://os2.eu/) (Denmark's public sector
open-source organization). This repository provides a production-ready Kubernetes deployment using GitOps principles
with ArgoCD.

This documentation is written for DevOps engineers and system administrators who are comfortable with Kubernetes and
Helm. Following GitOps principles, all configuration lives in this Git repository - ArgoCD watches for changes and
automatically syncs them to your cluster.

## What This Deploys

| Component                     | Description                                                     |
|-------------------------------|-----------------------------------------------------------------|
| **OS2IoT Platform**           | Web-based IoT device management frontend and API backend        |
| **ChirpStack**                | LoRaWAN network server for sensor connectivity                  |
| **Mosquitto**                 | MQTT brokers (internal for ChirpStack, device-facing with auth) |
| **PostgreSQL**                | Shared database cluster via CloudNativePG                       |
| **Kafka/Zookeeper**           | Message streaming infrastructure                                |
| **Traefik**                   | Ingress controller with TLS termination                         |
| **Supporting Infrastructure** | ArgoCD, cert-manager, sealed-secrets                            |

## Architecture

```mermaid
graph TB
    subgraph "External Traffic"
        LB[Hetzner Load Balancer<br/>TCP only]
        FIP[Hetzner Floating IP<br/>78.46.245.217]
        GW[LoRaWAN Gateways]
    end

    subgraph "Ingress Layer"
        TR[Traefik<br/>hostPort 1700]
        FIPC[fip-controller<br/>assigns FIP to Traefik node]
    end

    subgraph "Applications"
        FE[os2iot-frontend]
        BE[os2iot-backend]
        CS[ChirpStack]
        CGW[ChirpStack Gateway]
    end

    subgraph "Message Brokers"
        MQ1[Mosquitto<br/>ChirpStack]
        MQ2[Mosquitto Broker<br/>Devices]
        KF[Kafka]
        ZK[Zookeeper]
    end

    subgraph "Data Layer"
        PG[(PostgreSQL)]
        RD[(Redis)]
    end

    LB -->|HTTP/HTTPS| TR
    GW -->|UDP 1700| FIP
    FIP --> TR
    FIPC -.->|Hetzner API| FIP
    TR --> FE
    TR --> BE
    TR --> CS
    TR -->|UDP| CGW
    FE --> BE
    BE --> PG
    BE --> KF
    BE --> CS
    CS --> PG
    CS --> RD
    CS --> MQ1
    CGW --> MQ1
    MQ2 --> PG
    KF --> ZK
```

---

## Table of Contents

- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Cloud Provider Configuration](#cloud-provider-configuration)
    - [Hetzner Cloud / Cloudfleet (Default)](#hetzner-cloud--cloudfleet-default)
    - [Alternative Providers](#alternative-providers)
- [Installation Guide](#installation-guide)
    - [Automated Bootstrap](#automated-bootstrap)
    - [Manual Bootstrap](#manual-bootstrap)
- [Architecture Reference](#architecture-reference)
- [Configuration Reference](#configuration-reference)
    - [PostgreSQL Database](#postgresql-database)
    - [OS2IoT Backend](#os2iot-backend)
    - [OS2IoT Organization Bootstrap](#os2iot-organization-bootstrap)
    - [Mosquitto Broker](#mosquitto-broker)
- [Operations](#operations)
- [Troubleshooting](#troubleshooting)
- [Contributing](#contributing)
- [License](#license)

---

## Prerequisites

The deployment relies on a standard Kubernetes toolchain. You'll use `kubectl` to interact with your cluster, `helm` to
package and deploy applications, and `kubeseal` to encrypt secrets so they can be safely stored in Git. Each tool plays
a specific role in the GitOps workflow.

### Required Tools

| Tool       | Minimum Version | Purpose                 |
|------------|-----------------|-------------------------|
| Kubernetes | 1.26+           | Container orchestration |
| Helm       | 3.12+           | Chart management        |
| kubectl    | 1.26+           | Cluster interaction     |
| kubeseal   | 0.24+           | Secret encryption       |
| git        | 2.0+            | GitOps workflow         |

### Cluster Requirements

| Resource        | Minimum | Recommended |
|-----------------|---------|-------------|
| Nodes           | 3       | 3+ (for HA) |
| CPU per node    | 4 cores | 8 cores     |
| Memory per node | 8 GB    | 16 GB       |
| Storage         | 50 GB   | 100 GB+     |

### Network Requirements

The following ports must be accessible from the internet:

| Port | Protocol | Purpose                                          |
|------|----------|--------------------------------------------------|
| 80   | TCP      | HTTP (redirects to HTTPS) via Load Balancer       |
| 443  | TCP      | HTTPS via Load Balancer                           |
| 1700 | UDP      | LoRaWAN gateway traffic via Floating IP (see below) |
| 8884 | TCP      | MQTT with client certificates                    |
| 8885 | TCP      | MQTT with username/password                      |

### Configuration Variables

Throughout this documentation, placeholders are used:

| Variable      | Description                 | Example             |
|---------------|-----------------------------|---------------------|
| `<FQDN>`      | Fully qualified domain name | `iot.example.com`   |
| `<CERT_MAIL>` | Email for Let's Encrypt     | `admin@example.com` |

Generate secure passwords with:

```bash
echo "$(cat /dev/urandom | tr -dc 'a-f0-9' | fold -w 32 | head -n 1)"
```

---

## Quick Start

The bootstrap process installs ArgoCD first, which then takes over and automatically deploys all other applications in
the correct order. Once complete, ArgoCD continuously monitors this Git repository and applies any changes you commit.

### Automated Bootstrap (Recommended)

```bash
# Clone and configure
git clone https://github.com/os2iot/OS2IoT-helm.git
cd OS2IoT-helm

# Edit configuration
# 1. Set your domain in applications/argo-cd/values.yaml
# 2. Set your repo URL in applications/argo-cd-resources/values.yaml
# 3. Set your email in applications/cert-manager/templates/cluster-issuer.yaml

# Bootstrap everything
./bootstrap.sh
```

### Access the Platform

#### ArgoCD UI:

```bash
kubectl port-forward svc/argo-cd-argocd-server -n argo-cd 8443:443
# Open https://localhost:8443
# Get password:
kubectl -n argo-cd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d; echo
```

#### OS2IoT Frontend (requires BOTH port-forwards):

```bash
# Terminal 1: Backend
kubectl port-forward -n os2iot-backend svc/os2iot-backend-svc 3000:3000

# Terminal 2: Frontend
kubectl port-forward -n os2iot-frontend svc/os2iot-frontend-svc 8081:8081

# Open http://localhost:8081
# Login: global-admin@os2iot.dk / hunter2
```

### Helper Scripts

| Script                             | Purpose                          |
|------------------------------------|----------------------------------|
| `./bootstrap.sh`                   | Full automated cluster bootstrap |
| `./seal-secrets.sh`                | Generate and seal all secrets    |
| `./generate-chirpstack-api-key.sh` | Generate ChirpStack API key      |
| `./bootstrap-os2iot-org.sh`        | Create default organization      |
| `./uninstall.sh`                   | Full cleanup and removal         |

These scripts automate repetitive tasks and encode best practices. Use them instead of running manual commands where
possible.

---

## Cloud Provider Configuration

Three things vary between cloud providers: how persistent storage is provisioned, how load balancers are created, and
how nodes are selected for scheduling. This deployment is pre-configured for **Hetzner Cloud via Cloudfleet.ai**, but
the sections below show how to adapt it for AWS, GCP, Azure, or bare metal environments.

### Hetzner Cloud / Cloudfleet (Default)

#### Hetzner Requirements

- **Hetzner API Token**: Required for CSI driver to provision volumes
- **Cloudfleet cluster**: Nodes must have the label `cfke.io/provider: hetzner`

#### Storage Configuration

The `cluster-resources` application deploys the Hetzner CSI driver:

- **StorageClass**: `hcloud-volumes` (default)
- **Volume binding**: `WaitForFirstConsumer`
- **Reclaim policy**: `Retain`

**Limitations:**

- Hetzner volumes can only attach to Hetzner nodes
- `ReadWriteMany` is NOT supported (use `ReadWriteOnce`)

#### Setting up the Hetzner API Token

```bash
cd applications/cluster-resources
mkdir -p local-secrets

cat > local-secrets/hcloud-token.yaml << EOF
apiVersion: v1
kind: Secret
metadata:
  name: hcloud
  namespace: kube-system
type: Opaque
stringData:
  token: "YOUR_HETZNER_API_TOKEN"
EOF

kubeseal --format yaml \
  --controller-name=sealed-secrets \
  --controller-namespace=sealed-secrets \
  < local-secrets/hcloud-token.yaml > templates/hcloud-token-sealed-secret.yaml
```

#### Load Balancer

Cloudfleet automatically provisions Hetzner Load Balancers. **Do not use Hetzner CCM** - it conflicts with Cloudfleet's
controller.

Get the LoadBalancer IP for DNS:

```bash
kubectl get svc traefik -n traefik
```

#### Floating IP for LoRaWAN UDP Traffic

Hetzner Cloud Load Balancers **do not support UDP**. Since ChirpStack Gateway Bridge requires UDP port 1700 for LoRaWAN
gateway packets, a [Hetzner Floating IP](https://docs.hetzner.com/cloud/floating-ips) is used instead.

**How it works:**

1. Traefik binds UDP 1700 directly on the node via `hostPort: 1700` (bypassing the Load Balancer)
2. A Hetzner Floating IP (`78.46.245.217` / `lora.os2iot.itkdev.dk`) is pointed at the node running Traefik
3. [`hcloud-fip-controller`](https://github.com/cbeneke/hcloud-fip-controller) automatically reassigns the Floating IP
   to a node running Traefik whenever pods are rescheduled

**Components** (deployed by `cluster-resources` in `kube-system`):

| Resource | Purpose |
|----------|---------|
| `fip-controller` Deployment (2 replicas) | Leader election ensures one active instance assigns the Floating IP to its node via the Hetzner API |
| `fip-controller-config` ConfigMap | Lists the Floating IPs to manage and how to identify node addresses |
| `fip-controller` ServiceAccount + RBAC | Permissions to list nodes and manage leader election leases |

The fip-controller pods use `requiredDuringSchedulingIgnoredDuringExecution` pod affinity to Traefik pods, ensuring
they only schedule on nodes where Traefik is listening on hostPort 1700.

**Configuration** in `applications/cluster-resources/values.yaml`:

```yaml
fipController:
  floatingIPs:
    - "78.46.245.217"    # Hetzner Floating IP for LoRaWAN
  nodeAddressType: "external"  # Match nodes by external IP
```

**Verify after deployment:**

```bash
# Check fip-controller pods are running
kubectl get pods -n kube-system -l app=fip-controller

# Check logs for successful IP assignment
kubectl logs -n kube-system -l app=fip-controller --tail=20
```

> **Note:** The fip-controller assigns the Floating IP via the Hetzner API. The node OS must also accept traffic on the
> Floating IP address. Cloudfleet may handle this automatically. If not, a privileged DaemonSet running
> `ip addr add <floating-ip>/32 dev eth0` would be needed.

#### DNS Configuration

Configure DNS A records:

```text
your-domain.com        A     <traefik-lb-ip>   # Cloudfleet LB (HTTP/HTTPS)
*.your-domain.com      A     <traefik-lb-ip>   # Cloudfleet LB (HTTP/HTTPS)
lora.your-domain.com   A     78.46.245.217     # Hetzner Floating IP (UDP 1700)
```

#### Region Configuration

All applications are pre-configured to run in **fsn1** region via nodeSelector. To change:

```yaml
# In each application's values.yaml
nodeSelector:
  topology.kubernetes.io/region: nbg1  # Change region
# Or disable region restriction:
nodeSelector: { }
```

### Alternative Providers

For non-Hetzner deployments, you need to configure three components:

| Component         | Hetzner         | AWS EKS             | GKE                 | AKS                 | Bare Metal       |
|-------------------|-----------------|---------------------|---------------------|---------------------|------------------|
| **CSI Driver**    | hcloud-csi      | aws-ebs-csi         | Built-in            | Built-in            | Longhorn/OpenEBS |
| **StorageClass**  | hcloud-volumes  | gp3                 | pd-standard         | managed-premium     | longhorn         |
| **Load Balancer** | Cloudfleet auto | AWS LB Controller   | Built-in            | Built-in            | MetalLB          |
| **Node Selector** | fsn1 region     | Remove or use zones | Remove or use zones | Remove or use zones | Remove           |

#### AWS EKS

1. **Disable Hetzner CSI** in `applications/cluster-resources/values.yaml`:

   ```yaml
   hcloud-csi:
     enabled: false
   ```

2. **Install AWS EBS CSI Driver**:

   ```bash
   eksctl create addon --name aws-ebs-csi-driver --cluster <cluster-name>
   ```

3. **Create StorageClass** and update `applications/postgres/values.yaml`:

   ```yaml
   cluster:
     storage:
       storageClass: "gp3"
   ```

4. **Install AWS Load Balancer Controller** and update Traefik:

   ```yaml
   traefik:
     service:
       annotations:
         service.beta.kubernetes.io/aws-load-balancer-type: "nlb"
   ```

5. **Remove nodeSelectors** from all applications or use availability zones.

See [AWS EBS CSI Driver documentation](https://docs.aws.amazon.com/eks/latest/userguide/ebs-csi.html) for details.

#### Google Cloud GKE

1. **Disable Hetzner CSI** (same as AWS)

2. **GKE includes CSI driver by default** - create StorageClass if needed:

   ```yaml
   storageClass: "pd-standard"
   ```

3. **Update Traefik** for GKE load balancer:

   ```yaml
   traefik:
     service:
       annotations:
         cloud.google.com/load-balancer-type: "External"
   ```

4. **Remove nodeSelectors** or use GKE zones.

See [GKE persistent volumes documentation](https://cloud.google.com/kubernetes-engine/docs/concepts/persistent-volumes)
for details.

#### Azure AKS

1. **Disable Hetzner CSI** (same as AWS)

2. **AKS includes Azure Disk CSI** - use built-in StorageClass:

   ```yaml
   storageClass: "managed-premium"
   ```

3. **Configure static IP** if needed:

   ```bash
   az network public-ip create --name os2iot-ip --resource-group <rg> --allocation-method Static
   ```

4. **Remove nodeSelectors** or use AKS zones.

See [AKS storage documentation](https://learn.microsoft.com/en-us/azure/aks/concepts-storage) for details.

#### Bare Metal / Self-Managed

1. **Install Longhorn for storage**:

   ```bash
   helm repo add longhorn https://charts.longhorn.io
   helm install longhorn longhorn/longhorn --namespace longhorn-system --create-namespace
   ```

   Update `applications/postgres/values.yaml`:

   ```yaml
   cluster:
     storage:
       storageClass: "longhorn"
   ```

2. **Install MetalLB for LoadBalancer**:

   ```bash
   kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.5/config/manifests/metallb-native.yaml
   ```

   Configure IP pool:

   ```yaml
   apiVersion: metallb.io/v1beta1
   kind: IPAddressPool
   metadata:
     name: default
     namespace: metallb-system
   spec:
     addresses:
       - 192.168.1.200-192.168.1.250  # Adjust to your network
   ---
   apiVersion: metallb.io/v1beta1
   kind: L2Advertisement
   metadata:
     name: default
     namespace: metallb-system
   ```

3. **Remove all nodeSelectors** from application values.yaml files.

See [Longhorn documentation](https://longhorn.io/docs/) and [MetalLB documentation](https://metallb.universe.tf/) for
details.

---

## Installation Guide

The installation follows a specific sequence: ArgoCD goes first because it manages all other deployments, then Sealed
Secrets so you can encrypt credentials, then your sealed secrets must be committed to Git so they're available when
ArgoCD deploys the applications that need them.

### Automated Bootstrap

The `bootstrap.sh` script handles the complete installation:

```bash
./bootstrap.sh
```

The script will:

1. Verify prerequisites (kubectl, helm, kubeseal)
2. Install ArgoCD
3. Install Sealed Secrets
4. Generate and seal all secrets
5. Prompt you to commit sealed secrets to Git
6. Install ArgoCD resources (app-of-apps)

**Before running**, configure:

- `applications/argo-cd/values.yaml` - Set `global.domain`
- `applications/argo-cd-resources/values.yaml` - Set `repoUrl`
- `applications/cert-manager/templates/cluster-issuer.yaml` - Set email

### Manual Bootstrap

If you prefer manual control, follow this exact sequence:

#### 1. Install ArgoCD

```bash
helm repo add argocd https://argoproj.github.io/argo-helm
helm repo update

cd applications/argo-cd
helm dependency build
kubectl create namespace argo-cd
helm template argo-cd . -n argo-cd | kubectl apply -f -
```

Verify ArgoCD is running:

```bash
kubectl port-forward svc/argo-cd-argocd-server -n argo-cd 8443:443
# Open https://localhost:8443
# Username: admin
# Password: kubectl -n argo-cd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

#### 2. Install Sealed Secrets

```bash
cd applications/sealed-secrets
helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets
helm repo update
helm dependency build
kubectl create namespace sealed-secrets
helm template sealed-secrets . -n sealed-secrets | kubectl apply -f -

# Wait for controller
kubectl wait --for=condition=available --timeout=300s deployment/sealed-secrets -n sealed-secrets
```

#### 3. Generate and Seal Secrets

```bash
./seal-secrets.sh
```

The script seals all secrets. If any contain placeholder values, it will warn you to update them first.

#### 4. Commit Sealed Secrets

```bash
git add applications/*/templates/*-sealed-secret.yaml
git commit -m "Add sealed secrets for applications"
git push
```

#### 5. Install ArgoCD Resources

```bash
cd applications/argo-cd-resources
helm template argo-cd-resources . -n argo-cd | kubectl apply -f -
```

ArgoCD will now automatically sync all applications.

---

## Architecture Reference

### Application Sync Waves

Sync waves ensure that dependencies are deployed before the applications that need them. For example, the PostgreSQL
operator must be running before you can create a PostgreSQL cluster, and the database must exist before applications can
connect to it. ArgoCD deploys applications in waves to enforce this ordering. All apps have automatic retry (5 attempts,
30s-5m exponential backoff) to handle transient failures like webhook unavailability during operator startup.

| Wave | Applications                                                                | Purpose                             |
|------|-----------------------------------------------------------------------------|-------------------------------------|
| 0    | `cluster-resources`                                                         | CSI driver and StorageClasses       |
| 1    | `argo-cd`, `argo-cd-resources`, `traefik`, `cert-manager`, `sealed-secrets` | Core infrastructure                 |
| 2    | `cloudnative-pg-operator`, `redis-operator`                                 | Operators (CRDs and webhooks)       |
| 3    | `postgres`                                                                  | Database cluster                    |
| 4    | `mosquitto`, `zookeeper`                                                    | Message brokers                     |
| 5    | `chirpstack`, `chirpstack-gateway`, `kafka`                                 | Apps depending on brokers/databases |
| 6    | `mosquitto-broker`, `os2iot-backend`                                        | Apps depending on postgres          |
| 7    | `os2iot-frontend`                                                           | Frontend                            |

### Service Naming

Services follow the pattern `{app-name}-svc.{namespace}`:

| Service                 | Address                                           |
|-------------------------|---------------------------------------------------|
| PostgreSQL (read-write) | `postgres-cluster-rw.postgres:5432`               |
| PostgreSQL (read-only)  | `postgres-cluster-ro.postgres:5432`               |
| Mosquitto (ChirpStack)  | `mosquitto-svc.mosquitto:1883`                    |
| Mosquitto (Devices)     | `mosquitto-broker-svc.mosquitto-broker:8884/8885` |
| Kafka                   | `kafka-svc.kafka:9092`                            |
| Zookeeper               | `zookeeper-svc.zookeeper:2181`                    |
| ChirpStack              | `chirpstack-clusterip-svc.chirpstack:8081`        |

### Ingress Resources

| Type                    | Used By             | Command                          |
|-------------------------|---------------------|----------------------------------|
| Kubernetes Ingress      | argo-cd, chirpstack | `kubectl get ingress -A`         |
| Traefik IngressRoute    | os2iot-frontend     | `kubectl get ingressroute -A`    |
| Traefik IngressRouteUDP | LoRaWAN             | `kubectl get ingressrouteudp -A` |

---

## Configuration Reference

### PostgreSQL Database

The platform uses a shared PostgreSQL cluster managed by CloudNativePG. A single database cluster simplifies operations
and backup management. Because Kubernetes enforces namespace isolation for security, each application that needs
database access requires its own copy of the credentials secret in its namespace - this is why you'll see the same
password defined in multiple secret files.

#### Database Users

| User         | Purpose                         | Database | Access             |
|--------------|---------------------------------|----------|--------------------|
| `os2iot`     | OS2IoT backend (owner)          | os2iot   | Full (owner)       |
| `chirpstack` | ChirpStack LoRaWAN server       | os2iot   | Full (granted)     |
| `mqtt`       | Mosquitto broker authentication | os2iot   | Read-only (SELECT) |

#### Creating Database Secrets

Database credentials must be sealed for both the postgres namespace (for role creation) and application namespaces (for
deployment access).

##### 1. Create local secret files

Create the following files in `applications/postgres/local-secrets/`:

**chirpstack-user-secret.yaml** (for postgres namespace):

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: postgres-cluster-chirpstack
  namespace: postgres
type: Opaque
stringData:
  username: chirpstack
  password: <GENERATE_SECURE_PASSWORD>
```

**chirpstack-user-secret-for-chirpstack-ns.yaml** (for chirpstack namespace):

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: postgres-cluster-chirpstack
  namespace: chirpstack
type: Opaque
stringData:
  username: chirpstack
  password: <SAME_PASSWORD_AS_ABOVE>
```

**os2iot-user-secret.yaml** (for postgres namespace):

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: postgres-cluster-os2iot
  namespace: postgres
type: Opaque
stringData:
  username: os2iot
  password: <GENERATE_SECURE_PASSWORD>
```

**os2iot-user-secret-for-backend-ns.yaml** (for os2iot-backend namespace):

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: postgres-cluster-os2iot
  namespace: os2iot-backend
type: Opaque
stringData:
  username: os2iot
  password: <SAME_PASSWORD_AS_ABOVE>
```

**mqtt-user-secret.yaml** (for postgres namespace):

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: postgres-cluster-mqtt
  namespace: postgres
type: Opaque
stringData:
  username: mqtt
  password: <GENERATE_SECURE_PASSWORD>
```

**mqtt-user-secret-for-broker-ns.yaml** (for mosquitto-broker namespace):

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: postgres-cluster-mqtt
  namespace: mosquitto-broker
type: Opaque
stringData:
  username: mqtt
  password: <SAME_PASSWORD_AS_ABOVE>
```

##### 2. Seal the secrets

```bash
cd applications/postgres

# Seal secrets for postgres namespace
kubeseal --format yaml \
  --controller-name=sealed-secrets \
  --controller-namespace=sealed-secrets \
  < local-secrets/chirpstack-user-secret.yaml > templates/chirpstack-user-sealed-secret.yaml
kubeseal --format yaml \
  --controller-name=sealed-secrets \
  --controller-namespace=sealed-secrets \
  < local-secrets/os2iot-user-secret.yaml > templates/os2iot-user-sealed-secret.yaml
kubeseal --format yaml \
  --controller-name=sealed-secrets \
  --controller-namespace=sealed-secrets \
  < local-secrets/mqtt-user-secret.yaml > templates/mqtt-user-sealed-secret.yaml

# Seal secrets for application namespaces
kubeseal --format yaml \
  --controller-name=sealed-secrets \
  --controller-namespace=sealed-secrets \
  < local-secrets/chirpstack-user-secret-for-chirpstack-ns.yaml > ../chirpstack/templates/postgres-cluster-chirpstack-sealed-secret.yaml
kubeseal --format yaml \
  --controller-name=sealed-secrets \
  --controller-namespace=sealed-secrets \
  < local-secrets/os2iot-user-secret-for-backend-ns.yaml > ../os2iot-backend/templates/postgres-cluster-os2iot-sealed-secret.yaml
kubeseal --format yaml \
  --controller-name=sealed-secrets \
  --controller-namespace=sealed-secrets \
  < local-secrets/mqtt-user-secret-for-broker-ns.yaml > ../mosquitto-broker/templates/postgres-cluster-mqtt-sealed-secret.yaml
```

#### Database Connection Details

| Setting           | Value                          |
|-------------------|--------------------------------|
| Host (read-write) | `postgres-cluster-rw.postgres` |
| Host (read-only)  | `postgres-cluster-ro.postgres` |
| Port              | `5432`                         |
| Database          | `os2iot`                       |

---

### OS2IoT Backend

The backend is the central API server that also acts as a certificate authority for IoT device authentication. It
requires several secrets: a CA certificate and key for signing device certificates, an encryption key for protecting
sensitive data in the database, SMTP credentials for sending notifications, and a ChirpStack API key for communicating
with the LoRaWAN network server.

#### CA Certificate Setup

The backend needs a CA certificate and key for device authentication (MQTT client certificates).

##### 1. Generate CA certificate and key

```bash
cd applications/os2iot-backend/local-secrets

# Generate CA private key (with password encryption)
openssl genrsa -aes256 -passout pass:<CA_KEY_PASSWORD> -out ca.key 4096

# Generate CA certificate (valid for 10 years)
openssl req -new -x509 -days 3650 -key ca.key -passin pass:<CA_KEY_PASSWORD> -out ca.crt \
  -subj "/CN=OS2IoT-Device-CA/O=OS2IoT/C=DK"
```

##### 2. Create the secret file

Create `applications/os2iot-backend/local-secrets/ca-keys.yaml`:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: ca-keys
  namespace: os2iot-backend
type: Opaque
stringData:
  password: "<CA_KEY_PASSWORD>"
  ca.crt: |
    -----BEGIN CERTIFICATE-----
    <contents of ca.crt>
    -----END CERTIFICATE-----
  ca.key: |
    -----BEGIN ENCRYPTED PRIVATE KEY-----
    <contents of ca.key>
    -----END ENCRYPTED PRIVATE KEY-----
```

##### 3. Seal the secret

```bash
cd applications/os2iot-backend
kubeseal --format yaml \
  --controller-name=sealed-secrets \
  --controller-namespace=sealed-secrets \
  < local-secrets/ca-keys.yaml > templates/ca-keys-sealed-secret.yaml
```

#### Encryption Key Setup

The backend uses a symmetric encryption key for encrypting sensitive data in the database.

**1. Create the secret file**

Create `applications/os2iot-backend/local-secrets/encryption-secret.yaml`:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: os2iot-backend-encryption
  namespace: os2iot-backend
type: Opaque
stringData:
  symmetricKey: "<GENERATE_32_CHAR_HEX_KEY>"
```

**2. Seal the secret**

```bash
cd applications/os2iot-backend
kubeseal --format yaml \
  --controller-name=sealed-secrets \
  --controller-namespace=sealed-secrets \
  < local-secrets/encryption-secret.yaml > templates/encryption-sealed-secret.yaml
```

#### Email Credentials Setup

The backend uses SMTP for sending emails (password resets, notifications).

**1. Create the secret file**

Create `applications/os2iot-backend/local-secrets/email-secret.yaml`:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: os2iot-backend-email
  namespace: os2iot-backend
type: Opaque
stringData:
  user: "<YOUR_SMTP_USERNAME>"
  pass: "<YOUR_SMTP_PASSWORD>"
```

**2. Seal the secret**

```bash
cd applications/os2iot-backend
kubeseal --format yaml \
  --controller-name=sealed-secrets \
  --controller-namespace=sealed-secrets \
  < local-secrets/email-secret.yaml > templates/email-sealed-secret.yaml
```

**3. Configure SMTP host and port**

Update `applications/os2iot-backend/values.yaml`:

```yaml
os2iotBackend:
  email:
    host: smtp.example.com
    port: "587"
    from: "noreply@example.com"
```

#### Debugging Startup Failures

The backend runs database migrations on startup. If the container fails to start, use these commands to diagnose the
issue.

##### View container logs

```bash
# View logs from current container
kubectl logs -n os2iot-backend -l app=os2iot-backend

# View logs from previous crashed container
kubectl logs -n os2iot-backend -l app=os2iot-backend --previous
```

##### View termination message

The container is configured with `terminationMessagePolicy: FallbackToLogsOnError`, which captures the last log output
on failure:

```bash
kubectl describe pod -n os2iot-backend -l app=os2iot-backend
```

Look for the `Last State` section to see the termination reason and message.

##### Access npm debug logs

npm writes detailed logs to `/home/node/.npm/_logs/`. These are persisted in an emptyDir volume and can be accessed if
the container is in CrashLoopBackOff:

```bash
# List available log files
kubectl exec -n os2iot-backend <pod-name> -- ls -la /home/node/.npm/_logs/

# View a specific log file
kubectl exec -n os2iot-backend <pod-name> -- cat /home/node/.npm/_logs/<log-file>.log

# Copy all npm logs locally
kubectl cp os2iot-backend/<pod-name>:/home/node/.npm/_logs ./npm-logs
```

##### Common startup issues

| Symptom                     | Likely Cause               | Solution                                  |
|-----------------------------|----------------------------|-------------------------------------------|
| SIGTERM during migrations   | Startup probe timeout      | Increase `failureThreshold` in deployment |
| Database connection refused | PostgreSQL not ready       | Check postgres-cluster pods and secrets   |
| Missing secret key          | Sealed secret not deployed | Verify sealed secrets exist in namespace  |

#### ChirpStack API Key Setup

The backend requires a **Network Server (Admin) API key** from ChirpStack to communicate with the LoRaWAN network server
for device management and data retrieval.

**Important**: This must be a Network Server API key (not a Tenant API key), as the backend queries gateways and devices
across the entire ChirpStack instance.

##### Option 1: Automated Generation (Recommended)

After ChirpStack is deployed, run the helper script:

```bash
./generate-chirpstack-api-key.sh
```

This script will:

1. Connect to the running ChirpStack pod
2. Generate a Network Server API key via ChirpStack CLI
3. Automatically create/update `applications/os2iot-backend/local-secrets/chirpstack-api-key.yaml`
4. Display next steps for sealing and committing

Then seal and commit the secret:

```bash
./seal-secrets.sh
git add applications/os2iot-backend/templates/chirpstack-api-key-sealed-secret.yaml
git commit -m "Add ChirpStack API key"
git push
```

##### Option 2: Manual Creation via UI

1. Port-forward to ChirpStack:

   ```bash
   kubectl port-forward svc/chirpstack-clusterip-svc -n chirpstack 8080:8081
   ```

2. Login at <http://localhost:8080> (admin/admin)

3. Navigate to **Network Server** → **API Keys** (NOT Tenant API Keys)

4. Create key, copy the token immediately

5. Create `applications/os2iot-backend/local-secrets/chirpstack-api-key.yaml`:

   ```yaml
   apiVersion: v1
   kind: Secret
   metadata:
     name: chirpstack-api-key
     namespace: os2iot-backend
   type: Opaque
   stringData:
     apiKey: "<YOUR_CHIRPSTACK_API_KEY>"
   ```

6. Seal and commit.

**Verify Configuration:**

Ensure `applications/os2iot-backend/values.yaml` has the correct ChirpStack service URL:

```yaml
os2iotBackend:
  chirpstack:
    hostname: "chirpstack-clusterip-svc.chirpstack"
    port: "8081"
```

The backend will automatically use the `chirpstack-api-key` secret for authentication.

---

### OS2IoT Organization Bootstrap

After the backend is deployed, create a default organization.

#### Automatic Organization Creation

A Kubernetes Job automatically creates a default organization. Verify:

```bash
kubectl logs job/os2iot-backend-bootstrap -n os2iot-backend
```

#### Manual Organization Creation

```bash
./bootstrap-os2iot-org.sh
```

#### Default Credentials

- **Email:** `global-admin@os2iot.dk`
- **Password:** `hunter2`

**Change the default password immediately after first login!**

#### Access the Frontend

**Both port-forwards are required:**

```bash
# Terminal 1: Backend API
kubectl port-forward -n os2iot-backend svc/os2iot-backend-svc 3000:3000

# Terminal 2: Frontend
kubectl port-forward -n os2iot-frontend svc/os2iot-frontend-svc 8081:8081
```

Open: <http://localhost:8081>

---

### Mosquitto Broker

This deployment includes two separate Mosquitto instances that serve different purposes. The first (`mosquitto`) handles
internal ChirpStack LoRaWAN traffic and runs without encryption since it only accepts connections from within the
cluster. The second (`mosquitto-broker`) is the external-facing broker for IoT devices, secured with TLS and
authenticating clients against the PostgreSQL database.

| Port | Description                                 |
|------|---------------------------------------------|
| 8884 | MQTT with client certificate authentication |
| 8885 | MQTT with username/password authentication  |

#### Database Configuration

Configure the PostgreSQL connection in your values override or via ArgoCD:

```yaml
mosquittoBroker:
  database:
    host: "postgres-cluster-rw.postgres"
    port: "5432"
    username: "mqtt"
    password: "your-password"
    name: "os2iot"
    sslMode: "disable"  # or "verify-ca" for production
```

#### TLS Certificates

The broker requires TLS certificates for secure MQTT communication. Certificates are stored as Kubernetes Secrets and
managed via SealedSecrets.

##### Required Secrets

| Secret Name   | Keys                       | Description                            |
|---------------|----------------------------|----------------------------------------|
| `ca-keys`     | `ca.crt`                   | CA certificate for client verification |
| `server-keys` | `server.crt`, `server.key` | Server certificate and private key     |

##### Option 1: Generate Self-Signed Certificates (Development)

```bash
cd applications/mosquitto-broker/local-secrets

# Generate CA
openssl genrsa -out ca.key 4096
openssl req -new -x509 -days 3650 -key ca.key -out ca.crt \
  -subj "/CN=OS2IoT-Mosquitto-CA/O=OS2IoT/C=DK"

# Generate server certificate
openssl genrsa -out server.key 4096
openssl req -new -key server.key -out server.csr \
  -subj "/CN=mosquitto-broker/O=OS2IoT/C=DK"
openssl x509 -req -days 3650 -in server.csr \
  -CA ca.crt -CAkey ca.key -CAcreateserial -out server.crt

rm server.csr ca.srl
```

##### Option 2: Use Real Certificates (Production)

Obtain certificates from a trusted CA and place in `applications/mosquitto-broker/local-secrets/`.

##### Seal the Certificates

Create `applications/mosquitto-broker/local-secrets/ca-keys.yaml`:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: ca-keys
  namespace: mosquitto-broker
type: Opaque
stringData:
  ca.crt: |
    -----BEGIN CERTIFICATE-----
    <your CA certificate content>
    -----END CERTIFICATE-----
```

Create `applications/mosquitto-broker/local-secrets/server-keys.yaml`:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: server-keys
  namespace: mosquitto-broker
type: Opaque
stringData:
  server.crt: |
    -----BEGIN CERTIFICATE-----
    <your server certificate content>
    -----END CERTIFICATE-----
  server.key: |
    -----BEGIN PRIVATE KEY-----
    <your server private key content>
    -----END PRIVATE KEY-----
```

Seal:

```bash
kubeseal --format yaml \
  --controller-name=sealed-secrets \
  --controller-namespace=sealed-secrets \
  < applications/mosquitto-broker/local-secrets/ca-keys.yaml > applications/mosquitto-broker/templates/ca-keys-sealed-secret.yaml
kubeseal --format yaml \
  --controller-name=sealed-secrets \
  --controller-namespace=sealed-secrets \
  < applications/mosquitto-broker/local-secrets/server-keys.yaml > applications/mosquitto-broker/templates/server-keys-sealed-secret.yaml
```

Commit only the sealed secrets - the `local-secrets/` directory is gitignored.

#### Rotating Certificates

To rotate certificates:

1. Generate new certificates following the steps above
2. Create new sealed secrets
3. Commit and push - ArgoCD will automatically deploy the updated secrets
4. Restart the broker pod:

   ```bash
   kubectl rollout restart deployment/mosquitto-broker -n mosquitto-broker
   ```

---

## Operations

Day-to-day operations focus on monitoring ArgoCD sync status and pod health. CloudNativePG handles database
maintenance (backups, failover, connection pooling) automatically, so you primarily need to watch for application-level
issues and ensure ArgoCD can reach your Git repository.

### Monitoring Application Health

```bash
# Check all ArgoCD applications
kubectl get applications -n argo-cd

# Watch sync status
watch kubectl get applications -n argo-cd

# Check all pods
kubectl get pods -A

# Check PostgreSQL cluster
kubectl get clusters -n postgres
```

### Backup Procedures

#### PostgreSQL Backup (CloudNativePG)

Enable backups in `applications/postgres/values.yaml`:

```yaml
backups:
  enabled: true
  provider: s3
  s3:
    bucket: "your-backup-bucket"
    region: "eu-west-1"
  retentionPolicy: "30d"
  schedule: "0 0 * * *"  # Daily at midnight
```

### Upgrading

1. Update chart versions in `Chart.yaml` files
2. Rebuild dependencies: `helm dependency build`
3. Commit and push - ArgoCD auto-syncs
4. Monitor: `kubectl get applications -n argo-cd`

### Uninstalling

**Full cleanup:**

```bash
./uninstall.sh
```

**Manual (preserves data):**

```bash
kubectl delete applications --all -n argo-cd
```

---

## Troubleshooting

When something goes wrong, start by running `kubectl get pods -A` to find pods that aren't Running or Ready. Once you've
identified the unhealthy pod, check its logs and describe output to understand what's failing. The table below covers
common issues, but the debug commands that follow are useful for investigating any problem.

### Common Issues

| Symptom                       | Likely Cause               | Solution                                              |
|-------------------------------|----------------------------|-------------------------------------------------------|
| Frontend shows CORS errors    | Backend not accessible     | Run BOTH backend and frontend port-forwards           |
| Pod stuck in Pending          | No storage available       | Check StorageClass and PVC status                     |
| CrashLoopBackOff              | Database not ready         | Check postgres-cluster pods in postgres namespace     |
| Sealed Secret not decrypting  | Wrong controller namespace | Verify sealed-secrets in sealed-secrets namespace     |
| ArgoCD sync failed            | Webhook not ready          | Wait and retry; check operator pods                   |
| LoadBalancer stuck in Pending | No LB provider             | Install MetalLB (bare metal) or verify cloud provider |
| LoRaWAN gateways can't connect | Floating IP not assigned  | Check `kubectl logs -n kube-system -l app=fip-controller` and verify Floating IP in Hetzner console |
| SIGTERM during migrations     | Startup probe timeout      | Increase `failureThreshold` in deployment             |

### Debug Commands

```bash
# View pod logs
kubectl logs -n <namespace> -l app=<app-name> --tail=100

# View previous crashed container logs
kubectl logs -n <namespace> -l app=<app-name> --previous

# Describe failing pod
kubectl describe pod -n <namespace> <pod-name>

# Check events
kubectl get events -n <namespace> --sort-by='.lastTimestamp'

# Test database connectivity
kubectl exec -n postgres -it postgres-cluster-1 -- psql -U postgres -c "SELECT 1"

# Test sealed-secrets controller
kubeseal --fetch-cert --controller-name=sealed-secrets --controller-namespace=sealed-secrets

# View all ingress resources
kubectl get ingress -A
kubectl get ingressroute -A
kubectl get ingressrouteudp -A
```

### Backend Debugging

```bash
# View container logs
kubectl logs -n os2iot-backend -l app=os2iot-backend

# View termination message
kubectl describe pod -n os2iot-backend -l app=os2iot-backend

# Access npm debug logs (if in CrashLoopBackOff)
kubectl exec -n os2iot-backend <pod-name> -- ls -la /home/node/.npm/_logs/
```

---

## Contributing

Before submitting changes, test your Helm templates locally with `helm template <chart-name> applications/<chart-name>/`
to catch syntax errors early.

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Test with `helm template`
5. Submit a pull request

---

## License

This project is licensed under the MPL-2.0 License. See the OS2IoT project for details.
