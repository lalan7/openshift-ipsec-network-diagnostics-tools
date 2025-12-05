#!/bin/bash
# Unit tests for verify-capture-timestamps.sh
# Tests argument parsing, help output, and verification logic
# No cluster connection required

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/../verify-capture-timestamps.sh"

PASS=0
FAIL=0

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

test_case() {
    local name="$1"
    local expected="$2"
    local actual="$3"
    if [[ "$actual" == *"$expected"* ]]; then
        echo -e "${GREEN}✓${NC} $name"
        PASS=$((PASS + 1))
    else
        echo -e "${RED}✗${NC} $name"
        echo "  Expected: '$expected'"
        echo "  Got: '$actual'"
        FAIL=$((FAIL + 1))
    fi
}

test_not_contains() {
    local name="$1"
    local not_expected="$2"
    local actual="$3"
    if [[ "$actual" != *"$not_expected"* ]]; then
        echo -e "${GREEN}✓${NC} $name"
        PASS=$((PASS + 1))
    else
        echo -e "${RED}✗${NC} $name"
        echo "  Should NOT contain: '$not_expected'"
        FAIL=$((FAIL + 1))
    fi
}

test_exit_code() {
    local name="$1"
    local expected_code="$2"
    local actual_code="$3"
    if [[ "$actual_code" -eq "$expected_code" ]]; then
        echo -e "${GREEN}✓${NC} $name"
        PASS=$((PASS + 1))
    else
        echo -e "${RED}✗${NC} $name"
        echo "  Expected exit code: $expected_code"
        echo "  Got: $actual_code"
        FAIL=$((FAIL + 1))
    fi
}

echo "═══════════════════════════════════════════════════════════════════"
echo "Unit Tests: verify-capture-timestamps.sh"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

# ============================================================
# Test help/usage output
# ============================================================
echo "--- Testing usage output ---"
USAGE=$(timeout 5 $SCRIPT 2>&1 || true)

test_case "Usage shows output-directory" "output-directory" "$USAGE"
test_case "Usage shows example" "Example:" "$USAGE"
test_case "Usage shows diag path example" "diag-" "$USAGE"
echo ""

# ============================================================
# Test script structure
# ============================================================
echo "--- Testing script structure ---"
SCRIPT_CONTENT=$(cat "$SCRIPT")

test_case "Script has shebang" "#!/bin/bash" "$SCRIPT_CONTENT"
test_case "Script has set -euo pipefail" "set -euo pipefail" "$SCRIPT_CONTENT"
test_case "Script defines section function" "section()" "$SCRIPT_CONTENT"
test_case "Script defines check_tool function" "check_tool()" "$SCRIPT_CONTENT"
test_case "Script defines analyze_pcap function" "analyze_pcap()" "$SCRIPT_CONTENT"
test_case "Script defines format_status function" "format_status()" "$SCRIPT_CONTENT"
echo ""

# ============================================================
# Test security patterns
# ============================================================
echo "--- Testing security patterns ---"
test_case "Uses quoted variables" '"$OUTPUT_DIR' "$SCRIPT_CONTENT"
test_case "Uses [[ ]] for conditionals" "[[ " "$SCRIPT_CONTENT"
test_case "Validates directory exists" "Directory not found" "$SCRIPT_CONTENT"
test_not_contains "No hardcoded passwords" "password=" "$SCRIPT_CONTENT"
test_not_contains "No hardcoded tokens" "token=" "$SCRIPT_CONTENT"
echo ""

# ============================================================
# Test verification features
# ============================================================
echo "--- Testing verification features ---"
test_case "Checks for node1-esp.pcap" "node1-esp.pcap" "$SCRIPT_CONTENT"
test_case "Checks for node2-esp.pcap" "node2-esp.pcap" "$SCRIPT_CONTENT"
test_case "Checks for timing files" "timing.txt" "$SCRIPT_CONTENT"
test_case "Checks for retis data" "retis_icv.data" "$SCRIPT_CONTENT"
test_case "Has capture alignment analysis" "Capture Start Alignment" "$SCRIPT_CONTENT"
test_case "Has ESP correlation" "ESP Packet Correlation" "$SCRIPT_CONTENT"
test_case "Uses tshark for analysis" "tshark" "$SCRIPT_CONTENT"
test_case "Calculates timestamp difference" "bc" "$SCRIPT_CONTENT"
echo ""

