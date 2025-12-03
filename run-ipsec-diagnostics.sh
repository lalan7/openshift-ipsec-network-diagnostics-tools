#!/bin/bash
#
# IPsec Full Diagnostics: tcpdump + xfrm + retis
# Captures ESP traffic, XFRM state/policy, and dropped packets with ICV failure tracking
#
# Usage:
#   ./run-ipsec-diagnostics.sh [options]
#
# This script runs:
#   1. XFRM state/policy dump on both nodes (START)
#   2. tcpdump ESP capture on both nodes (synchronized)
#   3. Retis capture with xfrm_audit_state_icvfail probe on dropping node
#   4. Monitor for ICV failures (optional auto-stop)
#   5. XFRM state/policy dump on both nodes (END)
#
# Requirements from RH engineering:
#   - tcpdump with -s0 on both sides
#   - Retis with -p ifdump, xfrm_audit_state_icvfail/stack probe
#   - XFRM state/policy at START and END for comparison
#   - All captures must be synchronized
#

set -euo pipefail

# Load config
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/capture-config.env" ]]; then
    source "$SCRIPT_DIR/capture-config.env"
fi

# Defaults
NODE1_NAME="${NODE1_NAME:-worker1.example.com}"
NODE2_NAME="${NODE2_NAME:-worker2.example.com}"
INTERFACE="${INTERFACE:-br-ex}"
DURATION="${DURATION:-30}"
PACKET_COUNT="${PACKET_COUNT:-1000}"
LOCAL_OUTPUT="${LOCAL_OUTPUT:-${HOME}/ipsec-captures}"
FILTER="${FILTER:-host \{NODE1_IP\} and host \{NODE2_IP\} and esp}"
TCPDUMP_EXTRA="${TCPDUMP_EXTRA:-}"
RETIS_IMAGE="${RETIS_IMAGE:-quay.io/retis/retis}"
SKIP_RETIS="${SKIP_RETIS:-false}"
RETIS_NODE="${RETIS_NODE:-}"  # Node where packets are being dropped (runs Retis)
MONITOR_ICV="${MONITOR_ICV:-false}"  # Monitor for ICV failures and auto-stop
ICV_THRESHOLD="${ICV_THRESHOLD:-3}"  # Number of ICV failures before stopping
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --node1) NODE1_NAME="$2"; shift 2 ;;
        --node2) NODE2_NAME="$2"; shift 2 ;;
        --interface) INTERFACE="$2"; shift 2 ;;
        --duration) DURATION="$2"; shift 2 ;;
        --output) LOCAL_OUTPUT="$2"; shift 2 ;;
        --filter) FILTER="$2"; shift 2 ;;
        --skip-retis) SKIP_RETIS="true"; shift ;;
        --retis-node) RETIS_NODE="$2"; shift 2 ;;
        --monitor-icv) MONITOR_ICV="true"; shift ;;
        --icv-threshold) ICV_THRESHOLD="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: $0 [options]"
            echo ""
            echo "Runs full IPsec diagnostics: xfrm dump + tcpdump + retis"
            echo "Designed for capturing ICV integrity failures with synchronized captures."
            echo ""
            echo "Options:"
            echo "  --node1          First node - sender (default: $NODE1_NAME)"
            echo "  --node2          Second node - receiver (default: $NODE2_NAME)"
            echo "  --interface      Network interface (default: $INTERFACE)"
            echo "  --duration       Capture duration in seconds (default: $DURATION)"
            echo "  --output         Local output directory (default: $LOCAL_OUTPUT)"
            echo "  --filter         tcpdump filter (default: ESP between nodes)"
            echo "  --skip-retis     Skip Retis capture"
            echo "  --retis-node     Node where Retis runs (dropping side, default: node2)"
            echo "  --monitor-icv    Monitor for ICV failures and auto-stop"
            echo "  --icv-threshold  Number of ICV failures before stopping (default: $ICV_THRESHOLD)"
            echo ""
            echo "Captures include:"
            echo "  - XFRM state/policy at START and END (for comparison)"
            echo "  - tcpdump ESP packets on both nodes (synchronized, full packet -s0)"
            echo "  - Retis with xfrm_audit_state_icvfail/stack probe on dropping node"
            echo ""
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# Default retis node to node2 (typically the receiving/dropping side)
if [[ -z "$RETIS_NODE" ]]; then
    RETIS_NODE="$NODE2_NAME"
