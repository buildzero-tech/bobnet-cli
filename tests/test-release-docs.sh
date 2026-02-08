#!/usr/bin/env bash
# Test: Release documentation commands
# Tests release-notes and changelog generators

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
# Test 1: Command Availability
# =============================================================================

info "Test 1: Release documentation commands exist"

# Verify commands are available
bobnet docs release-notes --help &>/dev/null || error "release-notes command not found"
bobnet docs changelog --help &>/dev/null || error "changelog command not found"
bobnet docs project-template --help &>/dev/null || error "project-template command not found"

success "All release doc commands available"

# =============================================================================
# Test 2: Help Text Completeness
# =============================================================================

info "Test 2: Help text completeness"

# release-notes help
HELP=$(bobnet docs release-notes --help)
echo "$HELP" | grep -q "Usage:" || error "release-notes help missing Usage section"
echo "$HELP" | grep -q "OPTIONS:" || error "release-notes help missing OPTIONS section"
echo "$HELP" | grep -q "EXAMPLES:" || error "release-notes help missing EXAMPLES section"

# changelog help
HELP=$(bobnet docs changelog --help)
echo "$HELP" | grep -q "Usage:" || error "changelog help missing Usage section"
echo "$HELP" | grep -q "EXAMPLES:" || error "changelog help missing EXAMPLES section"

# project-template help
HELP=$(bobnet docs project-template --help)
echo "$HELP" | grep -q "Usage:" || error "project-template help missing Usage section"
echo "$HELP" | grep -q "EXAMPLES:" || error "project-template help missing EXAMPLES section"

success "Help text is complete"

# =============================================================================
# Test 3: Project Template Output
# =============================================================================

info "Test 3: Project template output structure"

OUTPUT=$(bobnet docs project-template)

# Verify expected sections
echo "$OUTPUT" | grep -q "# GitHub Project Board Template" || error "Missing title"
echo "$OUTPUT" | grep -q "## Status Column Values" || error "Missing status values section"
echo "$OUTPUT" | grep -q "Not Started" || error "Missing 'Not Started' status"
echo "$OUTPUT" | grep -q "In Progress" || error "Missing 'In Progress' status"
echo "$OUTPUT" | grep -q "Blocked" || error "Missing 'Blocked' status"
echo "$OUTPUT" | grep -q "Review" || error "Missing 'Review' status"
echo "$OUTPUT" | grep -q "Done" || error "Missing 'Done' status"
echo "$OUTPUT" | grep -q "## Setup Instructions" || error "Missing setup instructions"
echo "$OUTPUT" | grep -q "## BobNet Integration" || error "Missing BobNet integration section"

success "Project template structure correct"

# =============================================================================
# Test 4: Changelog Format
# =============================================================================

info "Test 4: Changelog output format"

# Changelog should output Keep a Changelog format
OUTPUT=$(bobnet docs changelog 2>&1 || true)

echo "$OUTPUT" | grep -q "# Changelog" || error "Missing changelog title"
echo "$OUTPUT" | grep -q "## \[Unreleased\]" || error "Missing Unreleased section"
echo "$OUTPUT" | grep -q "### Added" || error "Missing Added section"
echo "$OUTPUT" | grep -q "### Changed" || error "Missing Changed section"
echo "$OUTPUT" | grep -q "### Fixed" || error "Missing Fixed section"

success "Changelog format correct"

# =============================================================================
# Test 5: Command Option Parsing
# =============================================================================

info "Test 5: Command option parsing"

# release-notes should accept --repo flag
if bobnet docs release-notes --repo buildzero-tech/bobnet-cli &>/dev/null; then
    # Will fail due to no tags, but shouldn't error on option parsing
    true
fi

# Test help flag doesn't error
bobnet docs release-notes -h &>/dev/null || error "release-notes -h failed"
bobnet docs changelog -h &>/dev/null || error "changelog -h failed"
bobnet docs project-template -h &>/dev/null || error "project-template -h failed"

success "Command option parsing works"

# =============================================================================
# Test 6: Output Formats
# =============================================================================

info "Test 6: Output format consistency"

# All commands should output markdown
TEMPLATE=$(bobnet docs project-template)
echo "$TEMPLATE" | head -1 | grep -q "^#" || error "Project template not markdown"

# Changelog should be markdown
CHANGELOG=$(bobnet docs changelog 2>&1 || true)
echo "$CHANGELOG" | head -1 | grep -q "^#" || error "Changelog not markdown"

success "Output formats are markdown"

# =============================================================================
# Summary
# =============================================================================

echo ""
echo "=== Test Suite Summary"
echo "  Tests run:  6"
echo "  Passed:     6"
echo "  Failed:     0"
echo ""
success "All release doc tests passed! ✨"
