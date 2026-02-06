#!/bin/bash
#######################################
# BobNet Rollback Test Script
# 
# Tests: Rollback after upgrade
# 
# Prerequisites: test-upgrade-vm.sh must run first
#
# Usage:
#   ./test-rollback-vm.sh [--verbose]
#
#######################################

set -euo pipefail

VERBOSE=false
[[ "${1:-}" == "--verbose" || "${1:-}" == "-v" ]] && VERBOSE=true

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { 
    echo -e "[$(date +'%H:%M:%S')] $*" 
}

success() { 
    echo -e "${GREEN}✓${NC} $*" 
}

error() { 
    echo -e "${RED}✗${NC} $*" >&2
    exit 1
}

warn() { 
    echo -e "${YELLOW}⚠${NC} $*" 
}

run_cmd() {
    local desc="$1"
    shift
    
    if [[ "$VERBOSE" == "true" ]]; then
        log "$desc"
        echo "  $ $*"
        "$@" || error "$desc failed"
    else
        log "$desc"
        "$@" >/dev/null 2>&1 || error "$desc failed"
    fi
}

#######################################
# Main Test Flow
#######################################

main() {
    log "=== BobNet Rollback Test ==="
    log "Testing: Rollback to pinned version"
    echo ""
    
    local repo_dir="${BOBNET_ROOT:-$HOME/.bobnet/ultima-thule}"
    
    # 1. Check prerequisites
    log "--- Prerequisites ---"
    [[ -d "$repo_dir" ]] || error "Repo not found: $repo_dir (run test-upgrade-vm.sh first)"
    [[ -f "$repo_dir/config/openclaw-versions.json" ]] || error "Version tracking not found (run upgrade first)"
    
    command -v openclaw &>/dev/null || error "OpenClaw not found"
    command -v bobnet &>/dev/null || error "BobNet CLI not found"
    success "All prerequisites met"
    echo ""
    
    # 2. Check current state
    log "--- Pre-Rollback State ---"
    local current_version=$(openclaw --version 2>/dev/null | head -1)
    local pinned_version=$(jq -r '.pinned' "$repo_dir/config/openclaw-versions.json")
    
    log "Current version: $current_version"
    log "Pinned version:  $pinned_version"
    
    if [[ "$current_version" == "$pinned_version" ]]; then
        error "Already on pinned version (no upgrade to rollback)"
    fi
    
    success "Ready to rollback"
    echo ""
    
    # 3. Run rollback
    log "--- Running Rollback ---"
    cd "$repo_dir"
    
    if bobnet upgrade --openclaw --rollback; then
        success "Rollback completed"
    else
        error "Rollback failed"
    fi
    echo ""
    
    # 4. Verify rollback
    log "--- Post-Rollback Validation ---"
    
    local new_version=$(openclaw --version 2>/dev/null | head -1)
    
    if [[ "$new_version" == "$pinned_version" ]]; then
        success "Version restored: $new_version"
    else
        error "Version mismatch: expected $pinned_version, got $new_version"
    fi
    
    run_cmd "Validating config" bobnet validate
    success "Config validation passed"
    echo ""
    
    # 5. Summary
    log "=== Test Summary ==="
    success "Pre-rollback:  $current_version"
    success "Post-rollback: $new_version"
    success "Pinned:        $pinned_version"
    success "Config:        valid"
    echo ""
    
    log "✅ Rollback test passed"
}

main "$@"
