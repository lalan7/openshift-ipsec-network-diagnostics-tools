#!/bin/bash
# tests/test-secrets.sh - Secret/PII detection test
# Scans repository for hardcoded secrets, personal information, and sensitive data
#
# Usage:
#   ./tests/test-secrets.sh           # Run all checks
#   ./tests/test-secrets.sh --verbose # Show detailed output

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR/.."

# Use command to bypass any shell aliases (e.g., grep aliased to rg)
GREP="/usr/bin/grep"

# Colors
readonly GREEN='\033[0;32m'
readonly RED='\033[0;31m'
readonly YELLOW='\033[0;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

VERBOSE=false
PASS=0
FAIL=0
WARN=0

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --verbose|-v) VERBOSE=true; shift ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --verbose, -v  Show detailed output"
            echo "  --help, -h     Show this help"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

test_case() {
    local name="$1"
    local result="$2"
    local details="${3:-}"
    
    if [[ "$result" == "pass" ]]; then
        echo -e "${GREEN}✓${NC} $name"
        PASS=$((PASS + 1))
    elif [[ "$result" == "warn" ]]; then
        echo -e "${YELLOW}⚠${NC} $name"
        WARN=$((WARN + 1))
        if [[ -n "$details" && "$VERBOSE" == "true" ]]; then
            echo "$details" | sed 's/^/    /'
        fi
    else
        echo -e "${RED}✗${NC} $name"
        FAIL=$((FAIL + 1))
        if [[ -n "$details" ]]; then
            echo "$details" | sed 's/^/    /'
        fi
    fi
}

