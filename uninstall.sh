#!/bin/bash
set -e

# Get the directory where this script is located
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Function to print section headers
print_header() {
    echo ""
    echo -e "${BOLD}${BLUE}==================================================================${NC}"
    echo -e "${BOLD}${BLUE}  $1${NC}"
    echo -e "${BOLD}${BLUE}==================================================================${NC}"
    echo ""
}

# Function to print step info
print_step() {
    echo -e "${CYAN}➜${NC} ${BOLD}$1${NC}"
}

# Function to print success
print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

# Function to print warning
print_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

# Function to print error
print_error() {
    echo -e "${RED}✗${NC} $1"
}

# Function to delete namespace if it exists
delete_namespace() {
    local ns=$1
    if kubectl get namespace "$ns" >/dev/null 2>&1; then
        print_step "Deleting namespace: $ns"
        kubectl delete namespace "$ns" --timeout=120s 2>/dev/null || {
            print_warning "Namespace $ns deletion timed out, forcing..."
            kubectl delete namespace "$ns" --force --grace-period=0 2>/dev/null || true
        }
        print_success "Deleted namespace: $ns"
    else
        echo "  Namespace $ns not found (skipping)"
    fi
}

# Function to delete ArgoCD application if it exists
delete_argo_app() {
    local app=$1
    if kubectl get application "$app" -n argo-cd >/dev/null 2>&1; then
        print_step "Deleting ArgoCD application: $app"
        # Remove finalizers first to prevent stuck deletions
        kubectl patch application "$app" -n argo-cd -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
        kubectl delete application "$app" -n argo-cd --timeout=60s 2>/dev/null || true
        print_success "Deleted application: $app"
    fi
}

print_header "OS2IoT Helm Uninstall Script"

echo -e "${RED}${BOLD}WARNING: This script will delete OS2IoT and all its data!${NC}"
echo ""
echo "This will remove:"
echo "  - All ArgoCD applications"
echo "  - All application namespaces and their resources"
echo "  - ArgoCD itself"
echo "  - Sealed Secrets controller"
echo "  - All persistent data (databases, volumes)"
echo ""

# Check kubectl context
CONTEXT=$(kubectl config current-context 2>/dev/null || echo "none")
echo -e "${YELLOW}Current kubectl context:${NC} ${BOLD}$CONTEXT${NC}"
echo ""

read -p "Are you sure you want to uninstall OS2IoT? Type 'yes' to confirm: " -r
if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
    echo "Aborted."
    exit 1
fi

echo ""
read -p "This will DELETE ALL DATA. Type 'DELETE' to confirm: " -r
if [[ ! $REPLY == "DELETE" ]]; then
    echo "Aborted."
    exit 1
fi

# List of application namespaces (in reverse dependency order)
APP_NAMESPACES=(
    "os2iot-frontend"
    "os2iot-backend"
    "chirpstack-gateway"
    "chirpstack"
    "mosquitto-broker"
    "mosquitto"
    "kafka"
    "zookeeper"
    "postgres"
    "redis-operator"
    "cloudnative-pg-operator"
    "cert-manager"
    "traefik"
    "sealed-secrets"
)

# List of ArgoCD applications (same order)
ARGO_APPS=(
    "os2iot-frontend"
    "os2iot-backend"
    "chirpstack-gateway"
    "chirpstack"
    "mosquitto-broker"
    "mosquitto"
    "kafka"
    "zookeeper"
    "postgres"
    "redis-operator"
    "cloudnative-pg-operator"
    "cert-manager"
    "traefik"
    "sealed-secrets"
    "argo-cd-resources"
    "argo-cd"
)

# Step 1: Delete ArgoCD Applications
print_header "Step 1: Delete ArgoCD Applications"

if kubectl get namespace argo-cd >/dev/null 2>&1; then
    # First, disable auto-sync on all applications to prevent recreation
    print_step "Disabling auto-sync on all applications..."
    for app in "${ARGO_APPS[@]}"; do
        kubectl patch application "$app" -n argo-cd \
            -p '{"spec":{"syncPolicy":null}}' --type=merge 2>/dev/null || true
    done
    print_success "Auto-sync disabled"

    # Delete applications
    for app in "${ARGO_APPS[@]}"; do
        delete_argo_app "$app"
    done