fi

# Check OpenShift connection
if ! oc whoami &>/dev/null; then
    echo "Error: Not connected to OpenShift cluster"
    echo ""
    echo "Please login first:"
    echo "  oc login https://api.<cluster>:6443"
    echo ""
    exit 1
fi

# Create output directory
OUTPUT_DIR="${LOCAL_OUTPUT}/diag-${TIMESTAMP}"
mkdir -p "$OUTPUT_DIR"

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║        IPsec ICV Failure Diagnostics                          ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""
echo "  Cluster: $(oc whoami --show-server 2>/dev/null || echo 'unknown')"
echo "  Node 1 (sender): $NODE1_NAME"
echo "  Node 2 (receiver): $NODE2_NAME"
echo "  Retis node (dropping side): $RETIS_NODE"
echo "  Interface: $INTERFACE"
echo "  Duration: ${DURATION}s"
echo "  Monitor ICV: $MONITOR_ICV (threshold: $ICV_THRESHOLD)"
echo "  Output: $OUTPUT_DIR"
echo ""

# Get node IPs
echo "Getting node IPs..."
NODE1_IP=$(oc get node "$NODE1_NAME" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "")
NODE2_IP=$(oc get node "$NODE2_NAME" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "")
RETIS_NODE_IP=$(oc get node "$RETIS_NODE" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "")

if [[ -z "$NODE1_IP" ]] || [[ -z "$NODE2_IP" ]]; then
    echo "Error: Could not get node IPs"
    exit 1
fi

echo "  $NODE1_NAME: $NODE1_IP"
echo "  $NODE2_NAME: $NODE2_IP"
if [[ "$RETIS_NODE" != "$NODE1_NAME" ]] && [[ "$RETIS_NODE" != "$NODE2_NAME" ]]; then
    echo "  $RETIS_NODE: $RETIS_NODE_IP"
fi
echo ""

# Resolve filter - for tcpdump (ESP between nodes)
RESOLVED_FILTER="${FILTER//\{NODE1_IP\}/$NODE1_IP}"
RESOLVED_FILTER="${RESOLVED_FILTER//\{NODE2_IP\}/$NODE2_IP}"

# Retis filter - for tracking packets between the two nodes
RETIS_FILTER="src host $NODE1_IP and dst host $NODE2_IP"

REMOTE_DIR="/tmp/ipsec-diag-${TIMESTAMP}"

# ============================================================
# PHASE 1: XFRM State/Policy Dump (START)
# ============================================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Phase 1: XFRM State & Policy Dump (START - before capture)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

dump_xfrm() {
    local NODE="$1"
    local SUFFIX="$2"
    local NODE_SHORT=$(echo "$NODE" | cut -d. -f1)
    
    oc debug node/"$NODE" --to-namespace=default -- chroot /host bash -c "
echo '=== XFRM State ===' 
ip xfrm state show 2>/dev/null || echo 'No XFRM state'
echo ''
echo '=== XFRM Policy ==='
ip xfrm policy show 2>/dev/null || echo 'No XFRM policy'
echo ''
echo '=== XFRM State Count ==='
ip xfrm state count 2>/dev/null || echo '0'
echo ''
echo '=== XFRM Policy Count ==='
ip xfrm policy count 2>/dev/null || echo '0'
" 2>&1 | grep -v "^Starting pod" | grep -v "^Removing debug" | grep -v "^To use host" > "$OUTPUT_DIR/xfrm-${NODE_SHORT}-${SUFFIX}.txt"
    
    echo "  Saved: xfrm-${NODE_SHORT}-${SUFFIX}.txt"
}

