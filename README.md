To install OS2IoT with this GitOps [template](https://github.com/os2iot/OS2IoT-helm), you need to have a
Kubernetes cluster with the following installed:

* Helm 3

This deployment documentation must be followed and executed in the exact order as described below. This is
due to some services depending on other services being ready before they can be installed.

In particular, `ArgoCD` needs to be installed before `Argo resources`, `sealed secrets` etc.

The application also requires generation of API keys, etc., and that you use sealed secrets to store them before a
given service can be installed. Some services also require keys/secrets from one service to communicate with another.

Also, because all configuration is stored in GitOps as code, you will need to update secrets and URLs to match your
domain and setup. This document will guide you through the process of setting up OS2IoT.

## Quick Reference

**Bootstrap the cluster (automated):**
```bash
./bootstrap.sh
```

**Generate and seal secrets:**
```bash
./seal-secrets.sh
```

**Generate ChirpStack API key:**
```bash
./generate-chirpstack-api-key.sh
```

**Bootstrap OS2IoT organization:**
```bash
./bootstrap-os2iot-org.sh
```

**Access ArgoCD UI:**
```bash
kubectl port-forward svc/argo-cd-argocd-server -n argo-cd 8443:443
# Open https://localhost:8443
```

**Get ArgoCD admin password:**
```bash
kubectl -n argo-cd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d; echo
```

**Access OS2IoT Frontend (requires BOTH port-forwards):**
```bash
# Terminal 1: Backend
kubectl port-forward -n os2iot-backend svc/os2iot-backend-svc 3000:3000

# Terminal 2: Frontend
kubectl port-forward -n os2iot-frontend svc/os2iot-frontend-svc 8081:8081

# Open http://localhost:8081
# Login: global-admin@os2iot.dk / hunter2
```

## Variables

Throughout this installation documentation, some values are used multiple times. These values are defined in the
following variables:

* `FQDN`: The fully qualified domain name of the cluster (e.g. aarhus.dk).
* `CERT_MAIL`: The email address used to request a certificate from Let's Encrypt.

They are used with this notation `<FQDN>` in the configuration snippets.

If you want to randomly generate keys and password, you can use this command:

```shell
echo "$(cat /dev/urandom | tr -dc 'a-f0-9' | fold -w 32 | head -n 1)"
```

## Bootstrap continuous deployment

The first step is
to [create](https://docs.github.com/en/repositories/creating-and-managing-repositories/creating-a-repository-from-a-template)
a new GitHub repository based on this [template repository](https://github.com/os2iot/OS2IoT-helm).

### Quick Start (Automated)

For a fully automated bootstrap, use the provided script:

```shell
./bootstrap.sh
```

The script will:
1. Verify all prerequisites (kubectl, helm, kubeseal)
2. Install ArgoCD
3. Install Sealed Secrets
4. Generate and seal all secrets
5. Prompt you to commit sealed secrets to Git
6. Install ArgoCD resources (app-of-apps)

**Prerequisites:**
- kubectl configured with cluster access
- helm 3 installed
- kubeseal CLI installed
- Repository URL configured in `applications/argo-cd-resources/values.yaml`

### Manual Bootstrap Sequence

If you prefer manual control, follow this exact sequence:

1. **Install ArgoCD** - GitOps controller (manual installation)
2. **Install Sealed Secrets** - Secret encryption controller (manual installation)
3. **Generate and seal secrets** - Create and encrypt all application secrets
4. **Commit sealed secrets** - Push encrypted secrets to Git
5. **Install Argo resources** - ArgoCD adopts sealed-secrets and auto-syncs all applications

This ensures the sealed-secrets controller is ready before any applications try to use SealedSecret resources.

### ArgoCD

For continuous development and using GitOps to handle updates and configuration
changes, [ArgoCD](https://argo-cd.readthedocs.io/en/stable/) needs to be bootstrapped into the cluster.

To do so, configure the domain in `applications/argo-cd/values.yaml`:

```yaml
global:
  domain: argo.<FQDN>
```

Then install ArgoCD using the following commands:

```shell
helm repo add argocd https://argoproj.github.io/argo-helm
helm repo update
cd applications/argo-cd
helm dependency build
kubectl create namespace argo-cd
helm template argo-cd . -n argo-cd | kubectl apply -f -
```

Because we are installing the ingress controller with ArgoCD, it is only accessable by using port forwarding at this
point in the installation:

```shell
kubectl port-forward svc/argo-cd-argocd-server -n argo-cd 8443:443
```

You can ensure that ArgoCD is running by opening the ingress URL:

```shell
open http://127.0.0.1:8443
```

You can log into the web-based user interface with the username `admin` and get the password with this command:

```shell
kubectl -n argo-cd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d; echo
```

Optionally, [Authentik](https://goauthentik.io/) can be installed as a single-sign-on (SSO) provider for
the internal services in the cluster. See the [Authentik](authentik.md) for more information.

### Sealed Secrets (Bootstrap)

Before installing argo-cd-resources, install sealed-secrets to enable secret encryption. This must be done before
argo-cd-resources to avoid a chicken-and-egg problem where applications try to deploy SealedSecret resources before
the controller exists.

Install sealed-secrets:

```shell
cd applications/sealed-secrets
helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets
helm repo update
helm dependency build
helm template sealed-secrets . -n kube-system | kubectl apply -f -
```

Wait for the controller to be ready:

```shell
kubectl wait --for=condition=available --timeout=300s deployment/sealed-secrets -n kube-system
```

You can verify it's running:

```shell
kubectl get deployment sealed-secrets -n kube-system
```

Now generate and seal all application secrets:

```shell
cd ../..
./seal-secrets.sh
```

The script will seal all secrets in the repository. If any secrets contain placeholder values (like `YOUR_SMTP_USERNAME`),
the script will skip them and warn you to update them first.

Once all secrets are sealed successfully, commit them to your repository:

```shell
git add applications/*/templates/*-sealed-secret.yaml
git commit -m "Add sealed secrets for applications"
git push
```

### Argo resources (applications)

Now we can install the Argo resources that define the applications and their configuration. But first, we need to
change the repository URL to our own repository.

Edit `applications/argo-cd-resources/values.yaml`:

```yaml
repoUrl: https://github.com/os2iot/<YOUR REPO>.git
```

Edit `applications/cert-manager/templates/cluster-issuer.yaml` and change the email address to your own:

```yaml
spec:
  acme:
    email: <CERT_MAIL>
 ```

Now commit the changes to the repository before the next step in Argo installation, which is to install the resources:

```shell
cd applications/argo-cd-resources/
helm template argo-cd-resources . -n argo-cd | kubectl apply -f -
```

This will install all the applications from `applications/argo-cd-resources/values.yaml` that are set to
`automated: true`. ArgoCD will:
- Adopt the existing sealed-secrets deployment and manage it going forward
- Automatically sync all applications that have their sealed secrets committed

All applications can now deploy automatically since sealed-secrets was installed first.

> **Note:** The automated `bootstrap.sh` script performs all the steps above automatically. For future deployments, consider using it to simplify the process.


## PostgreSQL Database

The platform uses a shared PostgreSQL cluster managed by CloudNativePG. The database is deployed in the `postgres` namespace and shared by ChirpStack and OS2IoT backend.

### Database Users

| User | Purpose | Database | Access |
|------|---------|----------|--------|
| `os2iot` | OS2IoT backend (owner) | os2iot | Full (owner) |
| `chirpstack` | ChirpStack LoRaWAN server | os2iot | Full (granted) |
| `mqtt` | Mosquitto broker authentication | os2iot | Read-only (SELECT) |

### Creating Database Secrets

Database credentials must be sealed for both the postgres namespace (for role creation) and the application namespaces (for deployment access).

#### 1. Create local secret files

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

#### 2. Generate secure passwords

```bash
# Generate a random 32-character hex password
echo "$(cat /dev/urandom | tr -dc 'a-f0-9' | fold -w 32 | head -n 1)"
```

#### 3. Seal the secrets

```bash
cd applications/postgres

# Seal secrets for postgres namespace (CloudNativePG roles)
kubeseal --format yaml < local-secrets/chirpstack-user-secret.yaml > templates/chirpstack-user-sealed-secret.yaml
kubeseal --format yaml < local-secrets/os2iot-user-secret.yaml > templates/os2iot-user-sealed-secret.yaml
kubeseal --format yaml < local-secrets/mqtt-user-secret.yaml > templates/mqtt-user-sealed-secret.yaml

# Seal secrets for application namespaces (deployment access)
kubeseal --format yaml < local-secrets/chirpstack-user-secret-for-chirpstack-ns.yaml > ../chirpstack/templates/postgres-cluster-chirpstack-sealed-secret.yaml
kubeseal --format yaml < local-secrets/os2iot-user-secret-for-backend-ns.yaml > ../os2iot-backend/templates/postgres-cluster-os2iot-sealed-secret.yaml
kubeseal --format yaml < local-secrets/mqtt-user-secret-for-broker-ns.yaml > ../mosquitto-broker/templates/postgres-cluster-mqtt-sealed-secret.yaml
```

#### 4. Commit the sealed secrets

Only commit the sealed secret files (`*-sealed-secret.yaml`). The `local-secrets/` directories are gitignored.

### Database Connection Details

Applications connect to the database using:

| Setting | Value |
|---------|-------|
| Host (read-write) | `postgres-cluster-rw.postgres` |
| Host (read-only) | `postgres-cluster-ro.postgres` |
| Port | `5432` |
| Database | `os2iot` |

---

## OS2IoT Backend

The OS2IoT backend requires a CA certificate and key for device authentication (MQTT client certificates).

### CA Certificate Setup

The backend needs a `ca-keys` secret containing the CA certificate and encrypted private key.

#### 1. Generate CA certificate and key

```bash
cd applications/os2iot-backend/local-secrets

# Generate CA private key (with password encryption)
openssl genrsa -aes256 -passout pass:<CA_KEY_PASSWORD> -out ca.key 4096

# Generate CA certificate (valid for 10 years)
openssl req -new -x509 -days 3650 -key ca.key -passin pass:<CA_KEY_PASSWORD> -out ca.crt \
  -subj "/CN=OS2IoT-Device-CA/O=OS2IoT/C=DK"
```

#### 2. Create the secret file

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

#### 3. Seal the secret

```bash
cd applications/os2iot-backend
kubeseal --format yaml < local-secrets/ca-keys.yaml > templates/ca-keys-sealed-secret.yaml
```

### Encryption Key Setup

The backend uses a symmetric encryption key for encrypting sensitive data in the database.

#### 1. Generate an encryption key

```bash
# Generate a random 32-character hex key
echo "$(cat /dev/urandom | tr -dc 'a-f0-9' | fold -w 32 | head -n 1)"
```

#### 2. Create the secret file

Create `applications/os2iot-backend/local-secrets/encryption-secret.yaml`:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: os2iot-backend-encryption
  namespace: os2iot-backend
type: Opaque
stringData:
  symmetricKey: "<YOUR_GENERATED_KEY>"
```

#### 3. Seal the secret

```bash
cd applications/os2iot-backend
kubeseal --format yaml < local-secrets/encryption-secret.yaml > templates/encryption-sealed-secret.yaml
```

### Email Credentials Setup

The backend uses SMTP for sending emails (password resets, notifications, etc.).

#### 1. Create the secret file

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

#### 2. Seal the secret

```bash
cd applications/os2iot-backend
kubeseal --format yaml < local-secrets/email-secret.yaml > templates/email-sealed-secret.yaml
```

#### 3. Configure SMTP host and port

Update `applications/os2iot-backend/values.yaml` with your SMTP server details:

```yaml
os2iotBackend:
  email:
    host: smtp.example.com
    port: "587"
    from: "noreply@example.com"
```

### Debugging Startup Failures

The backend runs database migrations on startup. If the container fails to start, use these commands to diagnose the issue.

#### View container logs

```bash
# View logs from current container
kubectl logs -n os2iot-backend -l app=os2iot-backend

# View logs from previous crashed container
kubectl logs -n os2iot-backend -l app=os2iot-backend --previous
```

#### View termination message

The container is configured with `terminationMessagePolicy: FallbackToLogsOnError`, which captures the last log output on failure:

```bash
kubectl describe pod -n os2iot-backend -l app=os2iot-backend
```

Look for the `Last State` section to see the termination reason and message.

#### Access npm debug logs

npm writes detailed logs to `/home/node/.npm/_logs/`. These are persisted in an emptyDir volume and can be accessed if the container is in CrashLoopBackOff:

```bash
# List available log files
kubectl exec -n os2iot-backend <pod-name> -- ls -la /home/node/.npm/_logs/

# View a specific log file
kubectl exec -n os2iot-backend <pod-name> -- cat /home/node/.npm/_logs/<log-file>.log

# Copy all npm logs locally
kubectl cp os2iot-backend/<pod-name>:/home/node/.npm/_logs ./npm-logs
```

#### Common issues

| Symptom | Likely Cause | Solution |
|---------|--------------|----------|
| SIGTERM during migrations | Startup probe timeout | Increase `failureThreshold` in deployment |
| Database connection refused | PostgreSQL not ready | Check postgres-cluster pods and secrets |
| Missing secret key | Sealed secret not deployed | Verify sealed secrets exist in namespace |

### ChirpStack API Key Setup

The OS2IoT backend requires a **Network Server (Admin) API key** from ChirpStack to communicate with the LoRaWAN network server for device management and data retrieval.

**Important**: This must be a Network Server API key (not a Tenant API key), as the backend queries gateways and devices across the entire ChirpStack instance.

#### Option 1: Automated Generation (Recommended)

A Kubernetes Job automatically generates the API key when ChirpStack is deployed.

**Using the helper script:**

After ChirpStack is deployed, run the helper script to generate and configure the API key:

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

**Retrieving from the Job logs:**

Alternatively, retrieve the API key from the Job that runs automatically during deployment:

```bash
kubectl logs job/chirpstack-create-api-key -n chirpstack
```

Look for the API key in the output (it will be a long JWT token starting with `eyJ`). Copy it and update `applications/os2iot-backend/local-secrets/chirpstack-api-key.yaml`:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: chirpstack-api-key
  namespace: os2iot-backend
type: Opaque
stringData:
  apiKey: "<PASTE_API_KEY_HERE>"
```

Then seal and commit as shown above.

#### Option 2: Manual Creation via UI

If you prefer manual control, create the API key through the ChirpStack UI:

1. Access ChirpStack:
   ```bash
   kubectl port-forward svc/chirpstack-clusterip-svc -n chirpstack 8080:8081
   # Then open http://localhost:8080
   ```

2. Login with default credentials: `admin` / `admin`

3. Navigate to **Network Server** → **API Keys** in the left menu (NOT Tenant API Keys)

4. Click **Add API key**, give it a descriptive name (e.g., "os2iot-backend"), and click **Submit**

5. **Important**: Copy the generated token immediately - it will only be shown once

6. Create `applications/os2iot-backend/local-secrets/chirpstack-api-key.yaml`:
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

7. Seal and commit:
   ```bash
   ./seal-secrets.sh
   git add applications/os2iot-backend/templates/chirpstack-api-key-sealed-secret.yaml
   git commit -m "Add ChirpStack API key"
   git push
   ```

#### Disable Automatic Job

To disable the automatic API key generation job, set `chirpstack.createApiKeyJob.enabled: false` in `applications/chirpstack/values.yaml`.

#### Verify Configuration

Ensure `applications/os2iot-backend/values.yaml` has the correct ChirpStack service URL:

```yaml
os2iotBackend:
  chirpstack:
    hostname: "chirpstack-clusterip-svc.chirpstack"
    port: "8081"
```

The backend will automatically use the `chirpstack-api-key` secret for authentication.

---

## OS2IoT Organization Bootstrap

After the backend is deployed and running, you need to create a default organization to start using OS2IoT.

### Automated Bootstrap (Recommended)

A Kubernetes Job automatically creates a default organization after the backend is deployed. This runs as an ArgoCD PostSync hook.

To verify the bootstrap job ran successfully:

```bash
kubectl logs job/os2iot-backend-bootstrap -n os2iot-backend
```

### Manual Bootstrap

If the automated bootstrap fails or you want to run it manually, use the helper script:

```bash
./bootstrap-os2iot-org.sh
```

This script will:
1. Connect to the backend API via port-forward
2. Authenticate with the default admin credentials
3. Create a "Default Organization"
4. Display the login credentials

### Default Credentials

After bootstrap, you can log in with:

- **Email:** `global-admin@os2iot.dk`
- **Password:** `hunter2`

**⚠️ IMPORTANT:** Change the default password immediately after first login!

### Access the Frontend

**IMPORTANT:** You must port-forward BOTH the frontend AND backend for the frontend to work properly:

```bash
# Terminal 1: Backend API
kubectl port-forward -n os2iot-backend svc/os2iot-backend-svc 3000:3000

# Terminal 2: Frontend
kubectl port-forward -n os2iot-frontend svc/os2iot-frontend-svc 8081:8081
```

Then open: http://localhost:8081

**Why both?** The frontend is configured to connect to `http://localhost:3000/api/v1/`. When you port-forward only the frontend, the browser cannot reach the backend API, causing CORS errors. Both port-forwards must be active simultaneously.

### Disable Automatic Bootstrap

To disable the automatic bootstrap job, set `os2iotBackend.bootstrapJob.enabled: false` in `applications/os2iot-backend/values.yaml`.

---

## Mosquitto Broker

MQTT broker for OS2IoT with PostgreSQL-based authentication. Exposes two ports:

| Port | Description |
|------|-------------|
| 8884 | MQTT with client certificate authentication |
| 8885 | MQTT with username/password authentication |

### Database Configuration

Configure the PostgreSQL connection in your values override or via ArgoCD:

```yaml
mosquittoBroker:
  database:
    host: "os2iot-postgresql"
    port: "5432"
    username: "os2iot"
    password: "your-password"
    name: "os2iot"
    sslMode: "disable"  # or "verify-ca" for production
```

### TLS Certificates

The broker requires TLS certificates for secure MQTT communication. Certificates are stored as Kubernetes Secrets and managed via SealedSecrets.

#### Required Secrets

| Secret Name | Keys | Description |
|-------------|------|-------------|
| `ca-keys` | `ca.crt` | CA certificate for client verification |
| `server-keys` | `server.crt`, `server.key` | Server certificate and private key |

#### Option 1: Generate Self-Signed Certificates (Development)

```bash
cd applications/mosquitto-broker/local-secrets

# Generate CA key and certificate (valid 10 years)
openssl genrsa -out ca.key 4096
openssl req -new -x509 -days 3650 -key ca.key -out ca.crt \
  -subj "/CN=OS2IoT-Mosquitto-CA/O=OS2IoT/C=DK"

# Generate server key and CSR
openssl genrsa -out server.key 4096
openssl req -new -key server.key -out server.csr \
  -subj "/CN=mosquitto-broker/O=OS2IoT/C=DK"

# Sign server certificate with CA (valid 10 years)
openssl x509 -req -days 3650 -in server.csr \
  -CA ca.crt -CAkey ca.key -CAcreateserial -out server.crt

# Clean up
rm server.csr ca.srl
```

#### Option 2: Use Real Certificates (Production)

For production, obtain certificates from a trusted CA or your organization's internal CA:

1. Obtain a CA certificate (or use your organization's internal CA)
2. Request a server certificate for your MQTT broker hostname
3. Place `ca.crt`, `server.crt`, and `server.key` in `applications/mosquitto-broker/local-secrets/`

#### Sealing the Certificates

After generating or obtaining certificates, create and seal the secrets:

1. Create `applications/mosquitto-broker/local-secrets/ca-keys.yaml`:

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

2. Create `applications/mosquitto-broker/local-secrets/server-keys.yaml`:

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

3. Seal the secrets:

```bash
kubeseal --format yaml < applications/mosquitto-broker/local-secrets/ca-keys.yaml > applications/mosquitto-broker/templates/ca-keys-sealed-secret.yaml
kubeseal --format yaml < applications/mosquitto-broker/local-secrets/server-keys.yaml > applications/mosquitto-broker/templates/server-keys-sealed-secret.yaml
```

4. Commit only the sealed secrets - the `local-secrets/` directory is gitignored.

#### Rotating Certificates

To rotate certificates:

1. Generate new certificates following the steps above
2. Create new sealed secrets
3. Commit and push - ArgoCD will automatically deploy the updated secrets
4. Restart the broker pod:
   ```bash
   kubectl rollout restart deployment/mosquitto-broker -n mosquitto-broker
   ```
