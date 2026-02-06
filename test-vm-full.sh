#!/bin/bash
#######################################
# BobNet Full VM Test Runner
# 
# Creates Ubuntu VM and runs full test suite
# 
# Usage:
#   ./test-vm-full.sh [--name <vm-name>] [--keep] [--verbose]
#
# Options:
#   --name <name>    VM name (default: bobnet-test)
#   --keep           Keep VM after tests (don't delete)
#   --verbose        Show verbose output from tests
#
#######################################

set -euo pipefail

VM_NAME="bobnet-test"
KEEP_VM=false
VERBOSE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --name) VM_NAME="$2"; shift 2 ;;
        --keep) KEEP_VM=true; shift ;;
        --verbose|-v) VERBOSE="--verbose"; shift ;;
        -h|--help)
            cat <<'EOF'
Usage: ./test-vm-full.sh [options]

Creates Ubuntu VM and runs full BobNet upgrade test suite.

OPTIONS:
  --name <name>    VM name (default: bobnet-test)
  --keep           Keep VM after tests complete
  --verbose, -v    Show verbose test output

EXAMPLES:
  ./test-vm-full.sh                    # Default: create VM, run tests, delete VM
  ./test-vm-full.sh --keep             # Keep VM after tests
  ./test-vm-full.sh --name my-test     # Custom VM name
  ./test-vm-full.sh --verbose --keep   # Verbose + keep VM

CLEANUP:
  multipass delete <vm-name>
  multipass purge
EOF
            exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

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

warn() { 
    echo -e "${YELLOW}⚠${NC} $*" 
}

cleanup() {
    if [[ "$KEEP_VM" == "false" ]]; then
        log "Cleaning up VM: $VM_NAME"
        multipass delete "$VM_NAME" 2>/dev/null || true
        multipass purge 2>/dev/null || true
        success "VM deleted"
    else
        log "VM kept: $VM_NAME"
        echo "  To access: multipass shell $VM_NAME"
        echo "  To delete: multipass delete $VM_NAME && multipass purge"
    fi
}

#######################################
# Main
#######################################

main() {
    log "BobNet Full VM Test"
    echo ""
    
    # Check prerequisites
    if ! command -v multipass &>/dev/null; then
        error "multipass not found. Install: brew install multipass"
    fi
    
    # Check if VM already exists
    if multipass list 2>/dev/null | grep -q "^${VM_NAME} "; then
        warn "VM '$VM_NAME' already exists"
        read -p "Delete and recreate? [y/N] " -r
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            log "Deleting existing VM..."
            multipass delete "$VM_NAME"
            multipass purge
            success "Deleted"
        else
            error "Aborted (VM already exists)"
        fi
    fi
    
    # Create VM
    log "Creating VM: $VM_NAME (2 CPUs, 4GB RAM, 20GB disk)"
    if multipass launch --name "$VM_NAME" --cpus 2 --memory 4G --disk 20G; then
        success "VM created"
    else
        error "Failed to create VM"
    fi
    echo ""
    
    # Wait for VM to be ready
    log "Waiting for VM to be ready..."
    sleep 5
    success "VM ready"
    echo ""
    
    # Run tests inside VM
    log "Running test suite inside VM..."
    echo ""
    
    # Build test command
    local test_cmd="sudo apt update && \
sudo apt install -y nodejs npm git jq curl && \
npm install -g openclaw@2026.1.30 && \
export PATH=\"\$HOME/.local/bin:\$PATH\" && \
curl -fsSL https://raw.githubusercontent.com/buildzero-tech/bobnet-cli/main/install.sh | bash -s -- --update && \
curl -fsSL https://raw.githubusercontent.com/buildzero-tech/bobnet-cli/main/test-suite-vm.sh | bash"
    
    # Add verbose flag if requested
    if [[ -n "$VERBOSE" ]]; then
        test_cmd="${test_cmd} ${VERBOSE}"
    fi
    
    # Execute tests
    if multipass exec "$VM_NAME" -- bash -c "$test_cmd"; then
        echo ""
        success "All tests passed! ✨"
        TEST_RESULT=0
    else
        echo ""
        error "Tests failed"
        TEST_RESULT=1
    fi
    echo ""
    
    # Cleanup or keep
    cleanup
    
    echo ""
    if [[ $TEST_RESULT -eq 0 ]]; then
        log "✅ Test suite completed successfully"
    else
        log "❌ Test suite failed"
        exit 1
    fi
}

# Run main and ensure cleanup on exit
trap cleanup EXIT
main "$@"
