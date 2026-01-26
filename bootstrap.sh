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

# Function to wait for user confirmation
wait_for_user() {
    echo ""
    read -p "Press Enter to continue or Ctrl+C to abort..."
    echo ""
}

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to check kubectl context
check_kubectl_context() {
    if ! command_exists kubectl; then
        print_error "kubectl is not installed"
        exit 1
    fi

    CONTEXT=$(kubectl config current-context 2>/dev/null || echo "none")
    echo -e "${YELLOW}Current kubectl context:${NC} ${BOLD}$CONTEXT${NC}"
    echo ""
    echo -e "${RED}${BOLD}WARNING:${NC} This script will install applications to this cluster."
    echo "Make sure you are connected to the correct Kubernetes cluster!"
    echo ""
    read -p "Continue with this context? (yes/no): " -r
    if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
        echo "Aborted."
        exit 1
    fi
}

print_header "OS2IoT Helm Bootstrap Script"

echo "This script will bootstrap OS2IoT on your Kubernetes cluster."
echo ""
echo "Bootstrap sequence:"
echo "  1. Pre-flight checks"
echo "  2. Install ArgoCD"
echo "  3. Install Sealed Secrets"
echo "  4. Generate and seal application secrets"
echo "  5. Install ArgoCD resources (app-of-apps)"
echo "  6. Generate ChirpStack API key"
echo ""

check_kubectl_context

# Pre-flight checks
print_header "Step 1: Pre-flight Checks"

print_step "Checking required tools..."

MISSING_TOOLS=()

if ! command_exists kubectl; then
    MISSING_TOOLS+=("kubectl")
fi

if ! command_exists helm; then
    MISSING_TOOLS+=("helm")
fi

if ! command_exists kubeseal; then
    MISSING_TOOLS+=("kubeseal")
fi

