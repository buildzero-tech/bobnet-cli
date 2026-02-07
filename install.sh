#!/bin/bash
#######################################
# BobNet CLI Installer
#######################################
#
# Usage:
#   curl -fsSL .../install.sh | bash                    # new repo
#   curl -fsSL .../install.sh | bash -s -- --clone URL  # clone existing
#   curl -fsSL .../install.sh | bash -s -- --update     # update CLI only
#
set -euo pipefail

BOBNET_CLI_VERSION="4.10.0"
BOBNET_CLI_URL="https://raw.githubusercontent.com/buildzero-tech/bobnet-cli/main/install.sh"

INSTALL_DIR="${BOBNET_DIR:-$HOME/.bobnet/ultima-thule}"
KEY_FILE="${BOBNET_KEY:-$HOME/.secrets/bobnet-vault.key}"
REPO_URL=""
REPO_MODE="new"
UPDATE_ONLY=false
VERBOSE=false

# Parse args
while [[ $# -gt 0 ]]; do
    case "$1" in
        --clone) REPO_URL="$2"; REPO_MODE="clone"; shift 2 ;;
        --key) KEY_FILE="$2"; shift 2 ;;
        --dir) INSTALL_DIR="$2"; shift 2 ;;
        --update) UPDATE_ONLY=true; shift ;;
        --verbose|-v) VERBOSE=true; shift ;;
        --version) echo "bobnet-cli v$BOBNET_CLI_VERSION"; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

log() { [[ "$VERBOSE" == "true" ]] && echo "[DEBUG] $*" || true; }

# Helper functions for install script
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
success() { echo -e "${GREEN}✓${NC} $*"; }
warn() { echo -e "${YELLOW}warn:${NC} $*" >&2; }
error() { echo -e "${RED}error:${NC} $*" >&2; exit 1; }

#######################################
# Install CLI to ~/.local
#######################################

