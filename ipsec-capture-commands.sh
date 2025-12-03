#!/bin/bash
#
# Generate IPsec Capture Commands
# Outputs the exact commands to run in separate terminals
#

NODE1="${1:-worker1.example.com}"
NODE2="${2:-worker2.example.com}"
INTERFACE="${3:-br-ex}"

# Get IPs
NODE1_IP=$(oc get node "$NODE1" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)
NODE2_IP=$(oc get node "$NODE2" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)

if [[ -z "$NODE1_IP" ]] || [[ -z "$NODE2_IP" ]]; then
    echo "Error: Could not get node IPs. Check node names."
    echo "Available nodes:"
    oc get nodes -o wide
    exit 1
fi

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
OUTPUT_DIR="/tmp/ipsec-capture-${TIMESTAMP}"

cat << EOF
================================================================================
                        IPsec Capture Commands
================================================================================

Node 1: $NODE1 ($NODE1_IP)
Node 2: $NODE2 ($NODE2_IP)
Interface: $INTERFACE
Output: $OUTPUT_DIR

================================================================================
STEP 1: Open TWO separate terminal windows
================================================================================

================================================================================
STEP 2: Run these commands (one per terminal)
================================================================================

--- TERMINAL 1 ($NODE1) ---
oc debug -t node/$NODE1 --to-namespace=default
# Wait for shell, then run:
chroot /host
mkdir -p ${OUTPUT_DIR}
toolbox
tcpdump -nn -s0 -i $INTERFACE -w /host${OUTPUT_DIR}/host1.pcap 'host $NODE1_IP and host $NODE2_IP and proto esp'

--- TERMINAL 2 ($NODE2) ---
oc debug -t node/$NODE2 --to-namespace=default
# Wait for shell, then run:
chroot /host
mkdir -p ${OUTPUT_DIR}
toolbox
tcpdump -nn -s0 -i $INTERFACE -w /host${OUTPUT_DIR}/host2.pcap 'host $NODE1_IP and host $NODE2_IP and proto esp'

================================================================================
STEP 3: Generate traffic, then press Ctrl+C in both terminals to stop
================================================================================

================================================================================
STEP 4: Retrieve the capture files
================================================================================

mkdir -p /tmp/ipsec-captures

# From host1:
oc debug node/$NODE1 --to-namespace=default -- chroot /host bash -c 'cat ${OUTPUT_DIR}/host1.pcap' > /tmp/ipsec-captures/host1.pcap

# From host2:  
oc debug node/$NODE2 --to-namespace=default -- chroot /host bash -c 'cat ${OUTPUT_DIR}/host2.pcap' > /tmp/ipsec-captures/host2.pcap

# Check files:
ls -lh /tmp/ipsec-captures/

================================================================================
EOF