else
    print_warning "ArgoCD namespace not found, skipping application deletion"
fi

# Step 2: Delete CRDs that might block namespace deletion
print_header "Step 2: Clean up Custom Resources"

# Delete CloudNativePG clusters
if kubectl get clusters.postgresql.cnpg.io -A >/dev/null 2>&1; then
    print_step "Deleting PostgreSQL clusters..."
    kubectl delete clusters.postgresql.cnpg.io --all -A --timeout=120s 2>/dev/null || true
    print_success "PostgreSQL clusters deleted"
fi

# Delete Redis instances
if kubectl get redis.redis.redis.opstreelabs.in -A >/dev/null 2>&1; then
    print_step "Deleting Redis instances..."
    kubectl delete redis.redis.redis.opstreelabs.in --all -A --timeout=60s 2>/dev/null || true
    print_success "Redis instances deleted"
fi

# Delete Certificates
if kubectl get certificates.cert-manager.io -A >/dev/null 2>&1; then
    print_step "Deleting cert-manager certificates..."
    kubectl delete certificates.cert-manager.io --all -A --timeout=60s 2>/dev/null || true
    kubectl delete clusterissuers.cert-manager.io --all --timeout=60s 2>/dev/null || true
    print_success "Certificates deleted"
fi

# Delete SealedSecrets
if kubectl get sealedsecrets.bitnami.com -A >/dev/null 2>&1; then
    print_step "Deleting SealedSecrets..."
    kubectl delete sealedsecrets.bitnami.com --all -A --timeout=60s 2>/dev/null || true
    print_success "SealedSecrets deleted"
fi

# Step 3: Delete Application Namespaces
print_header "Step 3: Delete Application Namespaces"

for ns in "${APP_NAMESPACES[@]}"; do
    delete_namespace "$ns"
done

# Step 4: Delete ArgoCD
print_header "Step 4: Delete ArgoCD"

if kubectl get namespace argo-cd >/dev/null 2>&1; then
    print_step "Deleting ArgoCD namespace..."

    # Delete all ArgoCD resources first
    kubectl delete appprojects --all -n argo-cd --timeout=60s 2>/dev/null || true
    kubectl delete applications --all -n argo-cd --timeout=60s 2>/dev/null || true

    # Delete the namespace
    kubectl delete namespace argo-cd --timeout=120s 2>/dev/null || {
        print_warning "ArgoCD namespace deletion timed out, forcing..."
        # Remove finalizers from any stuck resources
        kubectl get applications -n argo-cd -o name 2>/dev/null | xargs -I {} kubectl patch {} -n argo-cd -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
        kubectl delete namespace argo-cd --force --grace-period=0 2>/dev/null || true
    }
    print_success "ArgoCD deleted"
else
    print_warning "ArgoCD namespace not found"
fi

# Step 5: Clean up cluster-wide resources
print_header "Step 5: Clean up Cluster-wide Resources"

# Delete CRDs (optional, but thorough)
print_step "Deleting Custom Resource Definitions..."

# CloudNativePG CRDs
kubectl delete crd backups.postgresql.cnpg.io 2>/dev/null || true
kubectl delete crd clusters.postgresql.cnpg.io 2>/dev/null || true
kubectl delete crd poolers.postgresql.cnpg.io 2>/dev/null || true
kubectl delete crd scheduledbackups.postgresql.cnpg.io 2>/dev/null || true

# Redis Operator CRDs
kubectl delete crd redis.redis.redis.opstreelabs.in 2>/dev/null || true
kubectl delete crd redisclusters.redis.redis.opstreelabs.in 2>/dev/null || true
kubectl delete crd redisreplications.redis.redis.opstreelabs.in 2>/dev/null || true
kubectl delete crd redissentinels.redis.redis.opstreelabs.in 2>/dev/null || true

# Cert-manager CRDs
kubectl delete crd certificaterequests.cert-manager.io 2>/dev/null || true
kubectl delete crd certificates.cert-manager.io 2>/dev/null || true
kubectl delete crd challenges.acme.cert-manager.io 2>/dev/null || true
kubectl delete crd clusterissuers.cert-manager.io 2>/dev/null || true
kubectl delete crd issuers.cert-manager.io 2>/dev/null || true
kubectl delete crd orders.acme.cert-manager.io 2>/dev/null || true