install_cli() {
    log "Installing CLI v$BOBNET_CLI_VERSION to ~/.local/lib/bobnet/"
    mkdir -p ~/.local/bin ~/.local/lib/bobnet
    
    # Version file
    echo "$BOBNET_CLI_VERSION" > ~/.local/lib/bobnet/version
    
    # agents.sh library
    cat > ~/.local/lib/bobnet/agents.sh << 'AGENTS_SH'
#!/bin/bash
set -euo pipefail
BOBNET_ROOT="${BOBNET_ROOT:-$HOME/.bobnet/ultima-thule}"
# Schema location (try new name, fall back to old)
if [[ -f "$BOBNET_ROOT/config/bobnet.json" ]]; then
    AGENTS_SCHEMA="${AGENTS_SCHEMA:-$BOBNET_ROOT/config/bobnet.json}"
elif [[ -f "$BOBNET_ROOT/config/agents-schema.v3.json" ]]; then
    AGENTS_SCHEMA="${AGENTS_SCHEMA:-$BOBNET_ROOT/config/agents-schema.v3.json}"
else
    AGENTS_SCHEMA="${AGENTS_SCHEMA:-$BOBNET_ROOT/config/bobnet.json}"
fi
command -v jq &>/dev/null || { echo "jq required" >&2; exit 1; }
get_all_agents() { jq -r '.agents | keys[]' "$AGENTS_SCHEMA" 2>/dev/null || echo ""; }
get_agent_scope() { jq -r --arg a "$1" '.agents[$a].scope // "work"' "$AGENTS_SCHEMA" 2>/dev/null; }
get_agents_by_scope() { jq -r --arg s "$1" '.agents | to_entries[] | select(.value.scope == $s) | .key' "$AGENTS_SCHEMA" 2>/dev/null; }
get_workspace() { echo "$BOBNET_ROOT/workspace/$1"; }
get_agent_dir() { echo "$BOBNET_ROOT/agents/$1"; }
get_all_scopes() { jq -r '.scopes | keys[]' "$AGENTS_SCHEMA" 2>/dev/null || echo ""; }
agent_exists() { [[ -d "$(get_workspace "$1")" ]]; }
validate_agent() { agent_exists "$1" || { echo "Agent '$1' not found" >&2; return 1; }; }
is_agent_default() { [[ $(jq -r --arg a "$1" '.agents[$a].default // false' "$AGENTS_SCHEMA" 2>/dev/null) == "true" ]]; }
is_agent_reserved() { [[ $(jq -r --arg a "$1" '.agents[$a].reserved // false' "$AGENTS_SCHEMA" 2>/dev/null) == "true" ]]; }
get_reserved_agents() { jq -r '.agents | to_entries[] | select(.value.reserved == true) | .key' "$AGENTS_SCHEMA" 2>/dev/null; }
print_agent_summary() {
    echo "BobNet Agents"; echo "============="
    for scope in $(get_all_scopes); do
        echo "[$scope]"
        for agent in $(get_agents_by_scope "$scope"); do
            local e="✓"; [[ -d "$(get_workspace "$agent")" ]] || e="✗"
            local d=""; is_agent_default "$agent" && d=" (default)"
            echo "  $agent $e$d"
        done
    done
    # Show reserved agents separately
    local reserved=$(get_reserved_agents)
    if [[ -n "$reserved" ]]; then
        echo "[reserved]"
        for agent in $reserved; do
            local e="✓"; [[ -d "$(get_workspace "$agent")" ]] || e="✗"
            echo "  $agent $e"
        done
    fi
}
AGENTS_SH

    # Main CLI (full version)
    # Try to copy from local repo first, otherwise download
    if [[ -f "${BASH_SOURCE[0]%/*}/bobnet.sh" ]]; then
        cp "${BASH_SOURCE[0]%/*}/bobnet.sh" ~/.local/lib/bobnet/bobnet.sh
        log "Copied full bobnet.sh from local repo"
    elif [[ -f "$(pwd)/bobnet.sh" ]]; then
        cp "$(pwd)/bobnet.sh" ~/.local/lib/bobnet/bobnet.sh
        log "Copied full bobnet.sh from current directory"
    else
        log "Downloading full bobnet.sh from GitHub..."
        curl -fsSL "https://raw.githubusercontent.com/buildzero-tech/bobnet-cli/main/bobnet.sh" \
            > ~/.local/lib/bobnet/bobnet.sh
    fi
    chmod +x ~/.local/lib/bobnet/bobnet.sh
    
    # Verify it has the expected commands
    if ! grep -q "^cmd_github()" ~/.local/lib/bobnet/bobnet.sh; then
        echo "✗ Failed to install full bobnet.sh (missing cmd_github)" >&2
        exit 1
    fi
    success "Installed full bobnet.sh with all commands"
    

    # Wrapper script
    cat > ~/.local/bin/bobnet << 'WRAPPER'
#!/bin/bash
set -euo pipefail

# Find BOBNET_ROOT (may not exist)
if [[ -n "${BOBNET_ROOT:-}" ]]; then :
elif [[ -f "./config/bobnet.json" ]]; then BOBNET_ROOT="$(pwd)"
elif [[ -d "$HOME/.bobnet/ultima-thule" ]]; then BOBNET_ROOT="$HOME/.bobnet/ultima-thule"
else BOBNET_ROOT=""; fi

# Commands that work without a repo
case "${1:-help}" in
    help|--help|-h)
        source "$HOME/.local/lib/bobnet/bobnet.sh" 2>/dev/null || true
        cmd_help 2>/dev/null || echo "bobnet - BobNet CLI (run installer to set up repo)"
        exit 0 ;;
    --version)
        echo "bobnet v$(cat "$HOME/.local/lib/bobnet/version" 2>/dev/null || echo "unknown")"
        exit 0 ;;
    update)
        if [[ "${2:-}" == "-h" || "${2:-}" == "--help" ]]; then
            echo "Usage: bobnet update [--force]"
            echo ""
            echo "Update bobnet CLI to the latest version from GitHub."
            echo ""
            echo "OPTIONS:"
            echo "  --force, -f    Use gh API instead of curl (bypasses CDN cache)"
            exit 0
        fi
        _use_gh=false
        [[ "${2:-}" == "--force" || "${2:-}" == "-f" ]] && _use_gh=true
        
        echo "Checking for updates..."
        _current=$(cat "$HOME/.local/lib/bobnet/version" 2>/dev/null || echo "unknown")
        _remote=""
        
        if [[ "$_use_gh" == "true" ]]; then
            command -v gh &>/dev/null || { echo "gh CLI not found" >&2; exit 1; }
            _remote=$(gh api repos/buildzero-tech/bobnet-cli/contents/install.sh --jq '.content' 2>/dev/null | base64 -d | grep '^BOBNET_CLI_VERSION="' | cut -d'"' -f2)
        else
            _remote=$(curl -fsSL "https://raw.githubusercontent.com/buildzero-tech/bobnet-cli/main/install.sh" 2>/dev/null | grep '^BOBNET_CLI_VERSION="' | cut -d'"' -f2)
        fi
        
        if [[ -z "$_remote" ]]; then
            echo "Could not fetch remote version" >&2
            exit 1
        fi
        if [[ "$_current" == "$_remote" && "$_use_gh" != "true" ]]; then
            echo "Already at v$_current"
            exit 0
        fi
        echo "Updating v$_current → v$_remote..."
        if [[ "$_use_gh" == "true" ]]; then
            gh api repos/buildzero-tech/bobnet-cli/contents/install.sh --jq '.content' | base64 -d | bash -s -- --update
        else
            curl -fsSL "https://raw.githubusercontent.com/buildzero-tech/bobnet-cli/main/install.sh" | bash -s -- --update
        fi
        exit 0 ;;
    install|setup)
        if [[ -z "$BOBNET_ROOT" ]]; then
            echo "No BobNet repository found."
            echo ""
            
            # Check for existing ultima-thule repos on GitHub
            repos=()
            if command -v gh &>/dev/null && gh auth status &>/dev/null 2>&1; then
                while IFS= read -r repo; do
                    [[ -n "$repo" ]] && repos+=("$repo")
                done < <(gh repo list --limit 100 --json nameWithOwner,name -q '.[] | select(.name == "ultima-thule") | .nameWithOwner' 2>/dev/null)
                
                # Also check orgs user has access to
                while IFS= read -r org; do
                    if gh repo view "$org/ultima-thule" &>/dev/null 2>&1; then
                        [[ ! " ${repos[*]:-} " =~ " $org/ultima-thule " ]] && repos+=("$org/ultima-thule")
                    fi
                done < <(gh org list 2>/dev/null || true)
            fi
            
            if [[ ${#repos[@]} -gt 0 ]]; then
                echo "Found ultima-thule repo(s) on GitHub:"
                for i in "${!repos[@]}"; do
                    echo "  [$((i+1))] ${repos[$i]}"
                done
                echo "  [N] Create new repository"
                echo "  [C] Clone other (enter URL)"
                echo "  [Q] Quit"
                echo ""
                read -rp "Choice: " choice
                case "$choice" in
                    [0-9]*)
                        idx=$((choice - 1))
                        if [[ $idx -ge 0 && $idx -lt ${#repos[@]} ]]; then
                            repo="${repos[$idx]}"
                            echo "Cloning $repo..."
                            exec curl -fsSL "https://raw.githubusercontent.com/buildzero-tech/bobnet-cli/main/install.sh" | bash -s -- --clone "https://github.com/$repo.git"
                        else
                            echo "Invalid choice" >&2; exit 1
                        fi ;;
                    [Nn])
                        exec curl -fsSL "https://raw.githubusercontent.com/buildzero-tech/bobnet-cli/main/install.sh" | bash ;;
                    [Cc])
                        read -rp "Repository URL: " url
                        [[ -z "$url" ]] && { echo "No URL provided" >&2; exit 1; }
                        exec curl -fsSL "https://raw.githubusercontent.com/buildzero-tech/bobnet-cli/main/install.sh" | bash -s -- --clone "$url" ;;
                    [Qq]) exit 0 ;;
                    *) echo "Invalid choice" >&2; exit 1 ;;
                esac
            else
                echo "What would you like to do?"
                echo "  [N] Create new repository"
                echo "  [C] Clone existing (enter URL)"
                echo "  [Q] Quit"
                echo ""
                read -rp "Choice [N/c/q]: " choice
                case "$choice" in
                    [Cc])
                        read -rp "Repository URL: " url
                        [[ -z "$url" ]] && { echo "No URL provided" >&2; exit 1; }
                        exec curl -fsSL "https://raw.githubusercontent.com/buildzero-tech/bobnet-cli/main/install.sh" | bash -s -- --clone "$url" ;;
                    [Qq]) exit 0 ;;
                    *)
                        exec curl -fsSL "https://raw.githubusercontent.com/buildzero-tech/bobnet-cli/main/install.sh" | bash ;;
                esac
            fi
        fi ;;
    uninstall)
        if [[ -z "$BOBNET_ROOT" ]]; then
            echo "Nothing to uninstall — no BobNet repo found."
            exit 0
        fi ;;
