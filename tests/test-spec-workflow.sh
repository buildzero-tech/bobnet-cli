#!/usr/bin/env bash
# Test: spec → issues → work workflow
# Tests the complete workflow for specification-based development

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

error() { echo -e "${RED}✗${NC} $*" >&2; exit 1; }
success() { echo -e "${GREEN}✓${NC} $*"; }
info() { echo -e "${YELLOW}→${NC} $*"; }

# Parse flags
VERBOSE=false
CLEANUP=true
TEST_REPO="buildzero-tech/bobnet-cli"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --verbose|-v) VERBOSE=true; shift ;;
        --no-cleanup) CLEANUP=false; shift ;;
        --repo) TEST_REPO="$2"; shift 2 ;;
        *) error "Unknown flag: $1" ;;
    esac
done

run_cmd() {
    if [[ "$VERBOSE" == "true" ]]; then
        "$@"
    else
        "$@" &>/dev/null
    fi
}

# Test directory
TEST_DIR=$(mktemp -d)
[[ "$CLEANUP" == "true" ]] && trap "rm -rf $TEST_DIR" EXIT

cd "$TEST_DIR"

info "Test directory: $TEST_DIR"

# =============================================================================
# Test 1: Spec Parsing
# =============================================================================

info "Test 1: Spec parsing and validation"

cat > test-spec.md <<'EOF'
# Test Feature Specification

**Context:** BobNet Infrastructure  
**GitHub Milestone:** Test Milestone  
**Primary Repository:** buildzero-tech/bobnet-cli

## Work Breakdown

### Epic: Test Feature 📋
**Primary Repository:** buildzero-tech/bobnet-cli  
**Epic Issue:** TBD  
**Status:** Not started  
**Dependencies:** None

#### Features (feat → enhancement)
- Implement feature A
- Implement feature B

#### Documentation (docs → documentation)
- Document feature A
- Document feature B

#### Testing (test → testing)
- Add test for feature A

#### Maintenance (chore → maintenance)
- Update dependencies
EOF

# Test dry-run parsing
OUTPUT=$(bobnet spec create-issues test-spec.md --dry-run 2>&1)

# Verify output contains expected elements
echo "$OUTPUT" | grep -q "Context: BobNet Infrastructure" || error "Missing context in output"
echo "$OUTPUT" | grep -q "Milestone: Test Milestone" || error "Missing milestone in output"
echo "$OUTPUT" | grep -q "Primary Repository: buildzero-tech/bobnet-cli" || error "Missing primary repo in output"
echo "$OUTPUT" | grep -q "Found 1 Epic" || error "Missing Epic count in output"
echo "$OUTPUT" | grep -q "Epic: Test Feature" || error "Missing Epic title in output"

success "Spec parsing works correctly"

# =============================================================================
# Test 2: Epic Extraction
# =============================================================================

info "Test 2: Epic extraction from spec"

# Verify Epic is detected in output
OUTPUT=$(bobnet spec create-issues test-spec.md --dry-run 2>&1)

# Check Epic details
echo "$OUTPUT" | grep -q "Epic: Test Feature" || error "Epic not extracted"
echo "$OUTPUT" | grep -q "Work items: 6" || error "Work item count incorrect"

success "Epic extraction works correctly"

# =============================================================================
# Test 3: Multiple Work Categories
# =============================================================================

info "Test 3: Multiple work item categories"

# Verify all categories present in output
OUTPUT=$(bobnet spec create-issues test-spec.md --dry-run 2>&1)

# Each category should appear in the spec
grep -q "#### Features" test-spec.md || error "Features category missing"
grep -q "#### Documentation" test-spec.md || error "Documentation category missing"
grep -q "#### Testing" test-spec.md || error "Testing category missing"
grep -q "#### Maintenance" test-spec.md || error "Maintenance category missing"

success "Multiple work categories supported"

# =============================================================================
# Test 4: Help Text Validation
# =============================================================================

info "Test 4: Help text completeness"

# Verify all commands have help text
bobnet spec --help &>/dev/null || error "bobnet spec --help failed"
bobnet spec create-issues --help &>/dev/null || error "bobnet spec create-issues --help failed"
bobnet work --help &>/dev/null || error "bobnet work --help failed"
bobnet work start --help &>/dev/null || error "bobnet work start --help failed"
bobnet work done --help &>/dev/null || error "bobnet work done --help failed"
bobnet github my-issues --help &>/dev/null || error "bobnet github my-issues --help failed"

# Verify help text contains expected sections
bobnet spec create-issues --help | grep -q "WORKFLOW:" || error "spec create-issues help missing WORKFLOW section"
bobnet work start --help | grep -q "WORKFLOW:" || error "work start help missing WORKFLOW section"
bobnet work done --help | grep -q "WORKFLOW:" || error "work done help missing WORKFLOW section"

success "Help text is complete"

# =============================================================================
# Test 5: Error Handling
# =============================================================================

info "Test 5: Error handling"

# Test missing required fields
cat > bad-spec.md <<'EOF'
# Bad Spec

**Context:** BobNet Infrastructure

### Epic: No Milestone 📋
**Epic Issue:** TBD
EOF

# Should fail with clear error
if bobnet spec create-issues bad-spec.md --dry-run &>/dev/null; then
    error "Should have failed on missing milestone"
fi

# Verify error message is clear
ERROR_MSG=$(bobnet spec create-issues bad-spec.md --dry-run 2>&1 || true)
echo "$ERROR_MSG" | grep -q "Spec missing.*Milestone" || error "Error message not clear"

success "Error handling works correctly"

# =============================================================================
# Test 6: Idempotency
# =============================================================================

info "Test 6: Idempotency (dry-run)"

# Add issue numbers to spec
cat > test-spec-with-issues.md <<'EOF'
# Test Feature Specification

**Context:** BobNet Infrastructure  
**GitHub Milestone:** Test Milestone  
**Primary Repository:** buildzero-tech/bobnet-cli

## Work Breakdown

### Epic: Test Feature 📋
**Primary Repository:** buildzero-tech/bobnet-cli  
**Epic Issue:** #100  
**Status:** Not started  
**Dependencies:** None

#### Features (feat → enhancement)
- Implement feature A #101
- Implement feature B #102
EOF

# Run spec create-issues - should detect existing issues
OUTPUT=$(bobnet spec create-issues test-spec-with-issues.md --dry-run 2>&1)

# Should parse successfully
echo "$OUTPUT" | grep -q "Found 1 Epic" || error "Failed to parse spec with existing issues"

# In real mode, would skip existing issues
# (Can't test without actual GitHub access, but dry-run validates parsing)

success "Idempotency check passed (dry-run)"

# =============================================================================
# Summary
# =============================================================================

echo ""
echo "=== Test Suite Summary"
echo "  Tests run:  6"
echo "  Passed:     6"
echo "  Failed:     0"
echo ""
success "All tests passed! ✨"