# Sealed Secrets CRDs
kubectl delete crd sealedsecrets.bitnami.com 2>/dev/null || true

# Traefik CRDs
kubectl delete crd ingressroutes.traefik.io 2>/dev/null || true
kubectl delete crd ingressroutetcps.traefik.io 2>/dev/null || true
kubectl delete crd ingressrouteudps.traefik.io 2>/dev/null || true
kubectl delete crd middlewares.traefik.io 2>/dev/null || true
kubectl delete crd middlewaretcps.traefik.io 2>/dev/null || true
kubectl delete crd serverstransports.traefik.io 2>/dev/null || true
kubectl delete crd tlsoptions.traefik.io 2>/dev/null || true
kubectl delete crd tlsstores.traefik.io 2>/dev/null || true
kubectl delete crd traefikservices.traefik.io 2>/dev/null || true

# ArgoCD CRDs
kubectl delete crd applications.argoproj.io 2>/dev/null || true
kubectl delete crd applicationsets.argoproj.io 2>/dev/null || true
kubectl delete crd appprojects.argoproj.io 2>/dev/null || true

print_success "CRDs cleaned up"

# Delete ClusterRoles and ClusterRoleBindings
print_step "Cleaning up ClusterRoles and ClusterRoleBindings..."
kubectl delete clusterrole -l app.kubernetes.io/part-of=argocd 2>/dev/null || true
kubectl delete clusterrolebinding -l app.kubernetes.io/part-of=argocd 2>/dev/null || true
kubectl delete clusterrole -l app.kubernetes.io/name=sealed-secrets 2>/dev/null || true
kubectl delete clusterrolebinding -l app.kubernetes.io/name=sealed-secrets 2>/dev/null || true
kubectl delete clusterrole -l app.kubernetes.io/name=cert-manager 2>/dev/null || true
kubectl delete clusterrolebinding -l app.kubernetes.io/name=cert-manager 2>/dev/null || true
kubectl delete clusterrole -l app.kubernetes.io/name=traefik 2>/dev/null || true
kubectl delete clusterrolebinding -l app.kubernetes.io/name=traefik 2>/dev/null || true
kubectl delete clusterrole secrets-unsealer 2>/dev/null || true
kubectl delete clusterrolebinding secrets-unsealer 2>/dev/null || true
print_success "ClusterRoles cleaned up"

# Delete IngressClass
print_step "Cleaning up IngressClass..."
kubectl delete ingressclass traefik 2>/dev/null || true
print_success "IngressClass cleaned up"

# Step 6: Clean up PVs (if any orphaned)
print_header "Step 6: Clean up Persistent Volumes"

print_step "Checking for orphaned PersistentVolumes..."
ORPHANED_PVS=$(kubectl get pv -o jsonpath='{.items[?(@.status.phase=="Released")].metadata.name}' 2>/dev/null || true)
if [ -n "$ORPHANED_PVS" ]; then
    print_warning "Found orphaned PVs: $ORPHANED_PVS"
    read -p "Delete orphaned PVs? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        for pv in $ORPHANED_PVS; do
            kubectl delete pv "$pv" 2>/dev/null || true
        done
        print_success "Orphaned PVs deleted"
    fi
else
    print_success "No orphaned PVs found"
fi

# Final summary
print_header "Uninstall Complete!"

echo "The following have been removed:"
echo "  - All ArgoCD applications"
echo "  - All application namespaces"
echo "  - ArgoCD"
echo "  - Custom Resource Definitions"
echo "  - Cluster-wide RBAC resources"
echo ""

# Check for any remaining namespaces
REMAINING=$(kubectl get namespaces -o name | grep -E "(os2iot|chirpstack|mosquitto|kafka|zookeeper|postgres|redis|cert-manager|traefik|sealed-secrets|argo-cd)" || true)
if [ -n "$REMAINING" ]; then
    print_warning "Some namespaces may still be terminating:"
    echo "$REMAINING"
    echo ""
    echo "Run 'kubectl get namespaces' to check status"
fi

print_success "Uninstall completed successfully!"
echo ""
echo "You can now run './bootstrap.sh' to reinstall OS2IoT."
