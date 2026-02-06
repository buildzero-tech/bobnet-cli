#!/bin/bash
#######################################
# BobNet Full Test Suite
# 
# Runs all tests in sequence:
# 1. Upgrade test (2026.1.30 → latest)
# 2. Rollback test (latest → 2026.1.30)
# 3. Re-upgrade test (2026.1.30 → latest again)
#
# Usage:
#   ./test-suite-vm.sh [--verbose]
#
#######################################

set -euo pipefail

VERBOSE=false
[[ "${1:-}" == "--verbose" || "${1:-}" == "-v" ]] && VERBOSE=true

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { 
    echo -e "${BLUE}===${NC} $*" 
}

success() { 
    echo -e "${GREEN}✓${NC} $*" 
}

error() { 
    echo -e "${RED}✗${NC} $*" >&2
    exit 1
}

#######################################
# Main Test Suite
#######################################

main() {
    local start_time=$(date +%s)
    local test_count=0
    local pass_count=0
    
    echo ""
    log "BobNet Full Test Suite"
    echo ""
    
    # Test 1: Upgrade
    log "Test 1/3: Upgrade (2026.1.30 → latest)"
    echo ""
    
    if [[ "$VERBOSE" == "true" ]]; then
        ./test-upgrade-vm.sh --verbose --clean
    else
        ./test-upgrade-vm.sh --clean
    fi
    
    if [[ $? -eq 0 ]]; then
        ((pass_count++))
        success "Test 1 PASSED: Upgrade"
    else
        error "Test 1 FAILED: Upgrade"
    fi
    ((test_count++))
    echo ""
    
    # Test 2: Rollback
    log "Test 2/3: Rollback (latest → pinned)"
    echo ""
    
    if [[ "$VERBOSE" == "true" ]]; then
        ./test-rollback-vm.sh --verbose
    else
        ./test-rollback-vm.sh
    fi
    
    if [[ $? -eq 0 ]]; then
        ((pass_count++))
        success "Test 2 PASSED: Rollback"
    else
        error "Test 2 FAILED: Rollback"
    fi
    ((test_count++))
    echo ""
    
    # Test 3: Re-upgrade
    log "Test 3/3: Re-upgrade (pinned → latest)"
    echo ""
    
    if [[ "$VERBOSE" == "true" ]]; then
        ./test-upgrade-vm.sh --verbose
    else
        ./test-upgrade-vm.sh
    fi
    
    if [[ $? -eq 0 ]]; then
        ((pass_count++))
        success "Test 3 PASSED: Re-upgrade"
    else
        error "Test 3 FAILED: Re-upgrade"
    fi
    ((test_count++))
    echo ""
    
    # Summary
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    log "Test Suite Summary"
    echo ""
    echo "  Tests run:  $test_count"
    echo "  Passed:     $pass_count"
    echo "  Failed:     $((test_count - pass_count))"
    echo "  Duration:   ${duration}s"
    echo ""
    
    if [[ $pass_count -eq $test_count ]]; then
        success "All tests passed! ✨"
        return 0
    else
        error "$((test_count - pass_count)) test(s) failed"
        return 1
    fi
}

main "$@"
