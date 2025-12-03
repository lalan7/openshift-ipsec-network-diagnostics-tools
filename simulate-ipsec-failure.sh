#!/bin/bash
#
# IPsec Integrity Failure Simulation Script
# Simulates packet corruption to trigger SA-icv-failure errors
#
# WARNING: This script modifies network packets and should only be used
# in a test environment. Use with caution!
#
# Usage:
#   ./simulate-ipsec-failure.sh <interface> <target_host> [corruption_rate]
#
# Example:
#   ./simulate-ipsec-failure.sh br-ex 10.75.126.30 0.01

set -euo pipefail

INTERFACE="${1:-}"
TARGET_HOST="${2:-}"
CORRUPTION_RATE="${3:-0.01}"  # 1% packet corruption by default

if [[ -z "$INTERFACE" || -z "$TARGET_HOST" ]]; then
    echo "Error: Missing required arguments"
    echo "Usage: $0 <interface> <target_host> [corruption_rate]"
    echo "Example: $0 br-ex 10.75.126.30 0.01"
    exit 1
fi

if [[ $EUID -ne 0 ]]; then
    echo "Error: This script must be run as root"
    exit 1
fi

# Check if tc (traffic control) is available
if ! command -v tc &> /dev/null; then
    echo "Error: tc (traffic control) not found"
    echo "Install iproute-tc package"
    exit 1
fi

echo "=== IPsec Integrity Failure Simulation ==="
echo "Interface: $INTERFACE"
echo "Target host: $TARGET_HOST"
echo "Corruption rate: $CORRUPTION_RATE"
echo ""
echo "WARNING: This will corrupt packets to simulate IPsec failures!"
echo "Press Ctrl+C to stop and cleanup"

# Function to cleanup on exit
cleanup() {
    echo ""
    echo "Cleaning up traffic control rules..."
    tc qdisc del dev "$INTERFACE" root 2>/dev/null || true
    echo "Cleanup complete"
}

trap cleanup EXIT INT TERM

# Create qdisc for packet corruption
echo "Setting up packet corruption on $INTERFACE..."
tc qdisc add dev "$INTERFACE" root netem corrupt "$CORRUPTION_RATE%" || {
    echo "Error: Failed to set up packet corruption"
    echo "Make sure the interface exists and tc netem is available"
    exit 1
}

echo "Packet corruption active. Monitoring for SA-icv-failure errors..."
echo "Watch logs with: journalctl -k -f | grep -i 'icv\|xfrm'"
echo ""

# Monitor for errors
while true; do
    if journalctl -k --since "10 seconds ago" | grep -qi "SA-icv-failure\|xfrm_audit_state_icvfail"; then
        echo "$(date): SA-icv-failure detected!"
    fi
    sleep 5
done