if [ ${#MISSING_TOOLS[@]} -gt 0 ]; then
    print_error "Missing required tools: ${MISSING_TOOLS[*]}"
    echo ""
    echo "Installation instructions:"
    echo "  kubectl: https://kubernetes.io/docs/tasks/tools/"
    echo "  helm: https://helm.sh/docs/intro/install/"
    echo "  kubeseal: https://github.com/bitnami-labs/sealed-secrets#kubeseal"
    exit 1
fi

print_success "All required tools are installed"

print_step "Checking configuration files..."

if [ ! -f "applications/argo-cd/values.yaml" ]; then
    print_error "applications/argo-cd/values.yaml not found"
    exit 1
fi

if [ ! -f "applications/argo-cd-resources/values.yaml" ]; then
    print_error "applications/argo-cd-resources/values.yaml not found"
    exit 1
fi

print_success "Configuration files found"

# Check if ArgoCD domain is configured
if grep -q "argo\.<FQDN>" applications/argo-cd/values.yaml; then
    print_warning "ArgoCD domain not configured in applications/argo-cd/values.yaml"
    echo "  Update 'domain: argo.<FQDN>' to your actual domain"
    read -p "Continue anyway? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# Check if repo URL is configured
if grep -q "os2iot/<YOUR REPO>" applications/argo-cd-resources/values.yaml; then
    print_warning "Repository URL not configured in applications/argo-cd-resources/values.yaml"
    echo "  Update 'repoUrl: https://github.com/os2iot/<YOUR REPO>.git' to your actual repository"
    read -p "Continue anyway? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

print_success "Pre-flight checks complete"

# Install ArgoCD
print_header "Step 2: Install ArgoCD"

if kubectl get namespace argo-cd >/dev/null 2>&1; then
    print_warning "ArgoCD namespace already exists"
    read -p "Skip ArgoCD installation? (Y/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        print_success "Skipping ArgoCD installation"
    else
        INSTALL_ARGOCD=true
    fi
else
    INSTALL_ARGOCD=true
fi

if [ "$INSTALL_ARGOCD" = true ]; then
    print_step "Adding ArgoCD Helm repository..."
    helm repo add argocd https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
    helm repo update >/dev/null 2>&1
    print_success "Helm repository updated"

    print_step "Building ArgoCD Helm dependencies..."
    cd applications/argo-cd
    helm dependency build
    cd "$SCRIPT_DIR"
    print_success "Dependencies built"

    print_step "Installing ArgoCD..."
    kubectl create namespace argo-cd >/dev/null 2>&1 || true
    helm template argo-cd applications/argo-cd -n argo-cd | kubectl apply -f - >/dev/null
    print_success "ArgoCD installed"

    print_step "Waiting for ArgoCD to be ready..."
    kubectl wait --for=condition=available --timeout=300s deployment/argo-cd-argocd-server -n argo-cd
    print_success "ArgoCD is ready"

    echo ""
    print_success "ArgoCD installed successfully!"
    echo ""
    echo "Access ArgoCD UI with port-forward:"
    echo -e "  ${CYAN}kubectl port-forward svc/argo-cd-argocd-server -n argo-cd 8443:443${NC}"
    echo -e "  Then open: ${CYAN}https://localhost:8443${NC}"
    echo ""
    echo "Get admin password:"
    echo -e "  ${CYAN}kubectl -n argo-cd get secret argocd-initial-admin-secret -o jsonpath=\"{.data.password}\" | base64 -d; echo${NC}"
    echo ""
    wait_for_user
fi

# Install Sealed Secrets
print_header "Step 3: Install Sealed Secrets"

if kubectl get deployment sealed-secrets -n kube-system >/dev/null 2>&1; then
    print_warning "Sealed Secrets already installed"
    read -p "Skip Sealed Secrets installation? (Y/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        print_success "Skipping Sealed Secrets installation"
    else
        INSTALL_SEALED_SECRETS=true
    fi
else
    INSTALL_SEALED_SECRETS=true
fi

if [ "$INSTALL_SEALED_SECRETS" = true ]; then
    print_step "Adding Sealed Secrets Helm repository..."
    helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets >/dev/null 2>&1 || true
    helm repo update >/dev/null 2>&1
    print_success "Helm repository updated"

    print_step "Building Sealed Secrets Helm dependencies..."
    cd applications/sealed-secrets
    helm dependency build
    cd "$SCRIPT_DIR"
    print_success "Dependencies built"

    print_step "Installing Sealed Secrets..."
    helm template sealed-secrets applications/sealed-secrets -n kube-system | kubectl apply -f - >/dev/null
    print_success "Sealed Secrets installed"

    print_step "Waiting for Sealed Secrets controller to be ready..."
    kubectl wait --for=condition=available --timeout=300s deployment/sealed-secrets -n kube-system

    # Also wait for the pod to be ready (deployment can be available but pod not fully ready)
    kubectl wait --for=condition=ready --timeout=60s pod -l app.kubernetes.io/name=sealed-secrets -n kube-system

    # Give it a few more seconds for the controller API to be fully ready
    sleep 5

    # Test kubeseal connectivity
    print_step "Testing kubeseal connectivity..."
    if kubectl get service sealed-secrets -n kube-system >/dev/null 2>&1; then
        print_success "Sealed Secrets service is accessible"
    else
        print_error "Cannot access sealed-secrets service in kube-system namespace"
        echo "This is unexpected - the deployment is ready but the service is not found."
        exit 1
    fi

    print_success "Sealed Secrets controller is ready"

    echo ""
    print_success "Sealed Secrets installed successfully!"
    echo ""
fi

# Generate and seal secrets
print_header "Step 4: Generate and Seal Secrets"

print_step "Checking if secrets need to be generated..."

if [ ! -f "applications/os2iot-backend/local-secrets/ca-keys.yaml" ]; then
    print_warning "OS2IoT backend secrets not found"
    echo "Some secrets are missing and need to be generated."
    echo "The seal-secrets.sh script will handle this."
    echo ""
fi

print_step "Running seal-secrets.sh..."
echo ""

if ./seal-secrets.sh; then
    echo ""
    print_success "Secrets sealed successfully!"
else
    echo ""
    print_error "Secret sealing failed"
    echo ""
    echo "Common issues:"
    echo "  - Placeholder values (YOUR_*) still in secret files"
    echo "  - Sealed Secrets controller not ready"
    echo "  - Missing local-secrets files"
    echo ""
    echo "Fix the issues and run './seal-secrets.sh' manually, then continue."
    exit 1
fi

echo ""
print_warning "IMPORTANT: Commit sealed secrets to Git before proceeding!"
echo ""
echo "Run these commands:"
echo -e "  ${CYAN}git add applications/*/templates/*-sealed-secret.yaml${NC}"
echo -e "  ${CYAN}git commit -m \"Add sealed secrets for applications\"${NC}"
echo -e "  ${CYAN}git push${NC}"
echo ""
read -p "Have you committed and pushed the sealed secrets? (yes/no): " -r
if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
    echo "Please commit and push the sealed secrets, then run this script again."
    exit 1
fi

# Install ArgoCD resources
print_header "Step 5: Install ArgoCD Resources"

print_step "Installing ArgoCD resources (app-of-apps)..."
helm template argo-cd-resources applications/argo-cd-resources -n argo-cd | kubectl apply -f - >/dev/null
print_success "ArgoCD resources installed"

print_step "Waiting for applications to sync..."
sleep 5

echo ""
print_success "ArgoCD will now automatically sync all applications!"
echo ""
echo "Monitor progress:"
echo -e "  ${CYAN}kubectl get applications -n argo-cd${NC}"
echo -e "  ${CYAN}watch kubectl get applications -n argo-cd${NC}"
echo ""
echo "Or use the ArgoCD UI:"
echo -e "  ${CYAN}kubectl port-forward svc/argo-cd-argocd-server -n argo-cd 8443:443${NC}"
echo ""

# Generate ChirpStack API Key
print_header "Step 6: Generate ChirpStack API Key"

echo "The OS2IoT backend requires a Network Server API key from ChirpStack."
echo ""

print_step "Waiting for ChirpStack to deploy..."
# Wait for ChirpStack deployment
kubectl wait --for=condition=available --timeout=300s deployment/chirpstack -n chirpstack 2>/dev/null || {
    print_warning "ChirpStack deployment not found or not ready yet"
    echo "It may still be syncing. You can generate the API key later with:"
    echo -e "  ${CYAN}./generate-chirpstack-api-key.sh${NC}"
    echo ""
}

# Check if the Job is enabled
if kubectl get job chirpstack-create-api-key -n chirpstack >/dev/null 2>&1; then
    print_step "Waiting for API key generation job to complete..."
    kubectl wait --for=condition=complete --timeout=120s job/chirpstack-create-api-key -n chirpstack 2>/dev/null || {
        print_warning "Job not complete yet. Continuing..."
    }
fi

echo ""
echo "You have two options to generate the ChirpStack API key:"
echo ""
echo "Option 1 (Recommended): Use the helper script"
echo -e "  ${CYAN}./generate-chirpstack-api-key.sh${NC}"
echo ""
echo "Option 2: Retrieve from Job logs"
echo -e "  ${CYAN}kubectl logs job/chirpstack-create-api-key -n chirpstack${NC}"
echo "  Then manually update applications/os2iot-backend/local-secrets/chirpstack-api-key.yaml"
echo ""

read -p "Would you like to run the helper script now? (Y/n): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Nn]$ ]]; then
    print_step "Running generate-chirpstack-api-key.sh..."
    echo ""

    if ./generate-chirpstack-api-key.sh; then
        echo ""
        print_success "ChirpStack API key generated and secret file updated!"

        print_step "Sealing the ChirpStack API key..."
        cd applications/os2iot-backend
        if kubeseal --format yaml --controller-name=sealed-secrets --controller-namespace=kube-system \
            < local-secrets/chirpstack-api-key.yaml \
            > templates/chirpstack-api-key-sealed-secret.yaml 2>/dev/null; then
            cd ../..
            print_success "ChirpStack API key sealed!"

            echo ""
            print_warning "Don't forget to commit the sealed secret:"
            echo -e "  ${CYAN}git add applications/os2iot-backend/templates/chirpstack-api-key-sealed-secret.yaml${NC}"
            echo -e "  ${CYAN}git commit -m 'Add ChirpStack API key'${NC}"
            echo -e "  ${CYAN}git push${NC}"
            echo ""
        else
            cd ../..
            print_error "Failed to seal the API key"
            echo "You can seal it manually later with: ./seal-secrets.sh"
            echo ""
        fi
    else
        print_warning "API key generation failed or was skipped"
        echo "You can run it manually later: ./generate-chirpstack-api-key.sh"
        echo ""
    fi
else
    print_warning "Skipped API key generation"
    echo "Generate it later with: ./generate-chirpstack-api-key.sh"
    echo ""
fi

# Final summary
print_header "Bootstrap Complete!"

echo "Next steps:"
echo ""
echo "1. Monitor application deployment:"
echo -e "   ${CYAN}kubectl get applications -n argo-cd${NC}"
echo ""
echo "2. Access ArgoCD UI:"
echo -e "   ${CYAN}kubectl port-forward svc/argo-cd-argocd-server -n argo-cd 8443:443${NC}"
echo -e "   Open: ${CYAN}https://localhost:8443${NC}"
echo ""
echo "3. Update placeholder secrets (if any):"
echo "   - applications/os2iot-backend/local-secrets/email-secret.yaml"
echo "   Then run './seal-secrets.sh' and commit the changes."
echo ""
echo "4. Generate ChirpStack API key (if not done yet):"
echo -e "   ${CYAN}./generate-chirpstack-api-key.sh${NC}"
echo ""
echo "5. Check application health:"
echo -e "   ${CYAN}kubectl get pods --all-namespaces${NC}"
echo ""

print_success "Bootstrap completed successfully!"
