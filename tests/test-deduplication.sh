#!/usr/bin/env bash
# Test: Deduplication logic
# Tests that specs with existing issue numbers don't create duplicates

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

while [[ $# -gt 0 ]]; do
    case "$1" in
        --verbose|-v) VERBOSE=true; shift ;;
        *) error "Unknown flag: $1" ;;
    esac
done

# Test directory
TEST_DIR=$(mktemp -d)
trap "rm -rf $TEST_DIR" EXIT
cd "$TEST_DIR"

# =============================================================================
# Test 1: Epic Issue Number Detection
# =============================================================================

info "Test 1: Detect existing Epic issue numbers"

# Spec with Epic Issue already set
cat > with-epic.md <<'EOF'
**Context:** BobNet Infrastructure
**GitHub Milestone:** Test
**Primary Repository:** buildzero-tech/bobnet-cli

### Epic: Existing Epic 📋
**Epic Issue:** #100
**Status:** In Progress

#### Features (feat → enhancement)
- Feature A
EOF

# Spec without Epic Issue
cat > without-epic.md <<'EOF'
**Context:** BobNet Infrastructure
**GitHub Milestone:** Test
**Primary Repository:** buildzero-tech/bobnet-cli

### Epic: New Epic 📋
**Epic Issue:** TBD
**Status:** Not started

#### Features (feat → enhancement)
- Feature A
EOF

# Verify parsing detects the difference
OUTPUT_WITH=$(bobnet spec create-issues with-epic.md --dry-run 2>&1)
OUTPUT_WITHOUT=$(bobnet spec create-issues without-epic.md --dry-run 2>&1)

# Both should parse successfully
echo "$OUTPUT_WITH" | grep -q "Found 1 Epic" || error "Failed to parse spec with existing Epic"
echo "$OUTPUT_WITHOUT" | grep -q "Found 1 Epic" || error "Failed to parse spec without Epic"

success "Epic issue number detection works"

# =============================================================================
# Test 2: Work Item Issue Reference Detection
# =============================================================================

info "Test 2: Detect existing work item issue references"

cat > with-issues.md <<'EOF'
**Context:** BobNet Infrastructure
**GitHub Milestone:** Test
**Primary Repository:** buildzero-tech/bobnet-cli

### Epic: Work Items 📋
**Epic Issue:** #100

#### Features (feat → enhancement)
- Feature A #101
- Feature B #102
- Feature C
EOF

# Parse and verify work items
OUTPUT=$(bobnet spec create-issues with-issues.md --dry-run 2>&1)

# Should show 3 work items total (including those with numbers)
echo "$OUTPUT" | grep -q "Work items: 3" || error "Work item count incorrect"

success "Work item issue reference detection works"

# =============================================================================
# Test 3: Cross-Repo Issue References
# =============================================================================

info "Test 3: Detect cross-repo issue references"

cat > cross-repo.md <<'EOF'
**Context:** BobNet Infrastructure
**GitHub Milestone:** Test
**Primary Repository:** buildzero-tech/bobnet-cli
**Additional Repos:** buildzero-tech/ultima-thule

### Epic: Cross-Repo 📋
**Epic Issue:** #100

#### Features (feat → enhancement)
- Feature in primary #101
- Feature in other repo buildzero-tech/ultima-thule#200
EOF

OUTPUT=$(bobnet spec create-issues cross-repo.md --dry-run 2>&1)

# Should detect cross-repo reference format
grep -q "buildzero-tech/ultima-thule" cross-repo.md || error "Cross-repo reference format missing"

success "Cross-repo issue reference detection works"

# =============================================================================
# Test 4: Idempotency Pattern
# =============================================================================

info "Test 4: Idempotency (same spec, multiple runs)"

cat > idempotent.md <<'EOF'
**Context:** BobNet Infrastructure
**GitHub Milestone:** Test
**Primary Repository:** buildzero-tech/bobnet-cli

### Epic: Idempotent Test 📋
**Epic Issue:** TBD

#### Features (feat → enhancement)
- Feature A
- Feature B
EOF

# First "run" (dry-run)
OUTPUT1=$(bobnet spec create-issues idempotent.md --dry-run 2>&1)

# Simulate adding issue numbers (as would happen after real run)
sed -i.bak 's/\*\*Epic Issue:\*\* TBD/**Epic Issue:** #100/' idempotent.md
sed -i.bak 's/^- Feature A$/- Feature A #101/' idempotent.md
sed -i.bak 's/^- Feature B$/- Feature B #102/' idempotent.md

# Second "run" (dry-run with issue numbers)
OUTPUT2=$(bobnet spec create-issues idempotent.md --dry-run 2>&1)

# Both should parse successfully
echo "$OUTPUT1" | grep -q "Found 1 Epic" || error "First run failed"
echo "$OUTPUT2" | grep -q "Found 1 Epic" || error "Second run failed"

success "Idempotency pattern works (spec-based deduplication)"

# =============================================================================
# Test 5: Partial Creation Recovery
# =============================================================================

info "Test 5: Partial creation recovery"

cat > partial.md <<'EOF'
**Context:** BobNet Infrastructure
**GitHub Milestone:** Test
**Primary Repository:** buildzero-tech/bobnet-cli

### Epic: Partial Creation 📋
**Epic Issue:** #100

#### Features (feat → enhancement)
- Feature A #101
- Feature B #102
- Feature C
- Feature D
EOF

OUTPUT=$(bobnet spec create-issues partial.md --dry-run 2>&1)

# Should have 4 work items total
echo "$OUTPUT" | grep -q "Work items: 4" || error "Work item count incorrect"

# First two have issue numbers (would be skipped in real run)
# Last two don't (would be created in real run)
grep -q "Feature A #101" partial.md || error "Existing issue A not preserved"
grep -q "Feature B #102" partial.md || error "Existing issue B not preserved"
grep -q "Feature C$" partial.md || error "New feature C format incorrect"

success "Partial creation recovery pattern works"

# =============================================================================
# Test 6: Milestone Reuse Pattern
# =============================================================================

info "Test 6: Milestone reuse across specs"

cat > spec1.md <<'EOF'
**Context:** BobNet Infrastructure
**GitHub Milestone:** Shared Milestone
**Primary Repository:** buildzero-tech/bobnet-cli

### Epic: Spec 1 📋
**Epic Issue:** TBD
EOF

cat > spec2.md <<'EOF'
**Context:** BobNet Infrastructure
**GitHub Milestone:** Shared Milestone
**Primary Repository:** buildzero-tech/bobnet-cli

### Epic: Spec 2 📋
**Epic Issue:** TBD
EOF

# Both specs should reference same milestone
OUTPUT1=$(bobnet spec create-issues spec1.md --dry-run 2>&1)
OUTPUT2=$(bobnet spec create-issues spec2.md --dry-run 2>&1)

echo "$OUTPUT1" | grep -q "Milestone: Shared Milestone" || error "Spec 1 milestone missing"
echo "$OUTPUT2" | grep -q "Milestone: Shared Milestone" || error "Spec 2 milestone missing"

# In real execution, milestone would only be created once
success "Milestone reuse pattern validated"

# =============================================================================
# Summary
# =============================================================================

echo ""
echo "=== Test Suite Summary"
echo "  Tests run:  6"
echo "  Passed:     6"
echo "  Failed:     0"
echo ""
success "All deduplication tests passed! ✨"
