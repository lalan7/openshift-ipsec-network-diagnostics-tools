#!/bin/bash
# E2E tests for run-ipsec-diagnostics.sh
# Requires cluster connection and test-config.env
# Tests actual script execution on real nodes

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/../run-ipsec-diagnostics.sh"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

PASS=0
FAIL=0
SKIP=0

# ============================================================
# Load test configuration
# ============================================================
if [[ -f "$SCRIPT_DIR/test-config.env" ]]; then
    source "$SCRIPT_DIR/test-config.env"
else
    echo -e "${RED}ERROR:${NC} tests/test-config.env not found"
    echo ""
    echo "Create it from the template:"
    echo "  cp tests/test-config.env.example tests/test-config.env"
    echo "  # Edit with your cluster nodes"
    exit 1
fi

# Required variables
NODE1="${TEST_NODE1:?TEST_NODE1 not set in test-config.env}"
NODE2="${TEST_NODE2:?TEST_NODE2 not set in test-config.env}"
RETIS_NODE="${TEST_RETIS_NODE:-$NODE2}"
DURATION="${TEST_DURATION:-10}"
SKIP_RETIS="${TEST_SKIP_RETIS:-false}"

test_case() {
    local name="$1"
    local result="$2"
    if [[ "$result" == "pass" ]]; then
        echo -e "${GREEN}✓${NC} $name"
        PASS=$((PASS + 1))
    elif [[ "$result" == "skip" ]]; then
        echo -e "${YELLOW}○${NC} $name (skipped)"
        SKIP=$((SKIP + 1))
    else
        echo -e "${RED}✗${NC} $name"
        FAIL=$((FAIL + 1))
    fi
}

echo "═══════════════════════════════════════════════════════════════════"
echo "E2E Tests: run-ipsec-diagnostics.sh"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "Configuration:"
echo "  Node1: $NODE1"
echo "  Node2: $NODE2"
echo "  Retis Node: $RETIS_NODE"
echo "  Duration: ${DURATION}s"
echo "  Skip Retis: $SKIP_RETIS"
echo ""

# ============================================================
# Pre-flight checks
# ============================================================
echo "--- Pre-flight checks ---"

# Check cluster connection
if oc whoami &>/dev/null; then
    CLUSTER=$(oc whoami --show-server 2>/dev/null || echo "unknown")
    test_case "Connected to cluster: $CLUSTER" "pass"
else
    echo -e "${RED}ERROR:${NC} Not connected to OpenShift cluster"
    echo "Please login first: oc login https://api.<cluster>:6443"
    exit 1
fi

# Check nodes exist
if oc get node "$NODE1" &>/dev/null; then
    test_case "Node1 exists: $NODE1" "pass"
else
    echo -e "${RED}ERROR:${NC} Node1 not found: $NODE1"
    exit 1
fi

if oc get node "$NODE2" &>/dev/null; then
    test_case "Node2 exists: $NODE2" "pass"
else
    echo -e "${RED}ERROR:${NC} Node2 not found: $NODE2"
    exit 1
fi
echo ""

# ============================================================
# Run the script
# ============================================================
echo "--- Running diagnostic script ---"
OUTPUT_DIR=$(mktemp -d)
echo "Output directory: $OUTPUT_DIR"
echo ""

SCRIPT_ARGS=(
    --node1 "$NODE1"
    --node2 "$NODE2"
    --duration "$DURATION"
    --output "$OUTPUT_DIR"
)

if [[ "$SKIP_RETIS" == "true" ]]; then
    SCRIPT_ARGS+=(--skip-retis)
else
    SCRIPT_ARGS+=(--retis-node "$RETIS_NODE")
fi

echo "Running: $SCRIPT ${SCRIPT_ARGS[*]}"
echo ""

# Run script (with 'yes' to accept disclaimer - note: yes command outputs "y", we need "yes")
if echo "yes" | timeout $((DURATION + 120)) "$SCRIPT" "${SCRIPT_ARGS[@]}"; then
    test_case "Script completed successfully" "pass"
