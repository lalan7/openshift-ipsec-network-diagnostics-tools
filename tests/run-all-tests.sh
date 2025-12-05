#!/bin/bash
# Test runner for run-ipsec-diagnostics.sh
# Usage:
#   ./run-all-tests.sh           # Run unit tests only
#   ./run-all-tests.sh --e2e     # Run unit + e2e tests
#   ./run-all-tests.sh --help    # Show help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

RUN_E2E=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --e2e) RUN_E2E=true; shift ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --e2e   Run E2E tests (requires cluster connection and test-config.env)"
            echo "  --help  Show this help"
            echo ""
            echo "By default, only unit tests are run (no cluster required)."
            echo ""
            echo "For E2E tests, create tests/test-config.env from the template:"
            echo "  cp tests/test-config.env.example tests/test-config.env"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

echo ""
echo -e "${BLUE}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║              IPsec Diagnostics Test Suite                      ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════════╝${NC}"
echo ""

TOTAL_PASS=0
TOTAL_FAIL=0

# ============================================================
# Unit Tests
# ============================================================
echo -e "${BLUE}━━━ Unit Tests ━━━${NC}"
echo ""

if [[ -x "$SCRIPT_DIR/test-args.sh" ]]; then
    if "$SCRIPT_DIR/test-args.sh"; then
        echo ""
        echo -e "${GREEN}Unit tests PASSED${NC}"
    else
        echo ""
        echo -e "${RED}Unit tests FAILED${NC}"
        ((TOTAL_FAIL++))
    fi
else
    echo -e "${YELLOW}Skipping: test-args.sh not found or not executable${NC}"
fi

echo ""

# ============================================================
# Secret & PII Detection
# ============================================================
echo -e "${BLUE}━━━ Secret & PII Detection ━━━${NC}"
echo ""

if [[ -x "$SCRIPT_DIR/test-secrets.sh" ]]; then
    if "$SCRIPT_DIR/test-secrets.sh"; then
        echo ""
        echo -e "${GREEN}Secret detection PASSED${NC}"
    else
        echo ""
        echo -e "${RED}Secret detection FAILED${NC}"
        ((TOTAL_FAIL++))
    fi
else
    echo -e "${YELLOW}Skipping: test-secrets.sh not found or not executable${NC}"
fi

echo ""

# ============================================================
# E2E Tests
# ============================================================
if [[ "$RUN_E2E" == "true" ]]; then
    echo -e "${BLUE}━━━ E2E Tests ━━━${NC}"
    echo ""
    
    if [[ ! -f "$SCRIPT_DIR/test-config.env" ]]; then
        echo -e "${YELLOW}WARNING:${NC} tests/test-config.env not found"
        echo "Create it from the template:"
        echo "  cp tests/test-config.env.example tests/test-config.env"
        echo ""
        echo -e "${YELLOW}E2E tests SKIPPED${NC}"
    elif [[ -x "$SCRIPT_DIR/test-e2e.sh" ]]; then
        if "$SCRIPT_DIR/test-e2e.sh"; then
            echo ""
            echo -e "${GREEN}E2E tests PASSED${NC}"
        else
            echo ""
            echo -e "${RED}E2E tests FAILED${NC}"
            ((TOTAL_FAIL++))
        fi
    else
        echo -e "${YELLOW}Skipping: test-e2e.sh not found or not executable${NC}"
    fi
    echo ""
else
    echo -e "${YELLOW}E2E tests skipped (use --e2e to run)${NC}"
    echo ""
fi

# ============================================================
# Summary
# ============================================================
echo -e "${BLUE}╔════════════════════════════════════════════════════════════════╗${NC}"
if [[ $TOTAL_FAIL -eq 0 ]]; then
    echo -e "${BLUE}║${NC}                    ${GREEN}ALL TESTS PASSED${NC}                           ${BLUE}║${NC}"
else
    echo -e "${BLUE}║${NC}                    ${RED}SOME TESTS FAILED${NC}                          ${BLUE}║${NC}"
fi
echo -e "${BLUE}╚════════════════════════════════════════════════════════════════╝${NC}"
echo ""

if [[ $TOTAL_FAIL -gt 0 ]]; then
    exit 1
fi

