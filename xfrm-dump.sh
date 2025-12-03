#!/bin/bash
#
# XFRM State and Policy Dump Script
# Captures IPsec Security Association and Policy information
#
# Usage:
#   ./xfrm-dump.sh [output_dir]
#
# Example:
#   ./xfrm-dump.sh /tmp/xfrm-dump
#
# Note: XFRM commands are Linux-specific. On macOS or other systems,
#       this script will create placeholder files indicating XFRM
#       dumps should be run on Linux nodes.

set -euo pipefail

# Detect OS
OS="$(uname -s)"
IS_LINUX=false

case "$OS" in
    Linux*)
        IS_LINUX=true
        ;;
esac

OUTPUT_DIR="${1:-/tmp/xfrm-dump-$(date +%Y%m%d-%H%M%S)}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

mkdir -p "$OUTPUT_DIR"

echo "Dumping XFRM state and policy..."
echo "OS: $OS"
echo "Output directory: $OUTPUT_DIR"
echo ""

if [[ "$IS_LINUX" != true ]] || ! command -v ip &> /dev/null; then
    echo "Warning: XFRM commands are Linux-specific and not available on $OS"
    echo "Creating placeholder files. Run this script on a Linux node for actual XFRM dumps."
    echo ""
    echo "XFRM dumps are Linux-specific. Run on Linux nodes for XFRM information." > "$OUTPUT_DIR/xfrm_state_$TIMESTAMP.txt"
    echo "XFRM dumps are Linux-specific. Run on Linux nodes for XFRM information." > "$OUTPUT_DIR/xfrm_policy_$TIMESTAMP.txt"
    echo "XFRM dumps are Linux-specific. Run on Linux nodes for XFRM information." > "$OUTPUT_DIR/xfrm_state_count_$TIMESTAMP.txt"
    echo "XFRM dumps are Linux-specific. Run on Linux nodes for XFRM information." > "$OUTPUT_DIR/xfrm_policy_count_$TIMESTAMP.txt"
else
    # Dump XFRM state
    echo "Capturing XFRM state..."
    ip xfrm state show > "$OUTPUT_DIR/xfrm_state_$TIMESTAMP.txt" 2>&1 || {
        echo "Warning: Failed to dump xfrm state (may not be available)"
        echo "No XFRM state found or IPsec not configured" > "$OUTPUT_DIR/xfrm_state_error_$TIMESTAMP.txt"
    }

    # Dump XFRM policy
    echo "Capturing XFRM policy..."
    ip xfrm policy show > "$OUTPUT_DIR/xfrm_policy_$TIMESTAMP.txt" 2>&1 || {
        echo "Warning: Failed to dump xfrm policy (may not be available)"
        echo "No XFRM policy found or IPsec not configured" > "$OUTPUT_DIR/xfrm_policy_error_$TIMESTAMP.txt"
    }

    # Additional XFRM statistics
    echo "Capturing XFRM statistics..."
    ip xfrm state count > "$OUTPUT_DIR/xfrm_state_count_$TIMESTAMP.txt" 2>&1 || echo "0" > "$OUTPUT_DIR/xfrm_state_count_$TIMESTAMP.txt
    ip xfrm policy count > "$OUTPUT_DIR/xfrm_policy_count_$TIMESTAMP.txt" 2>&1 || echo "0" > "$OUTPUT_DIR/xfrm_policy_count_$TIMESTAMP.txt

    # Show XFRM monitor (if available)
    if command -v ip &> /dev/null && ip xfrm monitor &> /dev/null; then
        echo "Note: Use 'ip xfrm monitor' for real-time XFRM events"
    fi
fi

echo ""
echo "Dump complete. Files saved to: $OUTPUT_DIR"
echo ""
ls -lh "$OUTPUT_DIR"

