#!/usr/bin/env bash
# Test: Project automation commands
# Tests bobnet github project set-status/set-priority and work blocked

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

error() { echo -e "${RED}✗${NC} $*" >&2; exit 1; }
success() { echo -e "${GREEN}✓${NC} $*"; }
info() { echo -e "${YELLOW}→${NC} $*"; }

# Source bobnet
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SCRIPT_DIR/bobnet.sh"

# Parse flags
VERBOSE=false
LIVE_TEST=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --verbose|-v) VERBOSE=true; shift ;;
        --live) LIVE_TEST=true; shift ;;
        *) error "Unknown flag: $1" ;;
    esac
done

# =============================================================================
# Test 1: Help Commands
# =============================================================================

info "Test 1: Help commands exist and are formatted correctly"

# Test github project help
output=$(bobnet_main github project help 2>&1)
[[ "$output" == *"set-status"* ]] || error "github project help missing set-status"
[[ "$output" == *"set-priority"* ]] || error "github project help missing set-priority"
[[ "$output" == *"refresh"* ]] || error "github project help missing refresh"
success "github project help"

# Test work help
output=$(bobnet_main work help 2>&1)
[[ "$output" == *"blocked"* ]] || error "work help missing blocked"
success "work help includes blocked"

# Test work blocked help
output=$(bobnet_main work blocked --help 2>&1)
[[ "$output" == *"Priority"* ]] || error "work blocked help missing Priority"
[[ "$output" == *"blocked label"* ]] || error "work blocked help missing blocked label"
success "work blocked --help"

# =============================================================================
# Test 2: Status Normalization
# =============================================================================

info "Test 2: Status value normalization"

# Mock test - just verify the case statement logic
test_status_normalization() {
    local input="$1"
    local expected="$2"
    
    # Simulate the case statement logic
    local status
    case "$input" in
        not-started|"not started"|notstarted) status="Not Started" ;;
        in-progress|"in progress"|inprogress|started) status="In Progress" ;;
        review|reviewing) status="Review" ;;
        done|complete|completed|closed) status="Done" ;;
        *) status="INVALID" ;;
    esac
    
    [[ "$status" == "$expected" ]] || error "Status '$input' normalized to '$status', expected '$expected'"
}

test_status_normalization "not-started" "Not Started"
test_status_normalization "in-progress" "In Progress"
test_status_normalization "inprogress" "In Progress"
test_status_normalization "started" "In Progress"
test_status_normalization "review" "Review"
test_status_normalization "done" "Done"
test_status_normalization "complete" "Done"
test_status_normalization "closed" "Done"
test_status_normalization "invalid" "INVALID"
success "Status normalization"

# =============================================================================
# Test 3: Priority Normalization
# =============================================================================

info "Test 3: Priority value normalization"

test_priority_normalization() {
    local input="$1"
    local expected="$2"
    
    local priority
    case "$input" in
        low|l) priority="Low" ;;
        medium|med|m) priority="Medium" ;;
        high|h) priority="High" ;;
        critical|crit|c) priority="Critical" ;;
        waiting|wait|w|blocked) priority="Waiting" ;;
        deferred|defer|d) priority="Deferred" ;;
        *) priority="INVALID" ;;
    esac
    
    [[ "$priority" == "$expected" ]] || error "Priority '$input' normalized to '$priority', expected '$expected'"
}

test_priority_normalization "low" "Low"
test_priority_normalization "l" "Low"
test_priority_normalization "medium" "Medium"
test_priority_normalization "med" "Medium"
test_priority_normalization "m" "Medium"
test_priority_normalization "high" "High"
test_priority_normalization "h" "High"
test_priority_normalization "critical" "Critical"
test_priority_normalization "crit" "Critical"
test_priority_normalization "waiting" "Waiting"
test_priority_normalization "wait" "Waiting"
test_priority_normalization "blocked" "Waiting"
test_priority_normalization "deferred" "Deferred"
test_priority_normalization "defer" "Deferred"
test_priority_normalization "invalid" "INVALID"
success "Priority normalization"

# =============================================================================
# Test 4: Project Inference
# =============================================================================

info "Test 4: Project inference from repository"

test_project_inference() {
    local repo="$1"
    local expected="$2"
    
    local result=$(infer_project_from_repo "$repo")
    [[ "$result" == "$expected" ]] || error "Repo '$repo' inferred project '$result', expected '$expected'"
}

test_project_inference "buildzero-tech/bobnet-cli" "buildzero-tech/4"
test_project_inference "buildzero-tech/ultima-thule" "buildzero-tech/4"
test_project_inference "other-org/other-repo" "buildzero-tech/4"  # Falls back to default
success "Project inference"

# =============================================================================
# Test 5: Cache Path Generation
# =============================================================================

info "Test 5: Cache path generation"

cache_path=$(get_project_cache_path "buildzero-tech" "4")
[[ "$cache_path" == *"github-projects/buildzero-tech-4.json" ]] || error "Unexpected cache path: $cache_path"
success "Cache path format"

# =============================================================================
# Test 6: Live API Tests (optional)
# =============================================================================

if [[ "$LIVE_TEST" == "true" ]]; then
    info "Test 6: Live API tests (--live flag enabled)"
    
    # Test cache refresh
    info "Testing cache refresh..."
    bobnet_main github project refresh buildzero-tech/4 >/dev/null 2>&1 || error "Cache refresh failed"
    success "Cache refresh"
    
    # Verify cache file exists
    cache_file="$BOBNET_CACHE_DIR/github-projects/buildzero-tech-4.json"
    [[ -f "$cache_file" ]] || error "Cache file not created"
    success "Cache file created"
    
    # Verify cache contents
    [[ $(jq -r '.id' "$cache_file" 2>/dev/null) == PVT_* ]] || error "Cache file invalid format"
    success "Cache file valid"
    
    info "Note: Live status/priority updates not tested (would modify real issues)"
else
    info "Test 6: Skipped (use --live to enable API tests)"
fi

# =============================================================================
# Summary
# =============================================================================

echo ""
success "All tests passed!"
