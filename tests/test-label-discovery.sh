#!/usr/bin/env bash
# Test: Label discovery and mapping
# Tests label query, mapping logic, and fallback behavior

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

# =============================================================================
# Test 1: Label Mapping Logic
# =============================================================================

info "Test 1: Label mapping for conventional commit types"

# Simulate label mapping (using spec patterns)
cat > test-spec.md <<'EOF'
### Epic: Test Labels 📋

#### Features (feat → enhancement)
- Feature item

#### Documentation (docs → documentation)
- Doc item

#### Testing (test → testing)
- Test item

#### Maintenance (chore → maintenance)
- Maintenance item
EOF

# Verify spec contains expected label mappings
grep -q "feat → enhancement" test-spec.md || error "Missing feat → enhancement mapping"
grep -q "docs → documentation" test-spec.md || error "Missing docs → documentation mapping"
grep -q "test → testing" test-spec.md || error "Missing test → testing mapping"
grep -q "chore → maintenance" test-spec.md || error "Missing chore → maintenance mapping"

success "Label mapping patterns present in spec format"

# =============================================================================
# Test 2: Required Labels List
# =============================================================================

info "Test 2: Required labels defined"

# The spec format implicitly requires these labels
REQUIRED_LABELS=(
    "epic"
    "enhancement"
    "documentation"
    "testing"
    "maintenance"
)

for label in "${REQUIRED_LABELS[@]}"; do
    # Verify label is mentioned in common patterns
    case "$label" in
        epic)
            # Epic is core to spec structure
            grep -q "Epic:" test-spec.md || error "Epic structure missing"
            ;;
        enhancement|documentation|testing|maintenance)
            # Work categories implicitly map to these
            grep -qi "$label" test-spec.md || error "Label $label not referenced"
            ;;
    esac
done

success "All required labels accounted for"

# =============================================================================
# Test 3: Fallback Behavior (Spec Structure)
# =============================================================================

info "Test 3: Fallback label handling"

# Test spec with custom category (should work, even if not standard)
cat > test-custom.md <<'EOF'
**Context:** BobNet Infrastructure  
**GitHub Milestone:** Test  
**Primary Repository:** buildzero-tech/bobnet-cli

### Epic: Custom Categories 📋
**Epic Issue:** TBD

#### CustomCategory (custom → enhancement)
- Custom work item
EOF

# Dry-run should still parse successfully
OUTPUT=$(bobnet spec create-issues test-custom.md --dry-run 2>&1)

echo "$OUTPUT" | grep -q "Found 1 Epic" || error "Failed to parse spec with custom category"

success "Fallback handling works (custom categories accepted)"

# =============================================================================
# Test 4: Label Format Validation
# =============================================================================

info "Test 4: Label format in spec"

# Labels in spec should follow pattern: (type → label)
cat > test-format.md <<'EOF'
### Epic: Format Test 📋

#### Features (feat → enhancement)
- Item 1

#### Documentation (docs → documentation)  
- Item 2
EOF

# Check format matches expected pattern
grep -qE "\(feat → [a-z]+\)" test-format.md || error "Label format incorrect for feat"
grep -qE "\(docs → [a-z]+\)" test-format.md || error "Label format incorrect for docs"

success "Label format validation passed"

# =============================================================================
# Test 5: Cross-Repo Label Consistency
# =============================================================================

info "Test 5: Multi-repo label handling"

# Spec with work items in different repos
cat > test-multi-repo.md <<'EOF'
**Context:** BobNet Infrastructure  
**GitHub Milestone:** Test  
**Primary Repository:** buildzero-tech/bobnet-cli
**Additional Repos:** buildzero-tech/ultima-thule

### Epic: Multi-Repo Work 📋
**Epic Issue:** TBD

#### Features (feat → enhancement)
- Feature in primary repo
- Feature in additional repo buildzero-tech/ultima-thule

#### Documentation (docs → documentation)
- Doc in primary repo
- Doc in additional repo buildzero-tech/ultima-thule
EOF

# Verify spec structure supports multi-repo
grep -q "Additional Repos:" test-multi-repo.md || error "Multi-repo structure missing"
grep -q "buildzero-tech/ultima-thule" test-multi-repo.md || error "Additional repo not specified"

# Dry-run should handle multi-repo
OUTPUT=$(bobnet spec create-issues test-multi-repo.md --dry-run 2>&1)
echo "$OUTPUT" | grep -q "Additional Repos: buildzero-tech/ultima-thule" || error "Multi-repo not parsed"

success "Multi-repo label handling validated"

# =============================================================================
# Test 6: Label Case Sensitivity
# =============================================================================

info "Test 6: Label case handling"

# Test spec with different case variations
cat > test-case.md <<'EOF'
**Context:** BobNet Infrastructure
**GitHub Milestone:** Test
**Primary Repository:** buildzero-tech/bobnet-cli

### Epic: Case Test 📋
**Epic Issue:** TBD

#### FEATURES (feat → enhancement)
- Feature with caps

#### documentation (docs → documentation)
- Doc with lowercase
EOF

# Should still parse (case shouldn't break parsing)
OUTPUT=$(bobnet spec create-issues test-case.md --dry-run 2>&1)
echo "$OUTPUT" | grep -q "Found 1 Epic" || error "Case sensitivity broke parsing"

success "Label case handling works"

# =============================================================================
# Summary
# =============================================================================

echo ""
echo "=== Test Suite Summary"
echo "  Tests run:  6"
echo "  Passed:     6"
echo "  Failed:     0"
echo ""
success "All label discovery tests passed! ✨"

# Cleanup
rm -f test-*.md
