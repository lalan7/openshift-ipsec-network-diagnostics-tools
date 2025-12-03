#!/bin/bash
#
# Automated IPsec Capture on Two Nodes
#
# Usage:
#   ./run-dual-capture.sh [options]
#
# Config:
#   Edit capture-config.env or export environment variables
#

set -euo pipefail

# Load config file if exists (same directory as script)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/capture-config.env" ]]; then
    source "$SCRIPT_DIR/capture-config.env"
fi

# Defaults (can be overridden by config file or environment variables)
NODE1_NAME="${NODE1_NAME:-worker1.example.com}"
NODE2_NAME="${NODE2_NAME:-worker2.example.com}"
INTERFACE="${INTERFACE:-br-ex}"
DURATION="${DURATION:-30}"
PACKET_COUNT="${PACKET_COUNT:-1000}"  # Max packets to capture
LOCAL_OUTPUT="${LOCAL_OUTPUT:-/tmp/ipsec-captures}"
FILTER="${FILTER:-host \{NODE1_IP\} and host \{NODE2_IP\} and esp}"
TCPDUMP_EXTRA="${TCPDUMP_EXTRA:-}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
REMOTE_DIR="/tmp/ipsec-capture-${TIMESTAMP}"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --node1) NODE1_NAME="$2"; shift 2 ;;
        --node2) NODE2_NAME="$2"; shift 2 ;;
        --interface) INTERFACE="$2"; shift 2 ;;
        --duration) DURATION="$2"; shift 2 ;;
        --output) LOCAL_OUTPUT="$2"; shift 2 ;;
        --filter) FILTER="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: $0 [--node1 NAME] [--node2 NAME] [--interface IF] [--duration SEC] [--output DIR] [--filter EXPR]"
            echo ""
            echo "Options:"
            echo "  --node1      First node name (default: $NODE1_NAME)"
            echo "  --node2      Second node name (default: $NODE2_NAME)"
            echo "  --interface  Network interface (default: $INTERFACE)"
            echo "  --duration   Capture duration in seconds (default: $DURATION)"
            echo "  --output     Local output directory (default: $LOCAL_OUTPUT)"
            echo "  --filter     tcpdump filter expression (default: ESP between nodes)"
            echo "               Use {NODE1_IP} and {NODE2_IP} as placeholders"
            echo ""
            echo "Config file: capture-config.env (in same directory)"
            echo "Environment: NODE1_NAME, NODE2_NAME, INTERFACE, DURATION, PACKET_COUNT, LOCAL_OUTPUT, FILTER, TCPDUMP_EXTRA"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# Check OpenShift connection
if ! oc whoami &>/dev/null; then
    echo "Error: Not connected to OpenShift cluster"
    echo ""
    echo "Please login first:"
    echo "  oc login https://api.<cluster>:6443"
    echo ""
    exit 1
fi

echo "=== IPsec Dual Capture ==="
echo "Cluster: $(oc whoami --show-server 2>/dev/null || echo 'unknown')"
echo ""

# Get node IPs
echo "Getting node information..."
NODE1_IP=$(oc get node "$NODE1_NAME" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "")
NODE2_IP=$(oc get node "$NODE2_NAME" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "")

if [[ -z "$NODE1_IP" ]] || [[ -z "$NODE2_IP" ]]; then
    echo "Error: Could not get node IPs"
    oc get nodes -o wide
    exit 1
fi

# Replace placeholders in filter with actual IPs
RESOLVED_FILTER="${FILTER//\{NODE1_IP\}/$NODE1_IP}"
RESOLVED_FILTER="${RESOLVED_FILTER//\{NODE2_IP\}/$NODE2_IP}"

echo "  Node 1: $NODE1_NAME ($NODE1_IP)"
echo "  Node 2: $NODE2_NAME ($NODE2_IP)"
echo "  Interface: $INTERFACE"
echo "  Duration: ${DURATION}s"
echo "  Filter: $RESOLVED_FILTER"
echo "  Remote dir: $REMOTE_DIR"
echo "  Local output: $LOCAL_OUTPUT"
echo ""

