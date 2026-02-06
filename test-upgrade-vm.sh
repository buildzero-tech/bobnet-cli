#!/bin/bash
#######################################
# BobNet Upgrade Test Script
# 
# Tests: OpenClaw upgrade path
# 
# Usage:
#   ./test-upgrade-vm.sh [--verbose] [--clean]
#
# Options:
#   --verbose, -v    Show command output
#   --clean          Force clean install (delete existing repos)
#
# Environment:
#   OPENCLAW_CURRENT   Starting version (default: 2026.1.30)
#   OPENCLAW_TARGET    Target version (default: latest)
#
# Examples:
#   # Default: 2026.1.30 → latest
#   ./test-upgrade-vm.sh
#
#   # Specific versions
#   OPENCLAW_CURRENT=2026.2.1 OPENCLAW_TARGET=2026.2.3-1 ./test-upgrade-vm.sh
#
#######################################

set -euo pipefail

VERBOSE=false
CLEAN=false
OPENCLAW_CURRENT="${OPENCLAW_CURRENT:-2026.1.30}"
OPENCLAW_TARGET="${OPENCLAW_TARGET:-latest}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --verbose|-v) VERBOSE=true; shift ;;
        --clean) CLEAN=true; shift ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

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
    log "=== BobNet Upgrade Test ==="
    log "Testing: OpenClaw $OPENCLAW_CURRENT → $OPENCLAW_TARGET"
    echo ""
    
    # 1. Check prerequisites
    log "--- Prerequisites ---"
    command -v node &>/dev/null || error "Node.js not found"
    command -v npm &>/dev/null || error "npm not found"
    command -v git &>/dev/null || error "git not found"
    command -v jq &>/dev/null || error "jq not found"
    success "All tools present"
    echo ""
    
    # 2. Install OpenClaw (current version)
    log "--- Install OpenClaw $OPENCLAW_CURRENT ---"
    if command -v openclaw &>/dev/null; then
        local current=$(openclaw --version 2>/dev/null | head -1)
        if [[ "$current" == "$OPENCLAW_CURRENT" ]]; then
            success "OpenClaw $OPENCLAW_CURRENT already installed"
        else
            warn "OpenClaw already installed: $current"
            if [[ "$CLEAN" == "true" ]]; then
                log "Clean mode: reinstalling $OPENCLAW_CURRENT"
                run_cmd "Installing OpenClaw $OPENCLAW_CURRENT" npm install -g "openclaw@$OPENCLAW_CURRENT"
            else
                log "Skipping reinstall (use --clean to force)"
            fi
        fi
    else
        run_cmd "Installing OpenClaw $OPENCLAW_CURRENT" npm install -g "openclaw@$OPENCLAW_CURRENT"
    fi
    
    # Add to PATH for this session
    export PATH="$HOME/.local/bin:$PATH"
    
    local version=$(openclaw --version 2>/dev/null | head -1)
    if [[ "$version" == "$OPENCLAW_CURRENT" ]]; then
        success "OpenClaw version: $version"
    else
        error "Expected $OPENCLAW_CURRENT, got: $version"
    fi
    echo ""
    
    # 3. Install BobNet CLI binary
    log "--- Install BobNet CLI Binary ---"
    log "Step 1/2: Install bobnet command to ~/.local/bin/bobnet"
    
    if [[ -f ~/.local/bin/bobnet ]]; then
        local bobnet_ver=$(bobnet --version 2>/dev/null || echo "unknown")
        success "BobNet CLI already installed: $bobnet_ver"
    else
        log "Downloading install.sh..."
        curl -fsSL https://raw.githubusercontent.com/buildzero-tech/bobnet-cli/main/install.sh | bash -s -- --update
        export PATH="$HOME/.local/bin:$PATH"
        success "BobNet CLI binary installed"
    fi
    
    local bobnet_ver=$(bobnet --version 2>/dev/null || echo "unknown")
    log "BobNet CLI version: $bobnet_ver"
    log "Binary location: $(which bobnet)"
    echo ""
    
    # 4. Create minimal test repo
    log "--- Create Test Repo ---"
    local repo_dir="${BOBNET_ROOT:-$HOME/.bobnet/ultima-thule}"
    
    if [[ -d "$repo_dir" ]]; then
        if [[ "$CLEAN" == "true" ]]; then
            warn "Clean mode: deleting existing repo"
            rm -rf "$repo_dir"
        else
            success "Using existing repo: $repo_dir"
        fi
    fi
    
    if [[ ! -d "$repo_dir" ]]; then
        mkdir -p "$repo_dir"/{config,workspace/bob,agents/bob}
        
        # Create minimal bobnet.json
        cat > "$repo_dir/config/bobnet.json" << 'EOF'
{
  "version": "3.5",
  "description": "Test repo for upgrade validation",
  "defaults": {
    "model": "anthropic/claude-sonnet-4-5"
  },
  "agents": {
    "bob": {
      "scope": "meta",
      "default": true,
      "model": "anthropic/claude-sonnet-4-5",
      "description": "Test agent"
    }
  },
  "scopes": {
    "meta": {
      "label": "Meta",
      "collective": "collective/"
    }
  }
}
EOF
        
        # Initialize git
        cd "$repo_dir"
        git init
        git add -A
        git commit -m "Initial test repo" >/dev/null
        
        success "Created test repo: $repo_dir"
    else
        success "Using existing repo: $repo_dir"
    fi
    echo ""
    
    # 5. Install BobNet config into OpenClaw
    log "--- Install BobNet Config into OpenClaw ---"
    log "Step 2/2: Sync config/bobnet.json → OpenClaw config"
    cd "$repo_dir"
    
    log "Running: bobnet install"
    log "  This reads config/bobnet.json and syncs to ~/.openclaw/openclaw.json"
    run_cmd "Syncing BobNet config to OpenClaw" bobnet install --yes
    
    success "BobNet config installed into OpenClaw"
    log "  - Agents synced to OpenClaw"
    log "  - Bindings synced to OpenClaw"
    log "  - Channels synced to OpenClaw"
    echo ""
    
    # 6. Validate pre-upgrade state
    log "--- Pre-Upgrade Validation ---"
    run_cmd "Validating config" bobnet validate
    
    local pre_version=$(openclaw --version 2>/dev/null | head -1)
    log "OpenClaw version: $pre_version"
    
    if [[ ! -f "$repo_dir/config/openclaw-versions.json" ]]; then
        warn "Version tracking file not found - will be created during upgrade"
    else
        log "Version history:"
        cat "$repo_dir/config/openclaw-versions.json" | jq -r '.history[] | "  \(.version) - \(.status)"'
    fi
    echo ""
    
    # 7. Run upgrade
    log "--- Running Upgrade ---"
    log "Target: $OPENCLAW_TARGET"
    echo ""
    
    # Build upgrade command
    local upgrade_cmd="bobnet upgrade --openclaw --yes"
    [[ "$OPENCLAW_TARGET" != "latest" ]] && upgrade_cmd="$upgrade_cmd --version $OPENCLAW_TARGET"
    
    # Run upgrade (not silent - we want to see progress)
    if $upgrade_cmd; then
        success "Upgrade completed"
    else
        error "Upgrade failed"
    fi
    echo ""
    
    # 8. Validate post-upgrade state
    log "--- Post-Upgrade Validation ---"
    
    local post_version=$(openclaw --version 2>/dev/null | head -1)
    
    # Check version changed
    if [[ "$post_version" == "$pre_version" ]]; then
        error "Version unchanged: $post_version"
    else
        success "Version updated: $pre_version → $post_version"
    fi
    
    # Verify expected version (if not "latest")
    if [[ "$OPENCLAW_TARGET" != "latest" && "$post_version" != "$OPENCLAW_TARGET" ]]; then
        error "Expected $OPENCLAW_TARGET, got $post_version"
    fi
    
    run_cmd "Validating config" bobnet validate
    success "Config validation passed"
    
    if [[ -f "$repo_dir/config/openclaw-versions.json" ]]; then
        log "Version history:"
        cat "$repo_dir/config/openclaw-versions.json" | jq -r '.history[] | "  \(.version) - \(.status) (\(.installedAt))"'
    fi
    echo ""
    
    # 9. Summary
    log "=== Test Summary ==="
    success "Pre-upgrade:  $pre_version"
    success "Post-upgrade: $post_version"
    success "Config:       valid"
    success "Gateway:      $(openclaw gateway status >/dev/null 2>&1 && echo 'running' || echo 'stopped')"
    echo ""
    
    log "✅ All tests passed"
}

main "$@"
