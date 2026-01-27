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

echo -e "${BLUE}=== OS2IoT Secret Sealing Script ===${NC}\n"

# Check if kubeseal is installed
if ! command -v kubeseal &> /dev/null; then
    echo -e "${RED}Error: kubeseal is not installed${NC}"
    echo "Install it with: brew install kubeseal (macOS) or see https://github.com/bitnami-labs/sealed-secrets"
    exit 1
fi

# Check if sealed-secrets controller is running
if ! kubectl get deployment -n sealed-secrets sealed-secrets &> /dev/null; then
    echo -e "${YELLOW}Warning: sealed-secrets controller not found in sealed-secrets namespace${NC}"
    echo "Make sure sealed-secrets is deployed before sealing secrets"
    read -p "Continue anyway? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# Counter for tracking progress
TOTAL=0
SUCCESS=0
SKIPPED=0
FAILED=0

# Function to seal a secret
seal_secret() {
    local input_file=$1
    local output_file=$2
    local description=$3

    TOTAL=$((TOTAL + 1))

    if [ ! -f "$input_file" ]; then
        echo -e "${YELLOW}⊘ Skipped${NC}: $description (file not found: $input_file)"
        SKIPPED=$((SKIPPED + 1))
        return
    fi

    # Check if the input file contains placeholder values
    if grep -q "YOUR_" "$input_file" 2>/dev/null; then
        echo -e "${YELLOW}⊘ Skipped${NC}: $description (contains placeholder values - update first)"
        SKIPPED=$((SKIPPED + 1))
        return
    fi

    echo -n "Sealing: $description... "

    ERROR_OUTPUT=$(mktemp)
    if kubeseal --format yaml --controller-name=sealed-secrets --controller-namespace=sealed-secrets < "$input_file" > "$output_file" 2>"$ERROR_OUTPUT"; then
        echo -e "${GREEN}✓${NC}"
        SUCCESS=$((SUCCESS + 1))
    else
        echo -e "${RED}✗ Failed${NC}"
        if [ -s "$ERROR_OUTPUT" ]; then
            echo -e "${RED}  Error: $(cat "$ERROR_OUTPUT")${NC}"
        fi
        FAILED=$((FAILED + 1))
    fi
    rm -f "$ERROR_OUTPUT"
}

echo -e "${BLUE}PostgreSQL Secrets${NC}"
echo "==================="
cd "$SCRIPT_DIR/applications/postgres"

seal_secret \
    "local-secrets/chirpstack-user-secret.yaml" \
    "templates/chirpstack-user-sealed-secret.yaml" \
    "ChirpStack user (postgres namespace)"

seal_secret \
    "local-secrets/os2iot-user-secret.yaml" \
    "templates/os2iot-user-sealed-secret.yaml" \
    "OS2IoT user (postgres namespace)"

seal_secret \
    "local-secrets/mqtt-user-secret.yaml" \
    "templates/mqtt-user-sealed-secret.yaml" \
    "MQTT user (postgres namespace)"

seal_secret \
    "local-secrets/chirpstack-user-secret-for-chirpstack-ns.yaml" \
    "../chirpstack/templates/postgres-cluster-chirpstack-sealed-secret.yaml" \
    "ChirpStack user (chirpstack namespace)"

seal_secret \
    "local-secrets/os2iot-user-secret-for-backend-ns.yaml" \
    "../os2iot-backend/templates/postgres-cluster-os2iot-sealed-secret.yaml" \
    "OS2IoT user (os2iot-backend namespace)"

seal_secret \
    "local-secrets/mqtt-user-secret-for-broker-ns.yaml" \
    "../mosquitto-broker/templates/postgres-cluster-mqtt-sealed-secret.yaml" \
    "MQTT user (mosquitto-broker namespace)"

echo ""
echo -e "${BLUE}OS2IoT Backend Secrets${NC}"
echo "======================"
cd "$SCRIPT_DIR/applications/os2iot-backend"

seal_secret \
    "local-secrets/ca-keys.yaml" \
    "templates/ca-keys-sealed-secret.yaml" \
    "CA certificate and key"

seal_secret \
    "local-secrets/encryption-secret.yaml" \
    "templates/encryption-sealed-secret.yaml" \
    "Database encryption key"

seal_secret \
    "local-secrets/email-secret.yaml" \
    "templates/email-sealed-secret.yaml" \
    "SMTP credentials"

seal_secret \
    "local-secrets/chirpstack-api-key.yaml" \
    "templates/chirpstack-api-key-sealed-secret.yaml" \
    "ChirpStack API key"

echo ""
echo -e "${BLUE}Mosquitto Broker Secrets${NC}"
echo "========================"
cd "$SCRIPT_DIR/applications/mosquitto-broker"

seal_secret \
    "local-secrets/ca-keys.yaml" \
    "templates/ca-keys-sealed-secret.yaml" \
    "CA certificate"

seal_secret \
    "local-secrets/server-keys.yaml" \
    "templates/server-keys-sealed-secret.yaml" \
    "Server certificate and key"

echo ""
echo -e "${BLUE}=== Summary ===${NC}"
echo "Total:   $TOTAL"
echo -e "${GREEN}Success: $SUCCESS${NC}"
echo -e "${YELLOW}Skipped: $SKIPPED${NC}"
if [ $FAILED -gt 0 ]; then
    echo -e "${RED}Failed:  $FAILED${NC}"
fi

if [ $SKIPPED -gt 0 ]; then
    echo ""
    echo -e "${YELLOW}Note: Some secrets were skipped because they contain placeholder values.${NC}"
    echo "Update the following files before sealing:"
    echo "  - applications/os2iot-backend/local-secrets/email-secret.yaml"
    echo "  - applications/os2iot-backend/local-secrets/chirpstack-api-key.yaml"
fi

if [ $FAILED -gt 0 ]; then
    echo ""
    echo -e "${RED}Some secrets failed to seal. Check the errors above.${NC}"
    exit 1
fi

echo ""
echo -e "${GREEN}✓ Secret sealing complete!${NC}"
echo "The sealed secrets are ready to commit to your repository."