# ============================================================
# Test summary output
# ============================================================
echo "--- Testing summary output ---"
test_case "Has verification summary section" "Verification Summary" "$SCRIPT_CONTENT"
test_case "Tracks CHECK_FILES status" "CHECK_FILES" "$SCRIPT_CONTENT"
test_case "Tracks CHECK_TIMING status" "CHECK_TIMING" "$SCRIPT_CONTENT"
test_case "Tracks CHECK_CLOCK_SYNC status" "CHECK_CLOCK_SYNC" "$SCRIPT_CONTENT"
test_case "Tracks CHECK_PACKET_COUNT status" "CHECK_PACKET_COUNT" "$SCRIPT_CONTENT"
test_case "Shows ALL CHECKS PASSED" "ALL CHECKS PASSED" "$SCRIPT_CONTENT"
test_case "Shows SOME CHECKS FAILED" "SOME CHECKS FAILED" "$SCRIPT_CONTENT"
test_case "Shows PASSED WITH WARNINGS" "PASSED WITH WARNINGS" "$SCRIPT_CONTENT"
echo ""

# ============================================================
# Test exit codes
# ============================================================
echo "--- Testing exit codes ---"

# Test with non-existent directory (should fail)
$SCRIPT /nonexistent/path 2>&1 || EXIT_CODE=$?
test_exit_code "Non-existent directory returns exit code 1" 1 "${EXIT_CODE:-0}"

# Test with empty directory (should fail due to missing files)
TEMP_DIR=$(mktemp -d)
$SCRIPT "$TEMP_DIR" 2>&1 || EXIT_CODE=$?
test_exit_code "Empty directory returns exit code 1" 1 "${EXIT_CODE:-0}"
rm -rf "$TEMP_DIR"
echo ""

# ============================================================
# Test with mock capture data
# ============================================================
echo "--- Testing with mock capture data ---"

# Create mock capture directory
MOCK_DIR=$(mktemp -d)
touch "$MOCK_DIR/node1-esp.pcap"
touch "$MOCK_DIR/node2-esp.pcap"
echo "START: 2024-12-05T14:30:22-05:00" > "$MOCK_DIR/node1-timing.txt"
echo "END: 2024-12-05T14:31:22-05:00" >> "$MOCK_DIR/node1-timing.txt"
echo "START: 2024-12-05T14:30:22-05:00" > "$MOCK_DIR/node2-timing.txt"
echo "END: 2024-12-05T14:31:22-05:00" >> "$MOCK_DIR/node2-timing.txt"
echo "2024-12-05T14:30:20-05:00" > "$MOCK_DIR/sync-time.txt"

# Run verification and capture full output (may fail due to empty pcap files)
# Redirect stderr to stdout and use cat to ensure full capture
OUTPUT=$($SCRIPT "$MOCK_DIR" 2>&1; echo "---END---")

test_case "Detects node1-esp.pcap file" "node1-esp.pcap" "$OUTPUT"
test_case "Detects node2-esp.pcap file" "node2-esp.pcap" "$OUTPUT"
test_case "Shows timing START times" "Node1 START:" "$OUTPUT"
test_case "Shows Available Capture Files section" "Available Capture Files" "$OUTPUT"

# Cleanup
rm -rf "$MOCK_DIR"
echo ""

# ============================================================
# Summary
# ============================================================
echo "═══════════════════════════════════════════════════════════════════"
echo -e "Results: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC}"
echo "═══════════════════════════════════════════════════════════════════"

if [[ $FAIL -gt 0 ]]; then
    exit 1
fi

