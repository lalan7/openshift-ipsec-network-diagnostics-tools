#!/bin/bash
#
# Automated Retis Capture for Dropped Packets
# Captures packets dropped due to xfrm_audit_state_icvfail (IPsec integrity failures)
#
# Usage:
#   ./run-retis-capture.sh [options]
#
# Config:
#   Edit capture-config.env or export environment variables
#

set -euo pipefail

# Load config file if exists
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/capture-config.env" ]]; then
    source "$SCRIPT_DIR/capture-config.env"
fi

# Color codes for output
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m' # No Color

# Helper function to display section headers
section() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "$1"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
}

# Helper function to confirm user input
confirm_yes_no() {
    local prompt="$1"
    local response
    echo -n "$prompt " >&2
    read -r response
    echo "$response"
}

# Display disclaimer and require user confirmation
show_disclaimer() {
    section "⚠️  DISCLAIMER"

    echo "" >&2
    echo -e "${YELLOW}This is NOT an official Red Hat supported tool.${NC}" >&2
    echo -e "${YELLOW}Provided for testing purposes only.${NC}" >&2
    echo -e "${YELLOW}Use at your own risk. No warranty provided.${NC}" >&2
    echo "" >&2

    local confirm
    confirm=$(confirm_yes_no "Do you understand and accept? Type 'yes' to continue or anything else to exit:")
    if [[ "$confirm" != "yes" ]]; then
        echo "Exiting..." >&2
        exit 0
    fi
}

# Defaults
NODE_NAME="${NODE_NAME:-${NODE1_NAME:-worker1.example.com}}"
DURATION="${DURATION:-30}"
LOCAL_OUTPUT="${LOCAL_OUTPUT:-/tmp/ipsec-captures}"
RETIS_IMAGE="${RETIS_IMAGE:-quay.io/retis/retis}"
RETIS_FILTER="${RETIS_FILTER:-}"  # Empty = capture all drops

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
REMOTE_DIR="/tmp/retis-capture-${TIMESTAMP}"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --node) NODE_NAME="$2"; shift 2 ;;
        --duration) DURATION="$2"; shift 2 ;;
        --output) LOCAL_OUTPUT="$2"; shift 2 ;;
        --filter) RETIS_FILTER="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: $0 [--node NAME] [--duration SEC] [--output DIR] [--filter EXPR]"
            echo ""
            echo "Options:"
            echo "  --node       Node to capture on (default: $NODE_NAME)"
            echo "  --duration   Capture duration in seconds (default: $DURATION)"
            echo "  --output     Local output directory (default: $LOCAL_OUTPUT)"
            echo "  --filter     Retis filter expression (default: all drops)"
            echo ""
            echo "Config file: capture-config.env"
            echo "Environment: NODE_NAME, DURATION, LOCAL_OUTPUT, RETIS_IMAGE, RETIS_FILTER"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# Show disclaimer and get user confirmation
show_disclaimer

# Check OpenShift connection
if ! oc whoami &>/dev/null; then
    echo "Error: Not connected to OpenShift cluster"
    echo ""
    echo "Please login first:"
    echo "  oc login https://api.<cluster>:6443"
    echo ""
    exit 1
fi

echo "=== Retis Dropped Packet Capture ==="
echo "Cluster: $(oc whoami --show-server 2>/dev/null || echo 'unknown')"
echo ""
echo "  Node: $NODE_NAME"
echo "  Duration: ${DURATION}s"
echo "  Filter: ${RETIS_FILTER:-all drops}"
echo "  Remote dir: $REMOTE_DIR"
echo "  Local output: $LOCAL_OUTPUT"
echo ""

# Build filter argument
FILTER_ARG=""
if [[ -n "$RETIS_FILTER" ]]; then
    FILTER_ARG="-f '$RETIS_FILTER'"
fi

# Build the retis capture script
# Run retis directly via podman with proper volume mounts
RETIS_SCRIPT="#!/bin/bash
mkdir -p $REMOTE_DIR
chmod 755 $REMOTE_DIR
cd $REMOTE_DIR

echo 'Starting Retis capture...'
echo 'Capturing: skb drops, skb-tracking, ct (conntrack), dev, ns'
echo 'Output: $REMOTE_DIR/retis_drops.data'
echo ''

