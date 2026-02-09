#!/usr/bin/env bash
# Test: Audit logging system
# Tests JSONL logging, query, and rotation

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

error() { echo -e "${RED}✗${NC} $*" >&2; exit 1; }
success() { echo -e "${GREEN}✓${NC} $*"; }
info() { echo -e "${YELLOW}→${NC} $*"; }

# Setup
BOBNET_ROOT="${BOBNET_ROOT:-$HOME/.bobnet/ultima-thule}"
LOG_DIR="$BOBNET_ROOT/logs/audit"
TEST_LOG="$LOG_DIR/test-$(date +%Y-%m-%d).jsonl"

cleanup() {
    rm -f "$TEST_LOG" 2>/dev/null || true
    rm -rf /var/tmp/bobnet-audit.lock 2>/dev/null || true
}

trap cleanup EXIT

# =============================================================================
# Test 1: Basic Log Entry
# =============================================================================

info "Test 1: Create basic log entry"
bobnet audit log test_action --subject "test@example.com" --result success >/dev/null 2>&1 || error "Failed to log event"

# Verify log file exists
[ -f "$LOG_DIR/$(date +%Y-%m-%d).jsonl" ] || error "Log file not created"

# Verify log entry
entry=$(tail -1 "$LOG_DIR/$(date +%Y-%m-%d).jsonl")
[[ "$entry" =~ "test_action" ]] || error "Log entry missing action"
[[ "$entry" =~ "test@example.com" ]] || error "Log entry missing subject"
success "Basic log entry created"

# =============================================================================
# Test 2: Log with Metadata
# =============================================================================

info "Test 2: Log with metadata"
bobnet audit log test_metadata --subject "meta@example.com" --metadata '{"key":"value"}' >/dev/null 2>&1 || error "Failed to log with metadata"

entry=$(tail -1 "$LOG_DIR/$(date +%Y-%m-%d).jsonl")
[[ "$entry" =~ "\"key\":\"value\"" ]] || error "Metadata not preserved"
success "Metadata logged correctly"

# =============================================================================
# Test 3: Log with Custom User/Agent/Channel
# =============================================================================

info "Test 3: Log with custom attribution"
bobnet audit log test_attribution \
    --user testuser \
    --agent testagent \
    --channel testchannel \
    --subject "attr@example.com" >/dev/null 2>&1 || error "Failed to log with attribution"

entry=$(tail -1 "$LOG_DIR/$(date +%Y-%m-%d).jsonl")
[[ "$entry" =~ "testuser" ]] || error "User attribution missing"
[[ "$entry" =~ "testagent" ]] || error "Agent attribution missing"
[[ "$entry" =~ "testchannel" ]] || error "Channel attribution missing"
success "Attribution logged correctly"

# =============================================================================
# Test 4: Query by Action
# =============================================================================

info "Test 4: Query by action"
output=$(bobnet audit query --action test_action 2>/dev/null)
[[ "$output" =~ "test_action" ]] || error "Query by action failed"
[[ "$output" =~ "test@example.com" ]] || error "Query didn't return correct entry"
success "Query by action works"

# =============================================================================
# Test 5: Query by Subject
# =============================================================================

info "Test 5: Query by subject"
output=$(bobnet audit query --subject "meta@example.com" 2>/dev/null)
[[ "$output" =~ "meta@example.com" ]] || error "Query by subject failed"
success "Query by subject works"

# =============================================================================
# Test 6: Query with Limit
# =============================================================================

info "Test 6: Query with limit"
# Create multiple entries
for i in {1..5}; do
    bobnet audit log test_limit_$i --subject "limit$i@example.com" >/dev/null 2>&1
done

output=$(bobnet audit query --limit 3 2>/dev/null)
lines=$(echo "$output" | wc -l | tr -d ' ')
[ "$lines" -le 3 ] || error "Limit not respected (got $lines lines)"
success "Query limit works"

# =============================================================================
# Test 7: JSON Output Format
# =============================================================================

info "Test 7: JSON output format"
output=$(bobnet audit query --action test_action --format json 2>/dev/null)
echo "$output" | jq . >/dev/null 2>&1 || error "JSON output is not valid"
success "JSON output format works"

# =============================================================================
# Test 8: Concurrent Writes (stress test)
# =============================================================================

info "Test 8: Concurrent writes"
pids=()
for i in {1..10}; do
    bobnet audit log concurrent_test_$i --subject "concurrent$i@example.com" &
    pids+=($!)
done

# Wait for all to complete
for pid in "${pids[@]}"; do
    wait "$pid" || error "Concurrent write failed"
done

# Verify all entries exist
count=$(grep -c "concurrent_test" "$LOG_DIR/$(date +%Y-%m-%d).jsonl" || echo 0)
[ "$count" -eq 10 ] || error "Not all concurrent writes succeeded (got $count/10)"
success "Concurrent writes work"

# =============================================================================
# Test 9: Portable Lock Cleanup
# =============================================================================

info "Test 9: Lock directory cleanup"
# Verify no stale locks
[ ! -d "/var/tmp/bobnet-audit.lock" ] || error "Stale lock directory exists"
success "No stale locks"

# =============================================================================
# Test 10: Query Recent Events
# =============================================================================

info "Test 10: Query recent events"
# Create a recent event
bobnet audit log recent_test --subject "recent@example.com" >/dev/null 2>&1

# Query without filters (should include recent)
output=$(bobnet audit query --limit 100 2>/dev/null)
[[ "$output" =~ "recent_test" ]] || error "Recent event not in query results"
success "Recent events queryable"

# =============================================================================
# All Tests Passed
# =============================================================================

echo ""
success "All 10 audit logging tests passed!"