for NODE in "$NODE1_NAME" "$NODE2_NAME"; do
    NODE_SHORT=$(echo "$NODE" | cut -d. -f1)
    echo "Dumping XFRM from $NODE_SHORT (start)..."
    dump_xfrm "$NODE" "start"
done
echo ""

# ============================================================
# PHASE 2: Synchronized Capture (tcpdump + Retis)
# ============================================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Phase 2: Synchronized Capture - tcpdump + Retis (${DURATION}s)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "tcpdump filter: $RESOLVED_FILTER"
echo "Retis filter: $RETIS_FILTER"
echo "Retis running on: $RETIS_NODE (dropping side)"
echo ""

# Build tcpdump commands - must use toolbox on RHCOS nodes
# Note: toolbox mounts host at /host, so paths need /host prefix for output
if [[ -n "$RESOLVED_FILTER" ]]; then
    TCPDUMP_CMD1="tcpdump -nn -s0 ${TCPDUMP_EXTRA} -c ${PACKET_COUNT} -i ${INTERFACE} -w /host${REMOTE_DIR}/node1-esp.pcap '${RESOLVED_FILTER}'"
    TCPDUMP_CMD2="tcpdump -nn -s0 ${TCPDUMP_EXTRA} -c ${PACKET_COUNT} -i ${INTERFACE} -w /host${REMOTE_DIR}/node2-esp.pcap '${RESOLVED_FILTER}'"
else
    TCPDUMP_CMD1="tcpdump -nn -s0 ${TCPDUMP_EXTRA} -c ${PACKET_COUNT} -i ${INTERFACE} -w /host${REMOTE_DIR}/node1-esp.pcap"
    TCPDUMP_CMD2="tcpdump -nn -s0 ${TCPDUMP_EXTRA} -c ${PACKET_COUNT} -i ${INTERFACE} -w /host${REMOTE_DIR}/node2-esp.pcap"
fi

# Create capture commands that run via oc debug + toolbox
echo "Starting synchronized captures..."
echo ""

# Record start time
SYNC_TIME=$(date -Iseconds)
echo "Capture start time: $SYNC_TIME"
echo "$SYNC_TIME" > "$OUTPUT_DIR/sync-time.txt"

# Create tcpdump script content (will be deployed to nodes)
TCPDUMP_SCRIPT1="#!/bin/bash
timeout ${DURATION} ${TCPDUMP_CMD1}
"

TCPDUMP_SCRIPT2="#!/bin/bash
timeout ${DURATION} ${TCPDUMP_CMD2}
"

# Encode scripts for deployment
TCPDUMP_SCRIPT1_B64=$(echo "$TCPDUMP_SCRIPT1" | base64)
TCPDUMP_SCRIPT2_B64=$(echo "$TCPDUMP_SCRIPT2" | base64)

# Start tcpdump on Node 1 (runs for DURATION seconds via toolbox)
echo "Starting tcpdump on $NODE1_NAME..."
oc debug node/"$NODE1_NAME" --to-namespace=default -- chroot /host bash -c "
mkdir -p ${REMOTE_DIR}
echo 'START:' \$(date -Iseconds) > ${REMOTE_DIR}/node1-timing.txt
# Deploy tcpdump script
echo '${TCPDUMP_SCRIPT1_B64}' | base64 -d > /tmp/tcpdump-run.sh
chmod +x /tmp/tcpdump-run.sh
# Run tcpdump via toolbox (required on RHCOS)
toolbox /host/tmp/tcpdump-run.sh 2>&1 || true
echo 'END:' \$(date -Iseconds) >> ${REMOTE_DIR}/node1-timing.txt
ls -la ${REMOTE_DIR}/ >> ${REMOTE_DIR}/node1-timing.txt 2>&1
" > "/tmp/tcpdump-${NODE1_NAME}.log" 2>&1 &
PID1=$!