# Run retis directly with podman, mounting the output directory
# Use --privileged for kernel tracing access
timeout $DURATION podman run --rm \\
    --privileged \\
    --pid=host \\
    --network=host \\
    -v /sys:/sys:ro \\
    -v /proc:/proc:ro \\
    -v $REMOTE_DIR:/output:rw \\
    $RETIS_IMAGE \\
    collect \\
    -c skb,skb-tracking,skb-drop,ct,dev,ns \\
    --skb-sections all \\
    --allow-system-changes \\
    -o /output/retis_drops.data \\
    $FILTER_ARG 2>&1 || true

echo ''
echo 'Capture complete.'
ls -lh $REMOTE_DIR/
"

echo "=== Phase 1: Deploying Retis script ==="
SCRIPT_B64=$(echo "$RETIS_SCRIPT" | base64)

echo "Deploying to $NODE_NAME..."
oc debug node/"$NODE_NAME" --to-namespace=default -- chroot /host bash -c "
echo '$SCRIPT_B64' | base64 -d > /tmp/retis-capture.sh
chmod +x /tmp/retis-capture.sh
" 2>/dev/null

echo "Done."
echo ""

echo "=== Phase 2: Starting Retis capture (${DURATION}s) ==="
echo ""
echo "Running Retis on $NODE_NAME..."
echo "(This may take a moment to start the container)"
echo ""

# Run the capture
oc debug node/"$NODE_NAME" --to-namespace=default -- chroot /host /tmp/retis-capture.sh \
    > "/tmp/retis-${NODE_NAME}.log" 2>&1 &
PID=$!

# Wait with timeout
for ((i=DURATION+30; i>0; i--)); do
    if ! kill -0 $PID 2>/dev/null; then
        echo ""
        echo "Capture finished."
        break
    fi
    printf "\r  Time remaining: %3d seconds" "$((i-30 > 0 ? i-30 : 0))"
    sleep 1
done
printf "\r  Time remaining:   0 seconds\n"

echo ""
echo "Stopping capture..."
kill $PID 2>/dev/null || true
sleep 2
kill -9 $PID 2>/dev/null || true
echo "Done."
echo ""

# Show log
echo "=== Capture Log ==="
tail -20 "/tmp/retis-${NODE_NAME}.log" 2>/dev/null || echo "(no log)"
echo ""

echo "=== Phase 3: Retrieving files ==="
mkdir -p "$LOCAL_OUTPUT"

echo "Retrieving from $NODE_NAME..."
# Use base64 to avoid binary data issues with oc debug output
B64_DATA=$(oc debug node/"$NODE_NAME" --to-namespace=default -- chroot /host bash -c "
if [[ -f '$REMOTE_DIR/retis_drops.data' ]]; then
    base64 '$REMOTE_DIR/retis_drops.data'
else
    echo 'FILE_NOT_FOUND'
fi
" 2>/dev/null | grep -v "^Starting pod" | grep -v "^Removing debug" | grep -v "^To use host")

if [[ "$B64_DATA" != "FILE_NOT_FOUND" && -n "$B64_DATA" ]]; then
    echo "$B64_DATA" | base64 -d > "$LOCAL_OUTPUT/retis_drops.data"
fi

echo ""
echo "=== Results ==="
if [[ -s "$LOCAL_OUTPUT/retis_drops.data" ]]; then
    SIZE=$(ls -lh "$LOCAL_OUTPUT/retis_drops.data" | awk '{print $5}')
    echo "✓ retis_drops.data: $SIZE"
else
    echo "✗ retis_drops.data: empty or missing"
fi

echo ""
echo "Files: $LOCAL_OUTPUT/"
echo ""
echo "To analyze:"
echo "  retis sort $LOCAL_OUTPUT/retis_drops.data"
echo "  retis print $LOCAL_OUTPUT/retis_drops.data"
echo ""

# Cleanup
oc debug node/"$NODE_NAME" --to-namespace=default -- chroot /host rm -rf "$REMOTE_DIR" /tmp/retis-capture.sh 2>/dev/null || true
echo "Done."