# Build capture scripts - use packet count limit (more reliable than timeout in toolbox)
# Build the tcpdump command with all variables expanded
# Filter must be single-quoted in the script to avoid word splitting
if [[ -n "$RESOLVED_FILTER" ]]; then
    TCPDUMP_CMD1="tcpdump -nn -s0 ${TCPDUMP_EXTRA} -c ${PACKET_COUNT} -i ${INTERFACE} -w /host${REMOTE_DIR}/host1.pcap '${RESOLVED_FILTER}'"
    TCPDUMP_CMD2="tcpdump -nn -s0 ${TCPDUMP_EXTRA} -c ${PACKET_COUNT} -i ${INTERFACE} -w /host${REMOTE_DIR}/host2.pcap '${RESOLVED_FILTER}'"
else
    TCPDUMP_CMD1="tcpdump -nn -s0 ${TCPDUMP_EXTRA} -c ${PACKET_COUNT} -i ${INTERFACE} -w /host${REMOTE_DIR}/host1.pcap"
    TCPDUMP_CMD2="tcpdump -nn -s0 ${TCPDUMP_EXTRA} -c ${PACKET_COUNT} -i ${INTERFACE} -w /host${REMOTE_DIR}/host2.pcap"
fi

# Script for host 1 - use escaped double quotes for the tcpdump command
SCRIPT_HOST1="#!/bin/bash
echo 'Creating directory: ${REMOTE_DIR}'
mkdir -p ${REMOTE_DIR}
echo 'Writing tcpdump script...'
echo '#!/bin/bash' > /tmp/tcpdump-run.sh
echo \"${TCPDUMP_CMD1}\" >> /tmp/tcpdump-run.sh
chmod +x /tmp/tcpdump-run.sh
echo 'tcpdump command:'
cat /tmp/tcpdump-run.sh
echo ''
echo 'Running via toolbox...'
toolbox /host/tmp/tcpdump-run.sh
echo 'Exit code:' \$?
echo 'Files:'
ls -la ${REMOTE_DIR}/ 2>/dev/null || echo 'Directory empty or not found'
"

# Script for host 2
SCRIPT_HOST2="#!/bin/bash
echo 'Creating directory: ${REMOTE_DIR}'
mkdir -p ${REMOTE_DIR}
echo 'Writing tcpdump script...'
echo '#!/bin/bash' > /tmp/tcpdump-run.sh
echo \"${TCPDUMP_CMD2}\" >> /tmp/tcpdump-run.sh
chmod +x /tmp/tcpdump-run.sh
echo 'tcpdump command:'
cat /tmp/tcpdump-run.sh
echo ''
echo 'Running via toolbox...'
toolbox /host/tmp/tcpdump-run.sh
echo 'Exit code:' \$?
echo 'Files:'
ls -la ${REMOTE_DIR}/ 2>/dev/null || echo 'Directory empty or not found'
"

echo "=== Phase 1: Deploying capture scripts ==="

# Deploy to node 1
echo "Deploying to $NODE1_NAME..."
SCRIPT1_B64=$(echo "$SCRIPT_HOST1" | base64)
oc debug node/"$NODE1_NAME" --to-namespace=default -- chroot /host bash -c "
echo '$SCRIPT1_B64' | base64 -d > /tmp/capture.sh
chmod +x /tmp/capture.sh
" 2>/dev/null

# Deploy to node 2
echo "Deploying to $NODE2_NAME..."
SCRIPT2_B64=$(echo "$SCRIPT_HOST2" | base64)
oc debug node/"$NODE2_NAME" --to-namespace=default -- chroot /host bash -c "
echo '$SCRIPT2_B64' | base64 -d > /tmp/capture.sh
chmod +x /tmp/capture.sh
" 2>/dev/null

echo "Done."
echo ""

echo "=== Phase 2: Starting captures (${DURATION}s) ==="

# Start captures in background
echo "Starting capture on $NODE1_NAME..."
oc debug node/"$NODE1_NAME" --to-namespace=default -- chroot /host /tmp/capture.sh \
    > "/tmp/capture-${NODE1_NAME}.log" 2>&1 &
PID1=$!

sleep 1

echo "Starting capture on $NODE2_NAME..."
oc debug node/"$NODE2_NAME" --to-namespace=default -- chroot /host /tmp/capture.sh \
    > "/tmp/capture-${NODE2_NAME}.log" 2>&1 &
PID2=$!

echo ""
echo "Captures running (PIDs: $PID1, $PID2)"
echo "Waiting up to ${DURATION} seconds for packets..."
echo "(Will stop automatically after $PACKET_COUNT packets or press Ctrl+C to stop early)"