# Start tcpdump on Node 2 (runs for DURATION seconds via toolbox)
echo "Starting tcpdump on $NODE2_NAME..."
oc debug node/"$NODE2_NAME" --to-namespace=default -- chroot /host bash -c "
mkdir -p ${REMOTE_DIR}
echo 'START:' \$(date -Iseconds) > ${REMOTE_DIR}/node2-timing.txt
# Deploy tcpdump script
echo '${TCPDUMP_SCRIPT2_B64}' | base64 -d > /tmp/tcpdump-run.sh
chmod +x /tmp/tcpdump-run.sh
# Run tcpdump via toolbox (required on RHCOS)
toolbox /host/tmp/tcpdump-run.sh 2>&1 || true
echo 'END:' \$(date -Iseconds) >> ${REMOTE_DIR}/node2-timing.txt
ls -la ${REMOTE_DIR}/ >> ${REMOTE_DIR}/node2-timing.txt 2>&1
" > "/tmp/tcpdump-${NODE2_NAME}.log" 2>&1 &
PID2=$!

# Start Retis on dropping node (with required probes for ICV failure tracking)
# -p ifdump: Interface dump probe
# -c skb,skb-tracking,skb-drop,ct,dev,ns: Collectors
# --skb-sections all: All SKB sections
# -p xfrm_audit_state_icvfail/stack: CRITICAL - ICV failure tracking
# -f: Filter for specific src/dst
PID_RETIS=""
if [[ "$SKIP_RETIS" != "true" ]]; then
    echo "Starting Retis on $RETIS_NODE (ICV failure tracking)..."
    oc debug node/"$RETIS_NODE" --to-namespace=default -- chroot /host bash -c "
mkdir -p ${REMOTE_DIR}
chmod 755 ${REMOTE_DIR}
echo \"START: \$(date -Iseconds)\" > ${REMOTE_DIR}/retis-timing.txt
timeout ${DURATION} podman run --rm \
    --privileged \
    --pid=host \
    --network=host \
    -v /sys:/sys:ro \
    -v /proc:/proc:ro \
    -v ${REMOTE_DIR}:/output:rw \
    ${RETIS_IMAGE} \
    -p ifdump \
    collect \
    -c skb,skb-tracking,skb-drop,ct,dev,ns \
    --skb-sections all \
    -p xfrm_audit_state_icvfail/stack \
    --allow-system-changes \
    -o /output/retis_icv.data \
    -f '${RETIS_FILTER}' 2>&1 | tee ${REMOTE_DIR}/retis-output.log || true
echo \"END: \$(date -Iseconds)\" >> ${REMOTE_DIR}/retis-timing.txt
" > "/tmp/retis-${RETIS_NODE}.log" 2>&1 &
    PID_RETIS=$!
fi

echo ""
echo "Captures running (PIDs: tcpdump1=$PID1, tcpdump2=$PID2${PID_RETIS:+, retis=$PID_RETIS})"
echo ""

# Wait for captures to complete
echo "Waiting for captures to complete (${DURATION}s)..."
NEW_ICV=0
for ((i=DURATION; i>0; i--)); do
    # Check if all captures are still running
    RUNNING=0
    kill -0 $PID1 2>/dev/null && ((RUNNING++)) || true
    kill -0 $PID2 2>/dev/null && ((RUNNING++)) || true
    [[ -n "$PID_RETIS" ]] && kill -0 $PID_RETIS 2>/dev/null && ((RUNNING++)) || true
    
    if [[ $RUNNING -eq 0 ]]; then
        echo ""
        echo "All captures completed"
        break
    fi
    
    # Optional ICV monitoring (check every 10 seconds to reduce overhead)
    if [[ "$MONITOR_ICV" == "true" ]] && (( i % 10 == 0 )); then
        NEW_ICV=$(oc debug node/"$RETIS_NODE" --to-namespace=default -- chroot /host dmesg 2>&1 | \
            grep -v "^Starting pod" | grep -v "^Removing debug" | grep -v "^To use host" | \
            grep -c "SA-icv-failure\|xfrm_audit_state_icvfail" 2>/dev/null || echo "0")
        NEW_ICV=$(echo "$NEW_ICV" | tr -d '[:space:]' | grep -E '^[0-9]+$' || echo "0")
        NEW_ICV=${NEW_ICV:-0}
        
        if [[ "$NEW_ICV" -ge "$ICV_THRESHOLD" ]]; then
            echo ""
            echo "ICV failure threshold reached ($NEW_ICV failures) - stopping captures"
            break
        fi
    fi
    
    if [[ "$MONITOR_ICV" == "true" ]]; then
        printf "\r  Time remaining: %3d seconds | Running: %d | ICV failures: %d" "$i" "$RUNNING" "$NEW_ICV"
    else
        printf "\r  Time remaining: %3d seconds | Running: %d" "$i" "$RUNNING"
    fi
    sleep 1
