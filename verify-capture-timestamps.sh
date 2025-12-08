#!/bin/bash
#
# Verify timestamp alignment across IPsec diagnostic captures
# Analyzes output from run-ipsec-diagnostics.sh
#
# Usage:
#   ./verify-capture-timestamps.sh <output-directory>
#   ./verify-capture-timestamps.sh ~/ipsec-captures/diag-20241205-143022
#

set -euo pipefail

# Color codes
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

usage() {
    echo "Usage: $0 <output-directory>"
    echo ""
    echo "Verifies timestamp alignment across tcpdump and Retis captures."
    echo ""
    echo "Arguments:"
    echo "  output-directory   Path to diag-* directory from run-ipsec-diagnostics.sh"
    echo ""
    echo "Example:"
    echo "  $0 ~/ipsec-captures/diag-20241205-143022"
    echo ""
    exit 1
}

section() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "$1"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
}

check_tool() {
    local tool="$1"
    if ! command -v "$tool" &>/dev/null; then
        echo -e "${RED}Error: $tool is required but not installed${NC}" >&2
        return 1
    fi
}

# Parse arguments
if [[ $# -lt 1 ]]; then
    usage
fi

OUTPUT_DIR="$1"

# Validate output directory
if [[ ! -d "$OUTPUT_DIR" ]]; then
    echo -e "${RED}Error: Directory not found: $OUTPUT_DIR${NC}" >&2
    exit 1
fi

# Check required tools
MISSING_TOOLS=0
for tool in tshark bc; do
    if ! check_tool "$tool"; then
        MISSING_TOOLS=1
    fi
done

if [[ $MISSING_TOOLS -eq 1 ]]; then
    echo ""
    echo "Install missing tools:"
    echo "  macOS:          brew install wireshark"
    echo "  RHEL 9/Fedora:  sudo dnf install wireshark-cli bc"
    echo "  Debian/Ubuntu:  sudo apt install tshark bc"
    exit 1
fi

# Track verification results
CHECK_FILES="SKIP"
CHECK_TIMING="SKIP"
CHECK_CLOCK_SYNC="SKIP"
CHECK_PACKET_COUNT="SKIP"
CHECK_RETIS="SKIP"

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║          Capture Timestamp Verification                       ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""
echo "Analyzing: $OUTPUT_DIR"

# ============================================================
# Check available files
# ============================================================
section "Available Capture Files"

REQUIRED_FILES_FOUND=0
REQUIRED_FILES_TOTAL=4  # node1-esp.pcap, node2-esp.pcap, node1-timing.txt, node2-timing.txt

for file in node1-esp.pcap node2-esp.pcap node1-timing.txt node2-timing.txt \
            retis_icv.data retis-timing.txt sync-time.txt; do
    if [[ -f "$OUTPUT_DIR/$file" ]]; then
        SIZE=$(ls -lh "$OUTPUT_DIR/$file" | awk '{print $5}')
        echo -e "  ${GREEN}✓${NC} $file ($SIZE)"
        # Count required files
        case "$file" in
            node1-esp.pcap|node2-esp.pcap|node1-timing.txt|node2-timing.txt)
                ((REQUIRED_FILES_FOUND++)) || true
                ;;
        esac
    else
        echo -e "  ${YELLOW}✗${NC} $file (not found)"
    fi
done

if [[ $REQUIRED_FILES_FOUND -eq $REQUIRED_FILES_TOTAL ]]; then
    CHECK_FILES="PASS"
else
    CHECK_FILES="FAIL"
fi

# ============================================================
# Timing Files Analysis
# ============================================================
section "Capture Start/End Times"

echo "From timing files (ISO-8601 format):"
echo ""

if [[ -f "$OUTPUT_DIR/sync-time.txt" ]]; then
    SYNC_TIME=$(cat "$OUTPUT_DIR/sync-time.txt" 2>/dev/null || echo "N/A")
    echo "  Script sync time: $SYNC_TIME"
fi

if [[ -f "$OUTPUT_DIR/node1-timing.txt" ]]; then
    NODE1_START=$(grep 'START:' "$OUTPUT_DIR/node1-timing.txt" 2>/dev/null | head -1 | sed 's/START: *//' || echo "N/A")
    NODE1_END=$(grep 'END:' "$OUTPUT_DIR/node1-timing.txt" 2>/dev/null | head -1 | sed 's/END: *//' || echo "N/A")
    echo "  Node1 START: $NODE1_START"
    echo "  Node1 END:   $NODE1_END"
fi

if [[ -f "$OUTPUT_DIR/node2-timing.txt" ]]; then
    NODE2_START=$(grep 'START:' "$OUTPUT_DIR/node2-timing.txt" 2>/dev/null | head -1 | sed 's/START: *//' || echo "N/A")
    NODE2_END=$(grep 'END:' "$OUTPUT_DIR/node2-timing.txt" 2>/dev/null | head -1 | sed 's/END: *//' || echo "N/A")
    echo "  Node2 START: $NODE2_START"
    echo "  Node2 END:   $NODE2_END"
fi

if [[ -f "$OUTPUT_DIR/retis-timing.txt" ]]; then
    RETIS_START=$(grep 'START:' "$OUTPUT_DIR/retis-timing.txt" 2>/dev/null | head -1 | sed 's/START: *//' || echo "N/A")
    RETIS_END=$(grep 'END:' "$OUTPUT_DIR/retis-timing.txt" 2>/dev/null | head -1 | sed 's/END: *//' || echo "N/A")
    echo "  Retis START: $RETIS_START"
    echo "  Retis END:   $RETIS_END"
fi

# Check if timing data was found
if [[ -f "$OUTPUT_DIR/node1-timing.txt" ]] && [[ -f "$OUTPUT_DIR/node2-timing.txt" ]]; then
    CHECK_TIMING="PASS"
else
    CHECK_TIMING="FAIL"
fi

# ============================================================
# PCAP Timestamp Analysis
# ============================================================
section "PCAP Packet Timestamps"

analyze_pcap() {
    local pcap_file="$1"
    local label="$2"
    
    if [[ ! -f "$pcap_file" ]]; then
        echo "  $label: file not found"
        return 1
    fi
    
    local pkt_count
    pkt_count=$(tshark -r "$pcap_file" 2>/dev/null | wc -l | tr -d ' ')
    
    if [[ "$pkt_count" -eq 0 ]]; then
        echo "  $label: no packets captured"
        return 1
    fi
    
    local first_ts last_ts first_time last_time
    first_ts=$(tshark -r "$pcap_file" -c 1 -T fields -e frame.time_epoch 2>/dev/null | head -1)
    last_ts=$(tshark -r "$pcap_file" -T fields -e frame.time_epoch 2>/dev/null | tail -1)
    first_time=$(tshark -r "$pcap_file" -c 1 -T fields -e frame.time 2>/dev/null | head -1)
    last_time=$(tshark -r "$pcap_file" -T fields -e frame.time 2>/dev/null | tail -1)
    
    echo "  $label:"
    echo "    Packets: $pkt_count"
    echo "    First:   $first_time (epoch: $first_ts)"
    echo "    Last:    $last_time (epoch: $last_ts)"
    
    # Return epoch timestamps for comparison
    echo "$first_ts $last_ts"
}

echo "Analyzing pcap files..."
echo ""

NODE1_TS=""
NODE2_TS=""

if [[ -f "$OUTPUT_DIR/node1-esp.pcap" ]]; then
    NODE1_TS=$(analyze_pcap "$OUTPUT_DIR/node1-esp.pcap" "Node1" | tail -1)
fi

echo ""

if [[ -f "$OUTPUT_DIR/node2-esp.pcap" ]]; then
    NODE2_TS=$(analyze_pcap "$OUTPUT_DIR/node2-esp.pcap" "Node2" | tail -1)
fi

# ============================================================
# Capture Start Time Alignment
# ============================================================
section "Capture Start Alignment"

echo "Note: This measures when each capture STARTED, not NTP clock accuracy."
echo "      Differences are normal due to oc debug startup timing variance."
echo ""

if [[ -n "$NODE1_TS" ]] && [[ -n "$NODE2_TS" ]]; then
    NODE1_FIRST=$(echo "$NODE1_TS" | awk '{print $1}')
    NODE2_FIRST=$(echo "$NODE2_TS" | awk '{print $1}')
    
    if [[ -n "$NODE1_FIRST" ]] && [[ -n "$NODE2_FIRST" ]]; then
        # Calculate difference in milliseconds
        DIFF_SEC=$(echo "$NODE2_FIRST - $NODE1_FIRST" | bc 2>/dev/null || echo "N/A")
        
        if [[ "$DIFF_SEC" != "N/A" ]]; then
            DIFF_MS=$(echo "$DIFF_SEC * 1000" | bc 2>/dev/null | cut -d. -f1)
            ABS_DIFF=$(echo "$DIFF_SEC" | tr -d '-')
            
            echo "First packet timestamp difference (Node2 - Node1):"
            echo "  Difference: ${DIFF_SEC}s (${DIFF_MS}ms)"
            echo ""
            
            # Evaluate capture alignment (more lenient - this is informational)
            if (( $(echo "$ABS_DIFF < 1.0" | bc -l) )); then
                echo -e "  ${GREEN}✓ Good alignment${NC} (<1s difference)"
                CHECK_CLOCK_SYNC="PASS"
            elif (( $(echo "$ABS_DIFF < 5.0" | bc -l) )); then
                echo -e "  ${GREEN}✓ Acceptable alignment${NC} (<5s difference)"
                CHECK_CLOCK_SYNC="PASS"
            elif (( $(echo "$ABS_DIFF < 10.0" | bc -l) )); then
                echo -e "  ${YELLOW}⚠ Large offset${NC} (<10s - captures may have limited overlap)"
                CHECK_CLOCK_SYNC="WARN"
            else
                echo -e "  ${RED}✗ Very large offset${NC} (>10s - captures may not overlap)"
                CHECK_CLOCK_SYNC="FAIL"
            fi
            
            echo ""
            echo "  To verify actual NTP sync, run on nodes:"
            echo "    chronyc tracking | grep 'System time'"
        fi
    fi
else
    echo "Cannot calculate - missing pcap data"
    CHECK_CLOCK_SYNC="SKIP"
fi

# ============================================================
# ESP Sequence Number Correlation
# ============================================================
section "ESP Packet Correlation (by SPI + Sequence)"

if [[ -f "$OUTPUT_DIR/node1-esp.pcap" ]] && [[ -f "$OUTPUT_DIR/node2-esp.pcap" ]]; then
    echo "Extracting ESP packets for correlation..."
    echo ""
    
    # Get unique SPIs from both captures
    NODE1_SPIS=$(tshark -r "$OUTPUT_DIR/node1-esp.pcap" -Y 'esp' -T fields -e esp.spi 2>/dev/null | sort -u | head -5)
    NODE2_SPIS=$(tshark -r "$OUTPUT_DIR/node2-esp.pcap" -Y 'esp' -T fields -e esp.spi 2>/dev/null | sort -u | head -5)
    
    echo "SPIs found in Node1: $(echo "$NODE1_SPIS" | tr '\n' ' ')"
    echo "SPIs found in Node2: $(echo "$NODE2_SPIS" | tr '\n' ' ')"
    echo ""
    
    # Find common sequences for correlation
    echo "Sample packets from Node1 (first 5):"
    tshark -r "$OUTPUT_DIR/node1-esp.pcap" -Y 'esp' -c 5 -T fields \
        -e frame.time_relative -e ip.src -e ip.dst -e esp.spi -e esp.sequence 2>/dev/null | \
        awk '{printf "  Time: %8.6fs | %s -> %s | SPI: %s | Seq: %s\n", $1, $2, $3, $4, $5}'
    
    echo ""
    echo "Sample packets from Node2 (first 5):"
    tshark -r "$OUTPUT_DIR/node2-esp.pcap" -Y 'esp' -c 5 -T fields \
        -e frame.time_relative -e ip.src -e ip.dst -e esp.spi -e esp.sequence 2>/dev/null | \
        awk '{printf "  Time: %8.6fs | %s -> %s | SPI: %s | Seq: %s\n", $1, $2, $3, $4, $5}'
    
    echo ""
    
    # Count packets per node
    NODE1_COUNT=$(tshark -r "$OUTPUT_DIR/node1-esp.pcap" -Y 'esp' 2>/dev/null | wc -l | tr -d ' ')
    NODE2_COUNT=$(tshark -r "$OUTPUT_DIR/node2-esp.pcap" -Y 'esp' 2>/dev/null | wc -l | tr -d ' ')
    
    echo "ESP Packet counts:"
    echo "  Node1: $NODE1_COUNT packets"
    echo "  Node2: $NODE2_COUNT packets"
    
    if [[ "$NODE1_COUNT" -ne "$NODE2_COUNT" ]]; then
        DIFF=$((NODE1_COUNT - NODE2_COUNT))
        if [[ $DIFF -gt 0 ]]; then
            echo -e "  ${YELLOW}⚠ Node1 has $DIFF more packets than Node2${NC}"
        else
            echo -e "  ${YELLOW}⚠ Node2 has $((-DIFF)) more packets than Node1${NC}"
        fi
        CHECK_PACKET_COUNT="WARN"
    else
        echo -e "  ${GREEN}✓ Packet counts match${NC}"
        CHECK_PACKET_COUNT="PASS"
    fi
else
    CHECK_PACKET_COUNT="SKIP"
fi

# ============================================================
# Retis Data Check
# ============================================================
if [[ -f "$OUTPUT_DIR/retis_icv.data" ]]; then
    section "Retis Data Analysis"
    
    RETIS_SIZE=$(ls -lh "$OUTPUT_DIR/retis_icv.data" | awk '{print $5}')
    echo "Retis data file size: $RETIS_SIZE"
    echo ""
    
    # Extract probe name from retis-timing.txt if available
    RETIS_PROBE=""
    if [[ -f "$OUTPUT_DIR/retis-timing.txt" ]]; then
        RETIS_PROBE=$(grep 'PROBE:' "$OUTPUT_DIR/retis-timing.txt" 2>/dev/null | sed 's/PROBE: *//' | head -1 || echo "")
    fi
    # Fallback to environment variable or default
    RETIS_PROBE="${RETIS_PROBE:-${RETIS_PROBE_ENV:-xfrm_audit_state_icvfail/stack}}"
    # Extract base probe name (before /stack if present)
    PROBE_BASE="${RETIS_PROBE%%/*}"
    
    echo "Retis probe used: $RETIS_PROBE"
    echo ""
    
    if [[ -f "$OUTPUT_DIR/retis-output.log" ]]; then
        echo "Retis output log (last 10 lines):"
        tail -10 "$OUTPUT_DIR/retis-output.log" | sed 's/^/  /'
        echo ""
    fi
    
    CHECK_RETIS="PASS"
fi

# ============================================================
# Retis PCAP Correlation
# ============================================================
if [[ -f "$OUTPUT_DIR/retis_icv.data" ]]; then
    section "Retis PCAP Correlation"
    
    RETIS_IMAGE="${RETIS_IMAGE:-quay.io/retis/retis}"
    RETIS_PCAP="$OUTPUT_DIR/retis-extracted.pcap"
    
    # Use probe base name for pcap extraction
    PROBE_FOR_PCAP="${PROBE_BASE:-xfrm_audit_state_icvfail}"
    
    echo "Generating pcap from Retis data..."
    echo "  Image: $RETIS_IMAGE"
    echo "  Probe: $PROBE_FOR_PCAP"
    echo ""
    
    # Check if podman is available
    if ! command -v podman &>/dev/null; then
        echo -e "  ${YELLOW}⚠${NC} podman not available - skipping Retis pcap generation"
        echo "  Install podman or run manually:"
        echo "    podman run --rm -v $OUTPUT_DIR:/data:rw $RETIS_IMAGE pcap --probe $PROBE_FOR_PCAP -o /data/retis-extracted.pcap /data/retis_icv.data"
    else
        # Generate pcap from Retis data
        # Syntax: retis pcap --probe <probe> -o <output.pcap> <input.data>
        PCAP_OUTPUT=$(podman run --rm -v "$OUTPUT_DIR":/data:rw "$RETIS_IMAGE" \
            pcap --probe "$PROBE_FOR_PCAP" -o /data/retis-extracted.pcap /data/retis_icv.data 2>&1) || true
        
        if [[ -s "$RETIS_PCAP" ]]; then
            RETIS_PCAP_SIZE=$(ls -lh "$RETIS_PCAP" | awk '{print $5}')
            RETIS_PKT_COUNT=$(tshark -r "$RETIS_PCAP" 2>/dev/null | wc -l | tr -d ' ' || echo "0")
            
            echo -e "  ${GREEN}✓${NC} Generated retis-extracted.pcap ($RETIS_PCAP_SIZE)"
            echo "  Packets in Retis pcap: $RETIS_PKT_COUNT"
            echo ""
            
            if [[ "$RETIS_PKT_COUNT" -gt 0 ]]; then
                echo "Sample packets from Retis pcap (first 5):"
                tshark -r "$RETIS_PCAP" -c 5 2>/dev/null | sed 's/^/    /' || true
                echo ""
                
                # Determine test vs production mode
                if [[ "$PROBE_FOR_PCAP" == *"netif_receive_skb"* ]]; then
                    echo -e "  ${GREEN}ℹ${NC}  TEST MODE: Retis captured all received packets"
                    echo "     These should correlate with tcpdump captures."
                    
                    # In test mode, compare packet counts
                    if [[ -n "$NODE1_COUNT" ]] && [[ -n "$NODE2_COUNT" ]]; then
                        echo ""
                        echo "  Packet count comparison:"
                        echo "    Node1 tcpdump:  $NODE1_COUNT ESP packets"
                        echo "    Node2 tcpdump:  $NODE2_COUNT ESP packets"
                        echo "    Retis capture:  $RETIS_PKT_COUNT packets (includes non-ESP)"
                        
                        if [[ "$RETIS_PKT_COUNT" -ge "$NODE2_COUNT" ]]; then
                            echo -e "    ${GREEN}✓${NC} Retis captured >= tcpdump packets (expected in test mode)"
                        else
                            echo -e "    ${YELLOW}⚠${NC} Retis captured fewer packets than tcpdump"
                        fi
                    fi
                else
                    echo -e "  ${GREEN}ℹ${NC}  PRODUCTION MODE: Retis captured dropped packets only"
                    echo "     These packets were dropped due to ICV failure and should NOT"
                    echo "     appear in the receiver's (Node2) tcpdump capture."
                    
                    if [[ "$NODE1_COUNT" -gt "$NODE2_COUNT" ]]; then
                        MISSING=$((NODE1_COUNT - NODE2_COUNT))
                        echo ""
                        echo "  Correlation analysis:"
                        echo "    Node1 sent:        $NODE1_COUNT ESP packets"
                        echo "    Node2 received:    $NODE2_COUNT ESP packets"
                        echo "    Missing (dropped): $MISSING packets"
                        echo "    Retis captured:    $RETIS_PKT_COUNT dropped packets"
                        
                        if [[ "$RETIS_PKT_COUNT" -gt 0 ]] && [[ "$RETIS_PKT_COUNT" -le "$MISSING" ]]; then
                            echo -e "    ${GREEN}✓${NC} Retis captured dropped packets (within expected range)"
                        elif [[ "$RETIS_PKT_COUNT" -eq 0 ]]; then
                            echo -e "    ${YELLOW}⚠${NC} Retis captured 0 drops but packets are missing"
                        fi
                    fi
                fi
                CHECK_RETIS="PASS"
            else
                echo -e "  ${YELLOW}⚠${NC} No packets in Retis pcap"
                if [[ "$PROBE_FOR_PCAP" == *"netif_receive_skb"* ]]; then
                    echo "     This is unexpected in test mode - check Retis logs"
                    CHECK_RETIS="WARN"
                else
                    echo "     This may be normal if no ICV failures occurred during capture"
                    CHECK_RETIS="PASS"
                fi
            fi
        else
            echo -e "  ${YELLOW}⚠${NC} Could not generate pcap from Retis data"
            if [[ -n "$PCAP_OUTPUT" ]]; then
                echo "  Output: $PCAP_OUTPUT"
            fi
            echo ""
            echo "  Run manually to debug:"
            echo "    podman run --rm -v $OUTPUT_DIR:/data:rw $RETIS_IMAGE pcap --probe $PROBE_FOR_PCAP -o /data/retis-extracted.pcap /data/retis_icv.data"
            CHECK_RETIS="WARN"
        fi
    fi
    
    echo ""
    echo "Additional Retis analysis commands:"
    echo "  podman run --rm -v $OUTPUT_DIR:/data:ro $RETIS_IMAGE sort /data/retis_icv.data"
    echo "  podman run --rm -v $OUTPUT_DIR:/data:ro $RETIS_IMAGE print /data/retis_icv.data"
fi

# ============================================================
# Correlation Commands
# ============================================================
section "Manual Correlation Commands"

echo "# Find specific ESP sequence in both captures:"
echo "SEQ=<sequence_number>"
echo "tshark -r $OUTPUT_DIR/node1-esp.pcap -Y \"esp.sequence == \$SEQ\" -T fields -e frame.time -e esp.spi -e esp.sequence"
echo "tshark -r $OUTPUT_DIR/node2-esp.pcap -Y \"esp.sequence == \$SEQ\" -T fields -e frame.time -e esp.spi -e esp.sequence"
echo ""

echo "# Export ESP sequence numbers for diff analysis:"
echo "tshark -r $OUTPUT_DIR/node1-esp.pcap -Y 'esp' -T fields -e esp.spi -e esp.sequence | sort > /tmp/node1-seq.txt"
echo "tshark -r $OUTPUT_DIR/node2-esp.pcap -Y 'esp' -T fields -e esp.spi -e esp.sequence | sort > /tmp/node2-seq.txt"
echo "diff /tmp/node1-seq.txt /tmp/node2-seq.txt"
echo ""

echo "# Find missing sequences (packets dropped between nodes):"
echo "comm -23 /tmp/node1-seq.txt /tmp/node2-seq.txt  # In Node1 but not Node2"
echo "comm -13 /tmp/node1-seq.txt /tmp/node2-seq.txt  # In Node2 but not Node1"
echo ""

if [[ -f "$OUTPUT_DIR/retis-extracted.pcap" ]]; then
    echo "# Correlate Retis captured drops with tcpdump:"
    echo "# Extract sequences from Retis pcap (dropped packets):"
    echo "tshark -r $OUTPUT_DIR/retis-extracted.pcap -Y 'esp' -T fields -e esp.spi -e esp.sequence | sort > /tmp/retis-seq.txt"
    echo ""
    echo "# Verify dropped packets are in Node1 but not Node2:"
    echo "# (Retis drops should match: in node1, missing from node2)"
    echo "while read spi seq; do"
    echo "  echo \"Checking SPI=\$spi SEQ=\$seq\""
    echo "  echo \"  Node1:\"; tshark -r $OUTPUT_DIR/node1-esp.pcap -Y \"esp.spi==\$spi && esp.sequence==\$seq\" -c 1 2>/dev/null | head -1"
    echo "  echo \"  Node2:\"; tshark -r $OUTPUT_DIR/node2-esp.pcap -Y \"esp.spi==\$spi && esp.sequence==\$seq\" -c 1 2>/dev/null | head -1"
    echo "done < /tmp/retis-seq.txt"
    echo ""
fi

# ============================================================
# Final Summary
# ============================================================
section "Verification Summary"

# Helper function to format status
format_status() {
    local status="$1"
    case "$status" in
        PASS) echo -e "${GREEN}PASS${NC}" ;;
        WARN) echo -e "${YELLOW}WARN${NC}" ;;
        FAIL) echo -e "${RED}FAIL${NC}" ;;
        SKIP) echo -e "${YELLOW}SKIP${NC}" ;;
        *)    echo "$status" ;;
    esac
}

