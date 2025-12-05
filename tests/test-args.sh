#!/bin/bash
# Unit tests for run-ipsec-diagnostics.sh
# Tests argument parsing, help output, and defaults
# No cluster connection required

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/../run-ipsec-diagnostics.sh"

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

echo "═══════════════════════════════════════════════════════════════════"
echo "Unit Tests: run-ipsec-diagnostics.sh"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

# ============================================================
# Test --help output
# ============================================================
echo "--- Testing --help output ---"
HELP=$(timeout 5 $SCRIPT --help 2>&1 || true)

test_case "--help shows --node1" "--node1" "$HELP"
test_case "--help shows --node2" "--node2" "$HELP"
test_case "--help shows --interface" "--interface" "$HELP"
test_case "--help shows --duration" "--duration" "$HELP"
test_case "--help shows --output" "--output" "$HELP"
test_case "--help shows --filter" "--filter" "$HELP"
test_case "--help shows --skip-retis" "--skip-retis" "$HELP"
test_case "--help shows --retis-node" "--retis-node" "$HELP"
test_case "--help shows --monitor-icv" "--monitor-icv" "$HELP"
test_case "--help shows --icv-threshold" "--icv-threshold" "$HELP"
test_case "--help shows --no-packet-limit" "--no-packet-limit" "$HELP"
test_case "--help shows usage description" "IPsec" "$HELP"
test_case "--help shows captures include" "Captures include" "$HELP"
echo ""

# ============================================================
# Test default values in help
# ============================================================
echo "--- Testing defaults in help ---"
test_case "--help shows default duration 30" "30" "$HELP"
test_case "--help shows default packet count 1000" "1000" "$HELP"
test_case "--help shows default threshold 3" "3" "$HELP"
echo ""

# ============================================================
# Test script structure
# ============================================================
echo "--- Testing script structure ---"
SCRIPT_CONTENT=$(cat "$SCRIPT")

test_case "Script has shebang" "#!/bin/bash" "$SCRIPT_CONTENT"
test_case "Script has set -euo pipefail" "set -euo pipefail" "$SCRIPT_CONTENT"
test_case "Script sources config" "source" "$SCRIPT_CONTENT"
test_case "Script checks oc whoami" "oc whoami" "$SCRIPT_CONTENT"
test_case "Script defines dump_xfrm function" "dump_xfrm()" "$SCRIPT_CONTENT"
test_case "Script defines retrieve_file function" "retrieve_file()" "$SCRIPT_CONTENT"
echo ""

# ============================================================
# Test security patterns
# ============================================================
echo "--- Testing security patterns ---"
test_case "Uses quoted variables" '"$NODE' "$SCRIPT_CONTENT"
test_case "Uses [[ ]] for conditionals" "[[ " "$SCRIPT_CONTENT"
test_case "Has cluster validation" "Not connected to OpenShift" "$SCRIPT_CONTENT"
test_not_contains "No hardcoded passwords" "password=" "$SCRIPT_CONTENT"
test_not_contains "No hardcoded tokens" "token=" "$SCRIPT_CONTENT"
echo ""

# ============================================================
# Test feature completeness
# ============================================================
echo "--- Testing feature completeness ---"
test_case "Has XFRM state dump" "ip xfrm state" "$SCRIPT_CONTENT"
test_case "Has XFRM policy dump" "ip xfrm policy" "$SCRIPT_CONTENT"
test_case "Has tcpdump command" "tcpdump" "$SCRIPT_CONTENT"
test_case "Has Retis integration" "retis" "$SCRIPT_CONTENT"
test_case "Has toolbox usage" "toolbox" "$SCRIPT_CONTENT"
test_case "Has ICV failure probe" "xfrm_audit_state_icvfail" "$SCRIPT_CONTENT"
test_case "Has base64 file retrieval" "base64" "$SCRIPT_CONTENT"
test_case "Has cleanup section" "Cleanup" "$SCRIPT_CONTENT"
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