esac

# All other commands require BOBNET_ROOT
if [[ -z "$BOBNET_ROOT" ]]; then
    echo "BOBNET_ROOT not found" >&2
    echo "Run: bobnet help" >&2
    exit 1
fi

export BOBNET_ROOT
export AGENTS_SCHEMA="$BOBNET_ROOT/config/bobnet.json"
source "$HOME/.local/lib/bobnet/agents.sh"
source "$HOME/.local/lib/bobnet/bobnet.sh"
bobnet_main "$@"
WRAPPER

    chmod +x ~/.local/bin/bobnet ~/.local/lib/bobnet/*.sh
}

#######################################
# Update-only mode
#######################################

if [[ "$UPDATE_ONLY" == "true" ]]; then
    install_cli
    echo "✓ Updated to v$BOBNET_CLI_VERSION"
    exit 0
fi

#######################################
# Full install
#######################################

echo "═══════════════════════════════════════════════════════════"
echo " BobNet Installer v$BOBNET_CLI_VERSION"
echo "═══════════════════════════════════════════════════════════"
echo ""

# Check if existing repo
[[ -d "$INSTALL_DIR/.git" ]] && REPO_MODE="existing"

# Prerequisites
echo "Checking prerequisites..."

command -v git &>/dev/null || { echo "✗ git required" >&2; exit 1; }
echo "  ✓ git"

if ! command -v git-crypt &>/dev/null; then
    echo "  Installing git-crypt..."
    if command -v apt-get &>/dev/null; then
        sudo apt-get update -qq && sudo apt-get install -y -qq git-crypt
    elif command -v brew &>/dev/null; then
        brew install git-crypt
    else
        echo "✗ Please install git-crypt" >&2; exit 1
    fi
fi
echo "  ✓ git-crypt"

if ! command -v jq &>/dev/null; then
    echo "  Installing jq..."
    if command -v apt-get &>/dev/null; then
        sudo apt-get install -y -qq jq
    elif command -v brew &>/dev/null; then
        brew install jq
    else
        echo "✗ Please install jq" >&2; exit 1
    fi
fi
echo "  ✓ jq"

CLAW_CMD=""
command -v openclaw &>/dev/null && CLAW_CMD="openclaw"
[[ -n "$CLAW_CMD" ]] && echo "  ✓ openclaw" || echo "  ⚠ openclaw not found (install later)"

# Key check for clone/existing
if [[ "$REPO_MODE" != "new" && ! -f "$KEY_FILE" ]]; then
    echo ""
    echo "✗ Key not found: $KEY_FILE"
    echo "  Copy from source: scp <host>:~/.secrets/bobnet-vault.key ~/.secrets/"
    echo "  Or specify: --key /path/to/key"
    exit 1
fi

echo ""

# Repository setup
case "$REPO_MODE" in
    new)
        echo "Creating new repository at $INSTALL_DIR..."
        mkdir -p "$INSTALL_DIR" && cd "$INSTALL_DIR"
        git init -q
        git-crypt init
        mkdir -p ~/.secrets && chmod 700 ~/.secrets
        git-crypt export-key "$KEY_FILE" && chmod 600 "$KEY_FILE"
        echo "  ✓ key: $KEY_FILE"
        mkdir -p agents workspace collective/{work,personal,patterns} config
        cat > .gitattributes << 'EOF'
agents/** filter=git-crypt diff=git-crypt
agents/**/* filter=git-crypt diff=git-crypt
EOF
        cat > .gitignore << 'EOF'
