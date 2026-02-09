#!/usr/bin/env bash
# Test: Trust lifecycle commands
# Tests archive, restore, delete, and cleanup operations

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
TEST_USER="testuser$$"
BOBNET_ROOT="${BOBNET_ROOT:-$HOME/.bobnet/ultima-thule}"
TEST_DB="$BOBNET_ROOT/config/trust-registry-$TEST_USER.db"

cleanup() {
    rm -f "$TEST_DB" 2>/dev/null || true
}

trap cleanup EXIT

# Initialize test registry
info "Setting up test environment"
bobnet trust init --user "$TEST_USER" --force >/dev/null 2>&1 || error "Failed to initialize test registry"

# Add test contacts
sqlite3 "$TEST_DB" <<EOF
INSERT INTO contacts (email, name, trust_level, trust_score, state, created_at, updated_at, last_interaction_at)
VALUES 
    ('active@example.com', 'Active Contact', 'known', 0.5, 'active', strftime('%s', 'now'), strftime('%s', 'now'), strftime('%s', 'now')),
    ('old@example.com', 'Old Contact', 'known', 0.3, 'active', strftime('%s', 'now', '-800 days'), strftime('%s', 'now', '-800 days'), strftime('%s', 'now', '-800 days')),
    ('blocked@example.com', 'Blocked', 'blocked', -0.6, 'active', strftime('%s', 'now'), strftime('%s', 'now'), NULL);

-- Add external source for old contact
INSERT INTO contact_sources (contact_id, source_type, source_id, last_seen_at)
SELECT id, 'google', 'old@example.com', strftime('%s', 'now', '-800 days')
FROM contacts WHERE email = 'old@example.com';
EOF

# =============================================================================
# Test 1: Archive Command
# =============================================================================

info "Test 1: Archive an active contact"
bobnet trust archive active@example.com --user "$TEST_USER" >/dev/null 2>&1 || error "Archive failed"

state=$(sqlite3 "$TEST_DB" "SELECT state FROM contacts WHERE email = 'active@example.com';")
[ "$state" = "archived" ] || error "Contact not archived (state: $state)"
success "Contact archived successfully"

# =============================================================================
# Test 2: Archive with Reason
# =============================================================================

info "Test 2: Archive with reason"
sqlite3 "$TEST_DB" "UPDATE contacts SET state = 'active' WHERE email = 'active@example.com';"
bobnet trust archive active@example.com --user "$TEST_USER" --reason "Test reason" >/dev/null 2>&1 || error "Archive with reason failed"

reason=$(sqlite3 "$TEST_DB" "SELECT archived_reason FROM contacts WHERE email = 'active@example.com';")
[ "$reason" = "Test reason" ] || error "Reason not stored"
success "Archive reason stored"

# =============================================================================
# Test 3: Restore Archived Contact
# =============================================================================

info "Test 3: Restore archived contact"
bobnet trust restore active@example.com --user "$TEST_USER" >/dev/null 2>&1 || error "Restore failed"

state=$(sqlite3 "$TEST_DB" "SELECT state FROM contacts WHERE email = 'active@example.com';")
[ "$state" = "active" ] || error "Contact not restored"
success "Contact restored"

# =============================================================================
# Test 4: Soft Delete
# =============================================================================

info "Test 4: Soft delete contact"
bobnet trust delete active@example.com --user "$TEST_USER" >/dev/null 2>&1 || error "Soft delete failed"

state=$(sqlite3 "$TEST_DB" "SELECT state FROM contacts WHERE email = 'active@example.com';")
[ "$state" = "deleted" ] || error "Contact not deleted"

count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM contacts WHERE email = 'active@example.com';")
[ "$count" -eq 1 ] || error "Contact removed (should be soft-deleted)"
success "Contact soft-deleted"

# =============================================================================
# Test 5: Restore Deleted Contact
# =============================================================================

info "Test 5: Restore soft-deleted contact"
bobnet trust restore active@example.com --user "$TEST_USER" >/dev/null 2>&1 || error "Restore deleted failed"

state=$(sqlite3 "$TEST_DB" "SELECT state FROM contacts WHERE email = 'active@example.com';")
[ "$state" = "active" ] || error "Deleted contact not restored"
success "Deleted contact restored"

# =============================================================================
# Test 6: Permanent Delete
# =============================================================================

info "Test 6: Permanent delete"
bobnet trust delete active@example.com --user "$TEST_USER" --permanent >/dev/null 2>&1 || error "Permanent delete failed"

count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM contacts WHERE email = 'active@example.com';")
[ "$count" -eq 0 ] || error "Contact not permanently deleted"
success "Contact permanently deleted"

# =============================================================================
# Test 7: Cleanup Dry Run
# =============================================================================

info "Test 7: Cleanup dry run"
output=$(bobnet trust cleanup --user "$TEST_USER" --dry-run 2>&1)
[[ "$output" =~ "old@example.com" ]] || error "Cleanup didn't identify old contact"

# Verify no changes
state=$(sqlite3 "$TEST_DB" "SELECT state FROM contacts WHERE email = 'old@example.com';")
[ "$state" = "active" ] || error "Dry run made changes"
success "Cleanup dry run works"

# =============================================================================
# Test 8: Cleanup Execution
# =============================================================================

info "Test 8: Cleanup with --yes"
bobnet trust cleanup --user "$TEST_USER" --yes >/dev/null 2>&1 || error "Cleanup failed"

# Verify old contact archived
state=$(sqlite3 "$TEST_DB" "SELECT state FROM contacts WHERE email = 'old@example.com';")
[ "$state" = "archived" ] || error "Old contact not archived (state: $state)"

# Verify blocked contact deleted
state=$(sqlite3 "$TEST_DB" "SELECT state FROM contacts WHERE email = 'blocked@example.com';")
[ "$state" = "deleted" ] || error "Blocked contact not deleted"
success "Cleanup executed successfully"

# =============================================================================
# Test 9: Restore Past Retention Period
# =============================================================================

info "Test 9: Restore fails past retention period"
# Create contact deleted 91 days ago
sqlite3 "$TEST_DB" <<EOF
INSERT INTO contacts (email, name, trust_level, trust_score, state, created_at, updated_at, deleted_at)
VALUES ('expired@example.com', 'Expired', 'known', 0.5, 'deleted', strftime('%s', 'now', '-100 days'), strftime('%s', 'now', '-91 days'), strftime('%s', 'now', '-91 days'));
EOF

if bobnet trust restore expired@example.com --user "$TEST_USER" 2>&1 | grep -q "90-day retention"; then
    success "Restore correctly fails past retention period"
else
    error "Should fail to restore expired contact"
fi

# =============================================================================
# Test 10: Archive Already Archived
# =============================================================================

info "Test 10: Archive fails on archived contact"
# Old contact is already archived from test 8
if bobnet trust archive old@example.com --user "$TEST_USER" 2>&1 | grep -q "already"; then
    success "Archive correctly fails on archived contact"
else
    error "Should fail to archive already archived contact"
fi

# =============================================================================
# All Tests Passed
# =============================================================================

echo ""
success "All 10 trust lifecycle tests passed!"
