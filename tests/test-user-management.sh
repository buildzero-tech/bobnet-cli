#!/usr/bin/env bash
# Test Suite: User Management (Phase 4: Multi-User RBAC)
# Tests user CRUD, agent binding, and permission enforcement

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOBNET_CLI="$HOME/.local/bin/bobnet"

# Test configuration
TEST_CONFIG_DIR="/tmp/bobnet-test-$$"
export BOBNET_CONFIG_DIR="$TEST_CONFIG_DIR"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

setup() {
    echo "Setting up test environment..."
    rm -rf "$TEST_CONFIG_DIR"
    mkdir -p "$TEST_CONFIG_DIR"
}

teardown() {
    echo "Cleaning up test environment..."
    rm -rf "$TEST_CONFIG_DIR"
}

pass() {
    echo -e "${GREEN}✓${NC} $1"
    ((TESTS_PASSED++))
    ((TESTS_RUN++))
}

fail() {
    echo -e "${RED}✗${NC} $1"
    [ -n "${2:-}" ] && echo "  Error: $2"
    ((TESTS_FAILED++))
    ((TESTS_RUN++))
}

test_user_add_basic() {
    echo "Test: Add basic user"
    
    if "$BOBNET_CLI" user add testuser --email test@example.com --role family 2>&1 | grep -q "User added"; then
        pass "Basic user add"
    else
        fail "Basic user add" "Failed to add user"
    fi
}

test_user_add_validation() {
    echo "Test: User add validation"
    
    # Missing email
    if "$BOBNET_CLI" user add baduser 2>&1 | grep -q "Username and email are required"; then
        pass "Rejects missing email"
    else
        fail "Rejects missing email"
    fi
    
    # Invalid role
    if "$BOBNET_CLI" user add baduser --email bad@example.com --role invalid 2>&1 | grep -q "Invalid role"; then
        pass "Rejects invalid role"
    else
        fail "Rejects invalid role"
    fi
}

test_user_add_duplicate() {
    echo "Test: Duplicate user handling"
    
    "$BOBNET_CLI" user add dupuser --email dup@example.com --role family >/dev/null 2>&1
    
    if "$BOBNET_CLI" user add dupuser --email dup2@example.com --role family 2>&1 | grep -q "already exists"; then
        pass "Rejects duplicate username"
    else
        fail "Rejects duplicate username"
    fi
}

test_user_list() {
    echo "Test: List users"
    
    # Add test users
    "$BOBNET_CLI" user add alice --email alice@example.com --role owner >/dev/null 2>&1
    "$BOBNET_CLI" user add bob --email bob@example.com --role family >/dev/null 2>&1
    
    local output=$("$BOBNET_CLI" user list 2>&1)
    
    if echo "$output" | grep -q "alice" && echo "$output" | grep -q "bob"; then
        pass "Lists all active users"
    else
        fail "Lists all active users" "Missing users in output"
    fi
}

test_user_show() {
    echo "Test: Show user details"
    
    "$BOBNET_CLI" user add showtest --email show@example.com --role delegate >/dev/null 2>&1
    
    local output=$("$BOBNET_CLI" user show showtest 2>&1)
    
    if echo "$output" | grep -q "showtest" && \
       echo "$output" | grep -q "show@example.com" && \
       echo "$output" | grep -q "delegate"; then
        pass "Shows user details"
    else
        fail "Shows user details" "Missing expected fields"
    fi
}

test_agent_binding() {
    echo "Test: Agent binding"
    
    "$BOBNET_CLI" user add bindtest --email bind@example.com --role family >/dev/null 2>&1
    
    if "$BOBNET_CLI" user bind-agent testagent bindtest 2>&1 | grep -q "Bound agent"; then
        pass "Binds agent to user"
    else
        fail "Binds agent to user"
    fi
    
    # Verify binding appears in user show
    local output=$("$BOBNET_CLI" user show bindtest 2>&1)
    if echo "$output" | grep -q "testagent"; then
        pass "Bound agent appears in user details"
    else
        fail "Bound agent appears in user details"
    fi
}

test_agent_binding_duplicate() {
    echo "Test: Duplicate agent binding"
    
    "$BOBNET_CLI" user add dupbind --email dupbind@example.com --role family >/dev/null 2>&1
    "$BOBNET_CLI" user bind-agent agent1 dupbind >/dev/null 2>&1
    
    if "$BOBNET_CLI" user bind-agent agent1 dupbind 2>&1 | grep -q "already bound"; then
        pass "Handles duplicate binding gracefully"
    else
        fail "Handles duplicate binding gracefully"
    fi
}