done
printf "\n"

echo "Waiting for capture processes to finish..."
wait $PID1 2>/dev/null || true
wait $PID2 2>/dev/null || true
[[ -n "$PID_RETIS" ]] && wait $PID_RETIS 2>/dev/null || true
echo "All capture processes finished."

# Retrieve pcap and timing files
echo ""
echo "Retrieving capture files..."

retrieve_file() {
    local NODE="$1"
    local REMOTE_FILE="$2"
    local LOCAL_FILE="$3"
    
    B64_DATA=$(oc debug node/"$NODE" --to-namespace=default -- chroot /host bash -c "
if [[ -f '${REMOTE_FILE}' ]]; then
    base64 '${REMOTE_FILE}'
else
    echo 'FILE_NOT_FOUND'
fi
" 2>&1 | grep -v "^Starting pod" | grep -v "^Removing debug" | grep -v "^To use host" | grep -v "^$")
    
    if [[ "$B64_DATA" != "FILE_NOT_FOUND" && -n "$B64_DATA" ]]; then
        echo "$B64_DATA" | base64 -d > "$LOCAL_FILE" 2>/dev/null
        if [[ -s "$LOCAL_FILE" ]]; then
            SIZE=$(ls -lh "$LOCAL_FILE" | awk '{print $5}')
            echo "  ✓ $(basename "$LOCAL_FILE"): $SIZE"
            return 0
        fi
    fi
    echo "  ✗ $(basename "$LOCAL_FILE"): not found"
    return 1
}

# Get pcap files
retrieve_file "$NODE1_NAME" "${REMOTE_DIR}/node1-esp.pcap" "$OUTPUT_DIR/node1-esp.pcap"
retrieve_file "$NODE1_NAME" "${REMOTE_DIR}/node1-timing.txt" "$OUTPUT_DIR/node1-timing.txt"
retrieve_file "$NODE2_NAME" "${REMOTE_DIR}/node2-esp.pcap" "$OUTPUT_DIR/node2-esp.pcap"
retrieve_file "$NODE2_NAME" "${REMOTE_DIR}/node2-timing.txt" "$OUTPUT_DIR/node2-timing.txt"

# Get Retis files
if [[ "$SKIP_RETIS" != "true" ]]; then
    retrieve_file "$RETIS_NODE" "${REMOTE_DIR}/retis_icv.data" "$OUTPUT_DIR/retis_icv.data"
    retrieve_file "$RETIS_NODE" "${REMOTE_DIR}/retis-timing.txt" "$OUTPUT_DIR/retis-timing.txt"
    retrieve_file "$RETIS_NODE" "${REMOTE_DIR}/retis-output.log" "$OUTPUT_DIR/retis-output.log"
fi
echo ""

# ============================================================
# PHASE 3: XFRM State/Policy Dump (END)
# ============================================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Phase 3: XFRM State & Policy Dump (END - after capture)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

for NODE in "$NODE1_NAME" "$NODE2_NAME"; do
    NODE_SHORT=$(echo "$NODE" | cut -d. -f1)
    echo "Dumping XFRM from $NODE_SHORT (end)..."
    dump_xfrm "$NODE" "end"
done
echo ""

# ============================================================
# Cleanup
# ============================================================
echo "Cleaning up remote files..."
oc debug node/"$NODE1_NAME" --to-namespace=default -- chroot /host rm -rf "$REMOTE_DIR" 2>/dev/null || true
oc debug node/"$NODE2_NAME" --to-namespace=default -- chroot /host rm -rf "$REMOTE_DIR" 2>/dev/null || true
if [[ "$RETIS_NODE" != "$NODE1_NAME" ]] && [[ "$RETIS_NODE" != "$NODE2_NAME" ]]; then
    oc debug node/"$RETIS_NODE" --to-namespace=default -- chroot /host rm -rf "$REMOTE_DIR" 2>/dev/null || true
fi

# ============================================================
# Summary
# ============================================================
echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║                       Results Summary                          ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""
echo "Output directory: $OUTPUT_DIR"
echo ""
ls -lh "$OUTPUT_DIR/"
echo ""

# Show timing info if available
if [[ -f "$OUTPUT_DIR/node1-timing.txt" ]]; then
    echo "Capture Timing:"
    echo "  Node1: $(cat "$OUTPUT_DIR/node1-timing.txt" 2>/dev/null | head -1)"
    echo "  Node2: $(cat "$OUTPUT_DIR/node2-timing.txt" 2>/dev/null | head -1)"
    if [[ -f "$OUTPUT_DIR/retis-timing.txt" ]]; then
        echo "  Retis: $(cat "$OUTPUT_DIR/retis-timing.txt" 2>/dev/null | head -1)"
    fi
    echo ""
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Analysis Commands"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "# Compare XFRM state/policy (start vs end):"
echo "diff $OUTPUT_DIR/xfrm-*-start.txt $OUTPUT_DIR/xfrm-*-end.txt"
echo ""
echo "# View XFRM state at start:"
echo "cat $OUTPUT_DIR/xfrm-*-start.txt"
echo ""
echo "# Analyze pcap files (ESP packets):"
echo "tcpdump -r $OUTPUT_DIR/node1-esp.pcap -nn"
echo "tcpdump -r $OUTPUT_DIR/node2-esp.pcap -nn"
echo ""
echo "# Check ESP packet details (SPI, sequence numbers):"
echo "tshark -r $OUTPUT_DIR/node1-esp.pcap -Y 'esp' -T fields -e frame.time -e ip.src -e ip.dst -e esp.spi -e esp.sequence"
echo "tshark -r $OUTPUT_DIR/node2-esp.pcap -Y 'esp' -T fields -e frame.time -e ip.src -e ip.dst -e esp.spi -e esp.sequence"
echo ""
echo "# Compare packet counts between nodes:"
echo "echo \"Node1 ESP packets: \$(tshark -r $OUTPUT_DIR/node1-esp.pcap -Y 'esp' 2>/dev/null | wc -l)\""
echo "echo \"Node2 ESP packets: \$(tshark -r $OUTPUT_DIR/node2-esp.pcap -Y 'esp' 2>/dev/null | wc -l)\""
echo ""
if [[ "$SKIP_RETIS" != "true" ]]; then
    echo "# Analyze ICV failures with Retis (requires retis on macOS via podman):"
    echo "podman run --rm -v $OUTPUT_DIR:/data:ro $RETIS_IMAGE sort /data/retis_icv.data"
    echo "podman run --rm -v $OUTPUT_DIR:/data:ro $RETIS_IMAGE print /data/retis_icv.data"
    echo ""
    echo "# View Retis output log:"
    echo "cat $OUTPUT_DIR/retis-output.log"
    echo ""
fi
echo "# Find matching packets across captures (by ESP sequence number):"
echo "# 1. Find dropped packet sequence in Retis output"
echo "# 2. Search for same sequence in both pcap files"
echo "# 3. Compare packet data for corruption"
echo ""
echo "Done."