echo "  Capture Files Present:    $(format_status "$CHECK_FILES")"
echo "  Timing Data Available:    $(format_status "$CHECK_TIMING")"
echo "  Capture Start Alignment:  $(format_status "$CHECK_CLOCK_SYNC")"
echo "  Packet Count Match:       $(format_status "$CHECK_PACKET_COUNT")"
echo "  Retis Data Available:     $(format_status "$CHECK_RETIS")"
echo ""

# Calculate overall status
FAIL_COUNT=0
WARN_COUNT=0
PASS_COUNT=0

for check in "$CHECK_FILES" "$CHECK_TIMING" "$CHECK_CLOCK_SYNC" "$CHECK_PACKET_COUNT"; do
    case "$check" in
        PASS) ((PASS_COUNT++)) || true ;;
        WARN) ((WARN_COUNT++)) || true ;;
        FAIL) ((FAIL_COUNT++)) || true ;;
    esac
done

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [[ $FAIL_COUNT -eq 0 ]] && [[ $WARN_COUNT -eq 0 ]]; then
    echo -e "  ${GREEN}✓ ALL CHECKS PASSED${NC}"
    OVERALL_EXIT=0
elif [[ $FAIL_COUNT -eq 0 ]]; then
    echo -e "  ${YELLOW}⚠ PASSED WITH WARNINGS${NC} ($WARN_COUNT warnings)"
    OVERALL_EXIT=0
else
    echo -e "  ${RED}✗ SOME CHECKS FAILED${NC} ($FAIL_COUNT failed, $WARN_COUNT warnings)"
    OVERALL_EXIT=1
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Output directory: $OUTPUT_DIR"
echo ""

exit $OVERALL_EXIT

