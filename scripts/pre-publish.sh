#!/bin/bash
# Pre-publish check script
# Run this before pushing to public GitHub
#
# Usage:
#   ./scripts/pre-publish.sh           # Run unit tests only
#   ./scripts/pre-publish.sh --e2e     # Run unit + e2e tests
#   ./scripts/pre-publish.sh --full    # Full check (tests + security scan)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR/.."

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

RUN_E2E=false
FULL_CHECK=false

# Parse args
while [[ $# -gt 0 ]]; do
    case $1 in
        --e2e) RUN_E2E=true; shift ;;
        --full) FULL_CHECK=true; RUN_E2E=true; shift ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --e2e   Run E2E tests (requires cluster + test-config.env)"
            echo "  --full  Full check: tests + security scan"
            echo ""
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

echo ""
echo -e "${BLUE}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║              Pre-Publish Check                                 ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════════╝${NC}"
echo ""

ERRORS=0

# ============================================================
# 1. Secret & PII Detection (comprehensive)
# ============================================================
echo -e "${BLUE}━━━ Secret & PII Detection ━━━${NC}"

if [[ -x "$PROJECT_ROOT/tests/test-secrets.sh" ]]; then
    if "$PROJECT_ROOT/tests/test-secrets.sh"; then
        echo -e "${GREEN}✓${NC} Secret detection passed"
    else
        echo -e "${RED}✗${NC} Secret detection failed"
        ERRORS=$((ERRORS + 1))
    fi
else
    # Fallback: basic checks if test-secrets.sh not available
    echo -e "${YELLOW}⚠${NC} tests/test-secrets.sh not found, running basic checks"
    
    # Check for hardcoded IPs (non-example)
    if grep -rn --include="*.sh" -E '192\.168\.[0-9]+\.[0-9]+' "$PROJECT_ROOT" 2>/dev/null | grep -v "example" | grep -v ".git" | grep -v "test-config.env"; then
        echo -e "${YELLOW}⚠ Found potential hardcoded IPs (review above)${NC}"
    fi

    # Check for real hostnames
    if grep -rn --include="*.sh" --include="*.md" -E '\.(internal|local|corp|company)' "$PROJECT_ROOT" 2>/dev/null | grep -v ".git" | grep -v "test-config.env" | grep -v "example"; then
        echo -e "${YELLOW}⚠ Found potential internal hostnames (review above)${NC}"
    fi

    # Check test-config.env is gitignored
    if [[ -f "$PROJECT_ROOT/tests/test-config.env" ]]; then
        if git -C "$PROJECT_ROOT" check-ignore -q tests/test-config.env 2>/dev/null; then
            echo -e "${GREEN}✓${NC} test-config.env is gitignored"
        else
            echo -e "${RED}✗${NC} test-config.env is NOT gitignored - DO NOT PUSH"
            ERRORS=$((ERRORS + 1))
        fi
    fi

    # Check no secrets in staged files
    if git -C "$PROJECT_ROOT" diff --cached --name-only 2>/dev/null | xargs -I {} grep -l -E "(password|token|secret|apikey)" "$PROJECT_ROOT/{}" 2>/dev/null; then
        echo -e "${YELLOW}⚠ Staged files may contain sensitive keywords${NC}"
    fi
fi

echo ""

# ============================================================
# 2. Run unit tests
# ============================================================
echo -e "${BLUE}━━━ Running Unit Tests ━━━${NC}"

if "$PROJECT_ROOT/tests/test-args.sh"; then
    echo -e "${GREEN}✓${NC} Unit tests passed"
else
    echo -e "${RED}✗${NC} Unit tests failed"
    ERRORS=$((ERRORS + 1))
fi
echo ""

# ============================================================
# 3. Run E2E tests (optional)
# ============================================================
if [[ "$RUN_E2E" == "true" ]]; then
    echo -e "${BLUE}━━━ Running E2E Tests ━━━${NC}"
    
    if [[ ! -f "$PROJECT_ROOT/tests/test-config.env" ]]; then
        echo -e "${YELLOW}⚠${NC} Skipping E2E: tests/test-config.env not found"
    elif ! oc whoami &>/dev/null; then
        echo -e "${YELLOW}⚠${NC} Skipping E2E: not connected to cluster"
    else
        if "$PROJECT_ROOT/tests/test-e2e.sh"; then
            echo -e "${GREEN}✓${NC} E2E tests passed"
        else
            echo -e "${RED}✗${NC} E2E tests failed"
            ERRORS=$((ERRORS + 1))
        fi
    fi
    echo ""
fi

# ============================================================
# 4. Security scan (optional, --full only)
# ============================================================
if [[ "$FULL_CHECK" == "true" ]]; then
    echo -e "${BLUE}━━━ Security Scan ━━━${NC}"
    
    # Check shellcheck is available
    if command -v shellcheck &>/dev/null; then
        echo "Running shellcheck on scripts..."
        SHELLCHECK_ERRORS=0
        for script in "$PROJECT_ROOT"/*.sh "$PROJECT_ROOT"/scripts/*.sh; do
            if [[ -f "$script" ]]; then
                if shellcheck -S warning "$script" 2>/dev/null; then
                    echo -e "${GREEN}✓${NC} $(basename "$script")"
                else
                    echo -e "${YELLOW}⚠${NC} $(basename "$script") has warnings"
                fi
            fi
        done
    else
        echo -e "${YELLOW}⚠${NC} shellcheck not installed, skipping"
    fi
    echo ""
fi

# ============================================================
# Summary
# ============================================================
echo -e "${BLUE}╔════════════════════════════════════════════════════════════════╗${NC}"
if [[ $ERRORS -eq 0 ]]; then
    echo -e "${BLUE}║${NC}              ${GREEN}✓ READY TO PUBLISH${NC}                              ${BLUE}║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "Next steps:"
    echo "  git add -A"
    echo "  git commit -m 'your message'"
    echo "  git push origin main"
else
    echo -e "${BLUE}║${NC}              ${RED}✗ DO NOT PUBLISH ($ERRORS issues)${NC}                    ${BLUE}║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════════╝${NC}"
    exit 1
fi