workspace/*/repos/
workspace/*/sandbox/
.DS_Store
*.swp
EOF
        git add . && git commit -q -m "Initial BobNet repository"
        echo "  ✓ repository created"
        ;;
    clone)
        echo "Cloning $REPO_URL..."
        mkdir -p "$(dirname "$INSTALL_DIR")"
        if ! git clone -q "$REPO_URL" "$INSTALL_DIR"; then
            echo "✗ Clone failed" >&2; exit 1
        fi
        cd "$INSTALL_DIR"
        if ! git-crypt unlock "$KEY_FILE"; then
            echo "✗ Unlock failed" >&2; exit 1
        fi
        echo "  ✓ cloned and unlocked"
        ;;
    existing)
        echo "Using existing repository at $INSTALL_DIR..."
        cd "$INSTALL_DIR"
        git pull -q || true
        git-crypt unlock "$KEY_FILE" 2>/dev/null || true
        echo "  ✓ updated"
        ;;
esac

# Install CLI
install_cli
echo "  ✓ CLI: ~/.local/bin/bobnet"

# Configure OpenClaw
if [[ -n "$CLAW_CMD" && "$REPO_MODE" != "new" ]]; then
    ~/.local/bin/bobnet install
fi

# Done
echo ""
echo "═══════════════════════════════════════════════════════════"
echo " Done!"
echo "═══════════════════════════════════════════════════════════"
echo "  Repository: $INSTALL_DIR"
echo "  Key:        $KEY_FILE"
echo "  CLI:        ~/.local/bin/bobnet (v$BOBNET_CLI_VERSION)"
[[ ":$PATH:" != *":$HOME/.local/bin:"* ]] && echo "" && echo "  Add to PATH: export PATH=\"\$HOME/.local/bin:\$PATH\""
echo ""
