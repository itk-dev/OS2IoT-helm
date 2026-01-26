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
NC='\033[0m' # No Color

echo -e "${BLUE}=== ChirpStack API Key Generator ===${NC}\n"

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}Error: kubectl is not installed${NC}"
    exit 1
fi

# Check kubectl connectivity
echo -e "${BLUE}Checking Kubernetes cluster connection...${NC}"
if ! kubectl cluster-info &> /dev/null; then
    echo -e "${RED}Error: Cannot connect to Kubernetes cluster${NC}"
    echo "Make sure:"
    echo "  - kubectl is configured with the correct context"
    echo "  - The cluster is running and accessible"
    echo ""
    echo "Check connection with: kubectl cluster-info"
    exit 1
fi
echo -e "${GREEN}✓ Connected to cluster${NC}"

# Check if chirpstack namespace exists
if ! kubectl get namespace chirpstack &> /dev/null; then
    echo -e "${RED}Error: chirpstack namespace not found${NC}"
    echo "ChirpStack has not been deployed yet."
    echo "Deploy it via ArgoCD first, then run this script."
    exit 1
fi

# Find ChirpStack pod
echo -e "${BLUE}Finding ChirpStack pod...${NC}"
POD=$(kubectl get pod -n chirpstack -l app=chirpstack -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [ -z "$POD" ]; then
    echo -e "${RED}Error: ChirpStack pod not found${NC}"
    echo "ChirpStack pod is not running in the chirpstack namespace."
    echo ""
    echo "Check deployment status:"
    echo "  kubectl get pods -n chirpstack"
    echo "  kubectl get deployment -n chirpstack"
    echo ""
    echo "If ChirpStack is still deploying, wait for it to be ready and try again."
    exit 1
fi

echo -e "${GREEN}Found pod: $POD${NC}\n"

# Execute command in pod
echo -e "${BLUE}Creating Network Server API key via ChirpStack CLI...${NC}"
echo ""

# Run the command and capture output
OUTPUT=$(kubectl exec -n chirpstack "$POD" -- chirpstack --config /etc/chirpstack create-api-key --name os2iot-backend 2>&1)

# Extract JWT token (format: eyJxxxx.eyJxxxx.xxxx)
API_KEY=$(echo "$OUTPUT" | grep -oP 'eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+' | head -1)

if [ -z "$API_KEY" ]; then
    echo -e "${RED}Error: Failed to extract API key from output${NC}"
    echo "Command output:"
    echo "$OUTPUT"
    exit 1
fi

echo -e "${GREEN}✓ API Key generated successfully!${NC}"
echo ""
echo "API Key: $API_KEY"
echo ""

# Create the secret file
SECRET_FILE="applications/os2iot-backend/local-secrets/chirpstack-api-key.yaml"

# Ensure directory exists
mkdir -p "$(dirname "$SECRET_FILE")"

# Update local secret file
cat > "$SECRET_FILE" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: chirpstack-api-key
  namespace: os2iot-backend
type: Opaque
stringData:
  apiKey: "$API_KEY"
EOF

echo -e "${GREEN}✓ Secret file updated: $SECRET_FILE${NC}"
echo ""
echo -e "${BLUE}Next steps:${NC}"
echo "  1. Seal the secret:"
echo -e "     ${YELLOW}./seal-secrets.sh${NC}"
echo ""
echo "  2. Commit the sealed secret:"
echo -e "     ${YELLOW}git add applications/os2iot-backend/templates/chirpstack-api-key-sealed-secret.yaml${NC}"
echo -e "     ${YELLOW}git commit -m 'Add ChirpStack API key'${NC}"
echo -e "     ${YELLOW}git push${NC}"
echo ""
echo -e "${GREEN}Done!${NC}"