echo ""
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  Secret & PII Detection Tests${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo ""

# ============================================================
# 1. gitleaks scan (if available)
# ============================================================
echo -e "${BLUE}--- External Scanner (gitleaks) ---${NC}"

if command -v gitleaks &>/dev/null; then
    GITLEAKS_OUTPUT=$(gitleaks detect --source "$PROJECT_ROOT" --no-git 2>&1 || true)
    if echo "$GITLEAKS_OUTPUT" | $GREP -q "no leaks found"; then
        test_case "gitleaks: No secrets detected" "pass"
    elif echo "$GITLEAKS_OUTPUT" | $GREP -qE "leaks found|leak detected"; then
        test_case "gitleaks: No secrets detected" "fail" "$GITLEAKS_OUTPUT"
    else
        test_case "gitleaks: No secrets detected" "pass"
    fi
else
    echo -e "${YELLOW}⚠${NC} gitleaks not installed (brew install gitleaks)"
    echo "  Falling back to pattern-based checks only"
fi
echo ""

# ============================================================
# 2. Pattern-based checks (always run)
# ============================================================
echo -e "${BLUE}--- Pattern-based Checks ---${NC}"

# Exclude patterns for grep (includes this script to avoid false positives)
EXCLUDE_PATTERNS='\.git|test-config\.env|test-config\.env\.example|test-secrets\.sh'

# 2.1 Check for real IP addresses (not RFC 5737 documentation IPs or private ranges)
REAL_IPS=$($GREP -rn --include="*.sh" --include="*.md" --include="*.env" --include="*.txt" \
    -E '([0-9]{1,3}\.){3}[0-9]{1,3}' "$PROJECT_ROOT" 2>/dev/null \
    | $GREP -vE "$EXCLUDE_PATTERNS" \
    | $GREP -vE '192\.0\.2\.|198\.51\.100\.|203\.0\.113\.' \
    | $GREP -vE '0\.0\.0\.0|127\.0\.0\.|255\.255\.' \
    | $GREP -vE '10\.[0-9]+\.[0-9]+\.[0-9]+' \
    | $GREP -vE '172\.(1[6-9]|2[0-9]|3[01])\.' \
    | $GREP -vE '192\.168\.' \
    | $GREP -vE 'example|placeholder|<.*>' || true)

if [[ -z "$REAL_IPS" ]]; then
    test_case "No hardcoded public IP addresses" "pass"
else
    test_case "No hardcoded public IP addresses" "fail" "$REAL_IPS"
fi

# 2.2 Check for email addresses (excluding examples)
EMAILS=$($GREP -rnoE '[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}' "$PROJECT_ROOT" 2>/dev/null \
    | $GREP -vE "$EXCLUDE_PATTERNS" \
    | $GREP -vE 'example\.(com|org|net)|placeholder|your-email' || true)

if [[ -z "$EMAILS" ]]; then
    test_case "No real email addresses" "pass"
else
    test_case "No real email addresses" "fail" "$EMAILS"
fi

# 2.3 Check for usernames in paths
USER_PATHS=$($GREP -rnoE '/Users/[a-zA-Z0-9_-]+|/home/[a-zA-Z0-9_-]+' "$PROJECT_ROOT" 2>/dev/null \
    | $GREP -vE "$EXCLUDE_PATTERNS" \
    | $GREP -vE 'example|placeholder|<|your-' || true)

if [[ -z "$USER_PATHS" ]]; then
    test_case "No personal paths (/Users/*, /home/*)" "pass"
else
    test_case "No personal paths (/Users/*, /home/*)" "fail" "$USER_PATHS"
fi

# 2.4 Check for internal/corporate hostnames
INTERNAL_HOSTS=$($GREP -rnoE '\b[a-zA-Z0-9-]+\.(internal|local|corp|company|intranet|private)\b' "$PROJECT_ROOT" 2>/dev/null \
    | $GREP -vE "$EXCLUDE_PATTERNS" \
    | $GREP -vE 'example|placeholder' || true)

if [[ -z "$INTERNAL_HOSTS" ]]; then
    test_case "No internal hostnames (.internal, .corp, etc)" "pass"
else
    test_case "No internal hostnames (.internal, .corp, etc)" "fail" "$INTERNAL_HOSTS"
fi

# 2.5 Check for AWS credentials patterns
AWS_CREDS=$($GREP -rnoE 'AKIA[0-9A-Z]{16}|aws_secret_access_key\s*=|AWS_SECRET_ACCESS_KEY=' "$PROJECT_ROOT" 2>/dev/null \
    | $GREP -vE "$EXCLUDE_PATTERNS" || true)

if [[ -z "$AWS_CREDS" ]]; then
    test_case "No AWS credential patterns" "pass"
else
    test_case "No AWS credential patterns" "fail" "$AWS_CREDS"
fi

# 2.6 Check for other cloud provider patterns
CLOUD_CREDS=$($GREP -rnoE 'AZURE_[A-Z_]+\s*=\s*["\047][^"\047]+|GOOGLE_APPLICATION_CREDENTIALS|gcp_credentials' "$PROJECT_ROOT" 2>/dev/null \
    | $GREP -vE "$EXCLUDE_PATTERNS" || true)

if [[ -z "$CLOUD_CREDS" ]]; then
    test_case "No Azure/GCP credential patterns" "pass"
else
    test_case "No Azure/GCP credential patterns" "fail" "$CLOUD_CREDS"
fi

# 2.7 Check for private keys
PRIVATE_KEYS=$($GREP -rln 'BEGIN.*PRIVATE KEY' "$PROJECT_ROOT" 2>/dev/null \
    | $GREP -vE "$EXCLUDE_PATTERNS" || true)

if [[ -z "$PRIVATE_KEYS" ]]; then
    test_case "No private key files" "pass"
else
    test_case "No private key files" "fail" "$PRIVATE_KEYS"
fi

# 2.8 Check for common secret keywords with actual values
SECRET_PATTERNS=$($GREP -rnoE '(password|secret|token|apikey|api_key|auth_token)\s*[:=]\s*["\047][^"\047]{8,}["\047]' "$PROJECT_ROOT" 2>/dev/null \
    | $GREP -vE "$EXCLUDE_PATTERNS" \
    | $GREP -vE 'example|placeholder|your-|<|TODO|CHANGEME|xxxxxx' || true)

if [[ -z "$SECRET_PATTERNS" ]]; then
    test_case "No hardcoded secrets (password/token/etc)" "pass"
else
    test_case "No hardcoded secrets (password/token/etc)" "fail" "$SECRET_PATTERNS"
fi

# 2.9 Check for GitHub/GitLab tokens
GIT_TOKENS=$($GREP -rnoE 'gh[pousr]_[A-Za-z0-9_]{36}|glpat-[A-Za-z0-9_-]{20}' "$PROJECT_ROOT" 2>/dev/null \
    | $GREP -vE "$EXCLUDE_PATTERNS" || true)

if [[ -z "$GIT_TOKENS" ]]; then
    test_case "No GitHub/GitLab tokens" "pass"
else
    test_case "No GitHub/GitLab tokens" "fail" "$GIT_TOKENS"
fi

# 2.10 Check for OpenShift/Kubernetes tokens
K8S_TOKENS=$($GREP -rnoE 'sha256~[A-Za-z0-9_-]{43}|eyJhbGciOiJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+' "$PROJECT_ROOT" 2>/dev/null \
    | $GREP -vE "$EXCLUDE_PATTERNS" || true)

if [[ -z "$K8S_TOKENS" ]]; then
    test_case "No OpenShift/Kubernetes tokens" "pass"
else
    test_case "No OpenShift/Kubernetes tokens" "fail" "$K8S_TOKENS"
fi
echo ""

# ============================================================
# 3. File-based checks
# ============================================================
echo -e "${BLUE}--- File-based Checks ---${NC}"

# 3.1 Check test-config.env is gitignored
if [[ -f "$PROJECT_ROOT/tests/test-config.env" ]]; then
    if git -C "$PROJECT_ROOT" check-ignore -q tests/test-config.env 2>/dev/null; then
        test_case "test-config.env is gitignored" "pass"
    else
        test_case "test-config.env is gitignored" "fail" "Add 'tests/test-config.env' to .gitignore"
    fi
else
    test_case "test-config.env is gitignored (file not present)" "pass"
fi

# 3.2 Check no .env files with secrets are tracked
TRACKED_ENV=$(git -C "$PROJECT_ROOT" ls-files "*.env" 2>/dev/null | $GREP -vE "example|template|capture-config.env" || true)
if [[ -z "$TRACKED_ENV" ]]; then
    test_case "No sensitive .env files tracked in git" "pass"
else
    test_case "No sensitive .env files tracked in git" "warn" "Review: $TRACKED_ENV"
fi

# 3.3 Check no pcap/data files are tracked
TRACKED_DATA=$(git -C "$PROJECT_ROOT" ls-files "*.pcap" "*.data" 2>/dev/null || true)
if [[ -z "$TRACKED_DATA" ]]; then
    test_case "No capture files (.pcap, .data) tracked in git" "pass"
else
    test_case "No capture files (.pcap, .data) tracked in git" "fail" "$TRACKED_DATA"
fi
echo ""

# ============================================================
# 4. Git history check (optional, slower)
# ============================================================
if [[ "$VERBOSE" == "true" ]]; then
    echo -e "${BLUE}--- Git History Check ---${NC}"
    
    # Check for secrets in recent commits (last 10)
    HISTORY_SECRETS=$(git -C "$PROJECT_ROOT" log -10 --oneline --diff-filter=A --name-only 2>/dev/null \
        | xargs -I {} sh -c "git -C '$PROJECT_ROOT' show {}:$* 2>/dev/null || true" \
        | $GREP -E 'password|secret|token|apikey' || true)
    
    if [[ -z "$HISTORY_SECRETS" ]]; then
        test_case "No secrets in recent git history" "pass"
    else
        test_case "No secrets in recent git history" "warn" "Consider: git filter-branch or BFG"
    fi
    echo ""
fi

# ============================================================
# Summary
# ============================================================
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
TOTAL=$((PASS + FAIL + WARN))
echo -e "Results: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC}, ${YELLOW}$WARN warnings${NC} (total: $TOTAL)"
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo ""

if [[ $FAIL -gt 0 ]]; then
    echo -e "${RED}ACTION REQUIRED:${NC} Fix the issues above before publishing."
    echo ""
    echo "Tips:"
    echo "  - Use placeholder values: 'example.com', '192.0.2.x', '<your-token>'"
    echo "  - Add sensitive files to .gitignore"
    echo "  - For git history cleanup: https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/removing-sensitive-data-from-a-repository"
    exit 1
fi

if [[ $WARN -gt 0 ]]; then
    echo -e "${YELLOW}Review warnings above before publishing.${NC}"
fi

exit 0