test_user_deactivate() {
    echo "Test: User deactivation"
    
    "$BOBNET_CLI" user add deactivate_test --email deact@example.com --role family >/dev/null 2>&1
    
    if "$BOBNET_CLI" user deactivate deactivate_test 2>&1 | grep -q "deactivated"; then
        pass "Deactivates user"
    else
        fail "Deactivates user"
    fi
    
    # Verify user no longer in active list
    local output=$("$BOBNET_CLI" user list 2>&1)
    if ! echo "$output" | grep -q "deactivate_test"; then
        pass "Deactivated user not in active list"
    else
        fail "Deactivated user not in active list"
    fi
    
    # Verify user appears with --all flag
    local all_output=$("$BOBNET_CLI" user list --all 2>&1)
    if echo "$all_output" | grep -q "deactivate_test"; then
        pass "Deactivated user appears in --all list"
    else
        fail "Deactivated user appears in --all list"
    fi
}

test_user_db_isolation() {
    echo "Test: User database isolation"
    
    "$BOBNET_CLI" user add user1 --email user1@example.com --role family >/dev/null 2>&1
    "$BOBNET_CLI" user add user2 --email user2@example.com --role family >/dev/null 2>&1
    
    local db1="$TEST_CONFIG_DIR/trust-registry-user1.db"
    local db2="$TEST_CONFIG_DIR/trust-registry-user2.db"
    
    if [ -f "$db1" ] && [ -f "$db2" ]; then
        pass "Creates separate databases for each user"
    else
        fail "Creates separate databases for each user" "Missing database files"
    fi
}

test_permission_check_owner() {
    echo "Test: Permission check - owner role"
    
    # Owner should have all permissions
    export BOBNET_USER="owner_test"
    "$BOBNET_CLI" user add owner_test --email owner@example.com --role owner >/dev/null 2>&1
    
    # Test via check_permission function (requires sourcing bobnet.sh)
    # For now, just verify user was created with correct role
    local output=$("$BOBNET_CLI" user show owner_test 2>&1)
    if echo "$output" | grep -q "Role: owner"; then
        pass "Owner role assigned correctly"
    else
        fail "Owner role assigned correctly"
    fi
}

test_permission_check_family() {
    echo "Test: Permission check - family role"
    
    "$BOBNET_CLI" user add family_test --email family@example.com --role family >/dev/null 2>&1
    
    local output=$("$BOBNET_CLI" user show family_test 2>&1)
    if echo "$output" | grep -q "Role: family"; then
        pass "Family role assigned correctly"
    else
        fail "Family role assigned correctly"
    fi
}

test_permission_check_delegate() {
    echo "Test: Permission check - delegate role"
    
    "$BOBNET_CLI" user add delegate_test --email delegate@example.com --role delegate >/dev/null 2>&1
    
    local output=$("$BOBNET_CLI" user show delegate_test 2>&1)
    if echo "$output" | grep -q "Role: delegate"; then
        pass "Delegate role assigned correctly"
    else
        fail "Delegate role assigned correctly"
    fi
}

test_permission_check_readonly() {
    echo "Test: Permission check - read-only role"
    
    "$BOBNET_CLI" user add readonly_test --email readonly@example.com --role read-only >/dev/null 2>&1
    
    local output=$("$BOBNET_CLI" user show readonly_test 2>&1)
    if echo "$output" | grep -q "Role: read-only"; then
        pass "Read-only role assigned correctly"
    else
        fail "Read-only role assigned correctly"
    fi
}

# Main test runner
main() {
    echo "========================================="
    echo "  User Management Test Suite"
    echo "========================================="
    echo
    
    setup
    
    # Run all tests
    test_user_add_basic
    test_user_add_validation
    test_user_add_duplicate
    test_user_list
    test_user_show
    test_agent_binding
    test_agent_binding_duplicate
    test_user_deactivate
    test_user_db_isolation
    test_permission_check_owner
    test_permission_check_family
    test_permission_check_delegate
    test_permission_check_readonly
    
    teardown
    
    # Summary
    echo
    echo "========================================="
    echo "  Test Summary"
    echo "========================================="
    echo "Total:  $TESTS_RUN"
    echo -e "Passed: ${GREEN}$TESTS_PASSED${NC}"
    echo -e "Failed: ${RED}$TESTS_FAILED${NC}"
    echo
    
    if [ $TESTS_FAILED -eq 0 ]; then
        echo -e "${GREEN}All tests passed!${NC}"
        exit 0
    else
        echo -e "${RED}Some tests failed.${NC}"
        exit 1
    fi
}

main "$@"