# Wait with timeout - check every second if processes are still running
for ((i=DURATION; i>0; i--)); do
    # Check if both processes have finished
    if ! kill -0 $PID1 2>/dev/null && ! kill -0 $PID2 2>/dev/null; then
        echo ""
        echo "Both captures finished early."
        break
    fi
    printf "\r  Time remaining: %3d seconds" "$i"
    sleep 1
done
printf "\r  Time remaining:   0 seconds\n"

echo ""
echo "Stopping captures..."
kill $PID1 $PID2 2>/dev/null || true
sleep 2
kill -9 $PID1 $PID2 2>/dev/null || true
echo "Done."
echo ""

# Show logs
echo "=== Capture Logs ==="
echo "--- Node 1 ---"
tail -10 "/tmp/capture-${NODE1_NAME}.log" 2>/dev/null || echo "(no log)"
echo "--- Node 2 ---"
tail -10 "/tmp/capture-${NODE2_NAME}.log" 2>/dev/null || echo "(no log)"
echo ""

echo "=== Phase 3: Retrieving files ==="
mkdir -p "$LOCAL_OUTPUT"

# Check what files exist on nodes
echo "Checking files on $NODE1_NAME..."
oc debug node/"$NODE1_NAME" --to-namespace=default -- chroot /host bash -c "ls -la $REMOTE_DIR/ 2>/dev/null || echo 'Directory not found'" 2>&1 | grep -v "^Starting pod" | grep -v "^Removing debug" | grep -v "^To use host"

echo ""
echo "Retrieving from $NODE1_NAME (via base64)..."
B64_HOST1=$(oc debug node/"$NODE1_NAME" --to-namespace=default -- chroot /host bash -c "
if [[ -f '$REMOTE_DIR/host1.pcap' ]]; then
    base64 '$REMOTE_DIR/host1.pcap'
else
    echo 'FILE_NOT_FOUND'
fi
" 2>&1 | grep -v "^Starting pod" | grep -v "^Removing debug" | grep -v "^To use host" | grep -v "^$")

if [[ "$B64_HOST1" != "FILE_NOT_FOUND" && -n "$B64_HOST1" ]]; then
    echo "$B64_HOST1" | base64 -d > "$LOCAL_OUTPUT/host1.pcap" 2>/dev/null
fi

echo "Retrieving from $NODE2_NAME (via base64)..."
B64_HOST2=$(oc debug node/"$NODE2_NAME" --to-namespace=default -- chroot /host bash -c "
if [[ -f '$REMOTE_DIR/host2.pcap' ]]; then
    base64 '$REMOTE_DIR/host2.pcap'
else
    echo 'FILE_NOT_FOUND'
fi
" 2>&1 | grep -v "^Starting pod" | grep -v "^Removing debug" | grep -v "^To use host" | grep -v "^$")

if [[ "$B64_HOST2" != "FILE_NOT_FOUND" && -n "$B64_HOST2" ]]; then
    echo "$B64_HOST2" | base64 -d > "$LOCAL_OUTPUT/host2.pcap" 2>/dev/null
fi

echo ""
echo "=== Results ==="
if [[ -s "$LOCAL_OUTPUT/host1.pcap" ]]; then
    SIZE=$(ls -lh "$LOCAL_OUTPUT/host1.pcap" | awk '{print $5}')
    echo "✓ host1.pcap: $SIZE"
else
    echo "✗ host1.pcap: empty or missing"
fi

if [[ -s "$LOCAL_OUTPUT/host2.pcap" ]]; then
    SIZE=$(ls -lh "$LOCAL_OUTPUT/host2.pcap" | awk '{print $5}')
    echo "✓ host2.pcap: $SIZE"
else
    echo "✗ host2.pcap: empty or missing"
fi

echo ""
echo "Files: $LOCAL_OUTPUT/"
echo ""

# Cleanup
oc debug node/"$NODE1_NAME" --to-namespace=default -- chroot /host rm -rf "$REMOTE_DIR" /tmp/capture.sh /tmp/tcpdump-run.sh 2>/dev/null || true
oc debug node/"$NODE2_NAME" --to-namespace=default -- chroot /host rm -rf "$REMOTE_DIR" /tmp/capture.sh /tmp/tcpdump-run.sh 2>/dev/null || true
echo "Done."