else
    test_case "Script completed successfully" "fail"
    echo -e "${RED}Script failed - check output above${NC}"
fi
echo ""

# ============================================================
# Validate output files
# ============================================================
echo "--- Validating output files ---"

# Find the output directory
DIAG_DIR=$(ls -d "$OUTPUT_DIR"/diag-* 2>/dev/null | head -1 || echo "")

if [[ -z "$DIAG_DIR" ]]; then
    echo -e "${RED}ERROR:${NC} No diag-* directory found in $OUTPUT_DIR"
    test_case "Output directory created" "fail"
else
    test_case "Output directory created: $(basename "$DIAG_DIR")" "pass"
    
    # Check individual files
    check_file() {
        local pattern="$1"
        local files=$(ls $DIAG_DIR/$pattern 2>/dev/null || echo "")
        if [[ -n "$files" ]]; then
            for f in $files; do
                if [[ -s "$f" ]]; then
                    test_case "File exists and non-empty: $(basename "$f")" "pass"
                else
                    test_case "File exists and non-empty: $(basename "$f")" "fail"
                fi
            done
        else
            test_case "File exists: $pattern" "fail"
        fi
    }
    
    # Required files
    check_file "xfrm-*-start.txt"
    check_file "xfrm-*-end.txt"
    check_file "node1-esp.pcap"
    check_file "node2-esp.pcap"
    check_file "sync-time.txt"
    check_file "*-timing.txt"
    
    # Retis files (optional)
    if [[ "$SKIP_RETIS" != "true" ]]; then
        if [[ -f "$DIAG_DIR/retis_icv.data" ]]; then
            test_case "Retis data file exists" "pass"
        else
            test_case "Retis data file exists" "fail"
        fi
        check_file "retis-output.log"
    else
        test_case "Retis files (skipped)" "skip"
    fi
fi
echo ""

# ============================================================
# Validate file contents
# ============================================================
echo "--- Validating file contents ---"

if [[ -n "$DIAG_DIR" ]]; then
    # Check XFRM files have content
    for f in "$DIAG_DIR"/xfrm-*-start.txt; do
        if [[ -f "$f" ]] && grep -q "XFRM State" "$f"; then
            test_case "XFRM file has state section: $(basename "$f")" "pass"
        else
            test_case "XFRM file has state section: $(basename "$f")" "fail"
        fi
    done
    
    # Check pcap files are valid
    for f in "$DIAG_DIR"/*.pcap; do
        if [[ -f "$f" ]]; then
            # Check magic bytes (pcap starts with 0xd4c3b2a1 or 0xa1b2c3d4)
            MAGIC=$(xxd -l 4 "$f" 2>/dev/null | head -1 || echo "")
            if [[ "$MAGIC" == *"d4c3"* ]] || [[ "$MAGIC" == *"a1b2"* ]]; then
                test_case "PCAP file valid format: $(basename "$f")" "pass"
            else
                test_case "PCAP file valid format: $(basename "$f")" "fail"
            fi
        fi
    done
    
    # Check sync-time.txt has valid timestamp
    if [[ -f "$DIAG_DIR/sync-time.txt" ]]; then
        SYNC_TIME=$(cat "$DIAG_DIR/sync-time.txt")
        if [[ "$SYNC_TIME" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2} ]]; then
            test_case "Sync time has valid format" "pass"
        else
            test_case "Sync time has valid format" "fail"
        fi
    fi
fi
echo ""

# ============================================================
# Cleanup
# ============================================================
echo "--- Cleanup ---"
if [[ -d "$OUTPUT_DIR" ]]; then
    rm -rf "$OUTPUT_DIR"
    echo "Removed test output: $OUTPUT_DIR"
fi
echo ""

# ============================================================
# Summary
# ============================================================
echo "═══════════════════════════════════════════════════════════════════"
echo -e "Results: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC}, ${YELLOW}$SKIP skipped${NC}"
echo "═══════════════════════════════════════════════════════════════════"

if [[ $FAIL -gt 0 ]]; then
    exit 1
fi

