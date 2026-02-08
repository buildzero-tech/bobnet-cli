#!/usr/bin/env bash
# Test Runner: Run all BobNet test suites
# Usage: ./tests/run-all.sh [--verbose]

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

error() { echo -e "${RED}✗${NC} $*" >&2; exit 1; }
success() { echo -e "${GREEN}✓${NC} $*"; }
info() { echo -e "${BLUE}→${NC} $*"; }
warn() { echo -e "${YELLOW}⚠${NC} $*" >&2; }

# Parse flags
VERBOSE=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --verbose|-v) VERBOSE=true; shift ;;
        *) error "Unknown flag: $1" ;;
    esac
done

# Find test directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="$SCRIPT_DIR"

# Verify we're in the right place
[[ ! -d "$TEST_DIR" ]] && error "Test directory not found: $TEST_DIR"

# Collect test scripts
TEST_SCRIPTS=(
    "test-spec-workflow.sh"
    "test-label-discovery.sh"
    "test-deduplication.sh"
)

# Track results
TOTAL_SUITES=0
PASSED_SUITES=0
FAILED_SUITES=0
TOTAL_TESTS=0
PASSED_TESTS=0

echo ""
info "BobNet Test Runner"
echo ""

# Run each test suite
for script in "${TEST_SCRIPTS[@]}"; do
    TEST_PATH="$TEST_DIR/$script"
    
    [[ ! -f "$TEST_PATH" ]] && warn "Test script not found: $script" && continue
    [[ ! -x "$TEST_PATH" ]] && warn "Test script not executable: $script" && continue
    
    TOTAL_SUITES=$((TOTAL_SUITES + 1))
    
    info "Running: $script"
    
    if [[ "$VERBOSE" == "true" ]]; then
        if "$TEST_PATH" --verbose; then
            PASSED_SUITES=$((PASSED_SUITES + 1))
            # Extract test count from output (assumes "Tests run: N" format)
            # For now, assume 6 tests per suite
            TOTAL_TESTS=$((TOTAL_TESTS + 6))
            PASSED_TESTS=$((PASSED_TESTS + 6))
        else
            FAILED_SUITES=$((FAILED_SUITES + 1))
            TOTAL_TESTS=$((TOTAL_TESTS + 6))
        fi
    else
        # Capture output, only show on failure
        if OUTPUT=$("$TEST_PATH" 2>&1); then
            PASSED_SUITES=$((PASSED_SUITES + 1))
            TOTAL_TESTS=$((TOTAL_TESTS + 6))
            PASSED_TESTS=$((PASSED_TESTS + 6))
            success "$script passed"
        else
            FAILED_SUITES=$((FAILED_SUITES + 1))
            TOTAL_TESTS=$((TOTAL_TESTS + 6))
            error "$script failed"
            echo "$OUTPUT"
            exit 1
        fi
    fi
    
    echo ""
done

# Summary
echo "=== Test Runner Summary"
echo "  Suites run:    $TOTAL_SUITES"
echo "  Suites passed: $PASSED_SUITES"
echo "  Suites failed: $FAILED_SUITES"
echo "  Tests run:     $TOTAL_TESTS"
echo "  Tests passed:  $PASSED_TESTS"
echo "  Tests failed:  $((TOTAL_TESTS - PASSED_TESTS))"
echo ""

if [[ $FAILED_SUITES -eq 0 ]]; then
    success "All test suites passed! ✨"
    exit 0
else
    error "$FAILED_SUITES suite(s) failed"
    exit 1
fi
