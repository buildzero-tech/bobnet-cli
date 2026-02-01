#!/bin/bash
#######################################
# BobNet Installer
#######################################
#
# Usage:
#   curl -fsSL .../install.sh | bash                    # new repo
#   curl -fsSL .../install.sh | bash -s -- --clone URL  # clone existing
#   curl -fsSL .../install.sh | bash -s -- --key PATH   # specify key
#
set -euo pipefail

INSTALL_DIR="${BOBNET_DIR:-$HOME/.bobnet/ultima-thule}"
KEY_FILE="${BOBNET_KEY:-$HOME/.secrets/bobnet-vault.key}"
REPO_URL=""
REPO_MODE="new"
VERBOSE=false

# Parse args
while [[ $# -gt 0 ]]; do
    case "$1" in
        --clone) REPO_URL="$2"; REPO_MODE="clone"; shift 2 ;;
        --key) KEY_FILE="$2"; shift 2 ;;
        --dir) INSTALL_DIR="$2"; shift 2 ;;
        --verbose|-v) VERBOSE=true; shift ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

log() { [[ "$VERBOSE" == "true" ]] && echo "[DEBUG] $*" || true; }
log "INSTALL_DIR=$INSTALL_DIR"
log "KEY_FILE=$KEY_FILE"
log "REPO_URL=$REPO_URL"
log "REPO_MODE=$REPO_MODE"

echo "═══════════════════════════════════════════════════════════"
echo " BobNet Installer"
echo "═══════════════════════════════════════════════════════════"
echo ""

# Check if existing repo
[[ -d "$INSTALL_DIR/.git" ]] && REPO_MODE="existing"

#######################################
# Prerequisites
#######################################

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
command -v clawdbot &>/dev/null && CLAW_CMD="clawdbot"
command -v openclaw &>/dev/null && CLAW_CMD="openclaw"  # prefer openclaw
[[ -n "$CLAW_CMD" ]] && echo "  ✓ $CLAW_CMD" || echo "  ⚠ openclaw not found (install later)"

# Key check for clone/existing
if [[ "$REPO_MODE" != "new" && ! -f "$KEY_FILE" ]]; then
    echo ""
    echo "✗ Key not found: $KEY_FILE"
    echo "  Copy from source: scp <host>:~/.secrets/bobnet-vault.key ~/.secrets/"
    echo "  Or specify: --key /path/to/key"
    exit 1
fi

echo ""

#######################################
# Embedded scripts
#######################################

extract_scripts() {
    local dir="$1"
    mkdir -p "$dir/scripts/lib"
    
    cat > "$dir/scripts/lib/agents.sh" << 'AGENTS_SH'
#!/bin/bash
set -euo pipefail
BOBNET_ROOT="${BOBNET_ROOT:-$HOME/.bobnet/ultima-thule}"
AGENTS_SCHEMA="${AGENTS_SCHEMA:-$BOBNET_ROOT/config/agents-schema.v3.json}"
command -v jq &>/dev/null || { echo "jq required" >&2; exit 1; }
get_all_agents() { jq -r '.agents | keys[]' "$AGENTS_SCHEMA" 2>/dev/null || echo ""; }
get_agent_scope() { jq -r --arg a "$1" '.agents[$a].scope // "work"' "$AGENTS_SCHEMA" 2>/dev/null; }
get_agents_by_scope() { jq -r --arg s "$1" '.agents | to_entries[] | select(.value.scope == $s) | .key' "$AGENTS_SCHEMA" 2>/dev/null; }
get_workspace() { echo "$BOBNET_ROOT/workspace/$1"; }
get_agent_dir() { echo "$BOBNET_ROOT/agents/$1"; }
get_all_scopes() { jq -r '.scopes | keys[]' "$AGENTS_SCHEMA" 2>/dev/null || echo ""; }
agent_exists() { [[ -d "$(get_workspace "$1")" ]]; }
validate_agent() { agent_exists "$1" || { echo "Agent '$1' not found" >&2; return 1; }; }
print_agent_summary() {
    echo "BobNet Agents"; echo "============="
    for scope in $(get_all_scopes); do
        echo "[$scope]"
        for agent in $(get_agents_by_scope "$scope"); do
            local e="✓"; [[ -d "$(get_workspace "$agent")" ]] || e="✗"
            echo "  $agent $e"
        done
    done
}
print_agent_paths() {
    echo "Agent: $1"
    echo "  Scope:     $(get_agent_scope "$1")"
    echo "  Workspace: $(get_workspace "$1")"
    echo "  AgentDir:  $(get_agent_dir "$1")"
}
AGENTS_SH

    cat > "$dir/scripts/bobnet" << 'BOBNET_SH'
#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/agents.sh"

cmd_status() {
    print_agent_summary
    echo ""; echo "Repository: $BOBNET_ROOT"
    command -v git-crypt &>/dev/null && {
        cd "$BOBNET_ROOT"
        git-crypt status &>/dev/null && echo "Encryption: unlocked ✓" || echo "Encryption: locked"
    }
}
cmd_setup() {
    echo "Configuring OpenClaw..."
    local claw=""
    command -v clawdbot &>/dev/null && claw="clawdbot"
    command -v openclaw &>/dev/null && claw="openclaw"
    [[ -z "$claw" ]] && { echo "openclaw/clawdbot not found" >&2; exit 1; }
    
    # Build agents list JSON
    local list='['
    local first=true
    for agent in $(get_all_agents); do
        local id="$agent"; [[ "$agent" == "bob" ]] && id="main"
        $first || list+=','
        first=false
        list+="{\"id\":\"$id\",\"workspace\":\"$(get_workspace "$agent")\",\"agentDir\":\"$(get_agent_dir "$agent")\"}"
        echo "  ✓ agent: $id"
    done
    list+=']'
    
    # Build bindings list from schema
    local bindings=$(jq -c '[.bindings[] | {agentId, match: {channel, peer: {kind: "group", id: .groupId}}}]' "$AGENTS_SCHEMA" 2>/dev/null || echo '[]')
    local bind_count=$(echo "$bindings" | jq length)
    
    # Apply config
    $claw config set agents.defaults.workspace "$(get_workspace bob)"
    $claw config set agents.list "$list" --json
    [[ "$bind_count" -gt 0 ]] && $claw config set bindings "$bindings" --json && echo "  ✓ bindings: $bind_count"
    
    echo "Done ✓"
}
cmd_unlock() {
    local key="${1:-$HOME/.secrets/bobnet-vault.key}"
    [[ -f "$key" ]] || { echo "Key not found: $key" >&2; exit 1; }
    cd "$BOBNET_ROOT" && git-crypt unlock "$key" && echo "Unlocked ✓"
}
cmd_lock() { cd "$BOBNET_ROOT" && git-crypt lock && echo "Locked ✓"; }
cmd_help() {
    echo "Usage: bobnet <command>"
    echo "  status    Show agents and repo status"
    echo "  setup     Configure OpenClaw with agent paths"
    echo "  unlock    Unlock git-crypt"
    echo "  lock      Lock git-crypt"
}
case "${1:-help}" in
    status) cmd_status ;;
    setup) cmd_setup ;;
    unlock) shift; cmd_unlock "$@" ;;
    lock) cmd_lock ;;
    *) cmd_help ;;
esac
BOBNET_SH

    chmod +x "$dir/scripts/bobnet" "$dir/scripts/lib/agents.sh"
}

#######################################
# Install
#######################################

case "$REPO_MODE" in
    new)
        echo "Creating new repository at $INSTALL_DIR..."
        mkdir -p "$INSTALL_DIR" && cd "$INSTALL_DIR"
        git init -q
        git-crypt init
        mkdir -p ~/.secrets && chmod 700 ~/.secrets
        git-crypt export-key "$KEY_FILE" && chmod 600 "$KEY_FILE"
        echo "  ✓ key: $KEY_FILE"
        mkdir -p agents workspace collective/{work,personal,patterns} core config docs
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
        extract_scripts "$INSTALL_DIR"
        git add . && git commit -q -m "Initial BobNet repository"
        echo "  ✓ repository created"
        ;;
    clone)
        echo "Cloning $REPO_URL..."
        mkdir -p "$(dirname "$INSTALL_DIR")"
        if ! git clone -q "$REPO_URL" "$INSTALL_DIR"; then
            echo "✗ Clone failed. Check:" >&2
            echo "  - SSH key: ssh -T git@github.com" >&2
            echo "  - Or use HTTPS: --clone https://github.com/..." >&2
            exit 1
        fi
        cd "$INSTALL_DIR"
        if ! git-crypt unlock "$KEY_FILE"; then
            echo "✗ Unlock failed. Check key file: $KEY_FILE" >&2
            exit 1
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

# Always extract latest scripts
log "Extracting scripts to $INSTALL_DIR/scripts/"
extract_scripts "$INSTALL_DIR"
log "Scripts extracted"
log "bobnet script: $(head -5 "$INSTALL_DIR/scripts/bobnet" | tail -1)"

#######################################
# Install to PATH
#######################################

mkdir -p ~/.local/bin ~/.local/lib/bobnet
cp "$INSTALL_DIR/scripts/lib/agents.sh" ~/.local/lib/bobnet/

cat > ~/.local/bin/bobnet << 'WRAPPER'
#!/bin/bash
set -euo pipefail
if [[ -n "${BOBNET_ROOT:-}" ]]; then :
elif [[ -f "./config/agents-schema.v3.json" ]]; then BOBNET_ROOT="$(pwd)"
elif [[ -d "$HOME/.bobnet/ultima-thule" ]]; then BOBNET_ROOT="$HOME/.bobnet/ultima-thule"
else echo "BOBNET_ROOT not found" >&2; exit 1; fi
export BOBNET_ROOT
source "$HOME/.local/lib/bobnet/agents.sh"
WRAPPER
tail -n +6 "$INSTALL_DIR/scripts/bobnet" >> ~/.local/bin/bobnet
chmod +x ~/.local/bin/bobnet
echo "  ✓ installed: ~/.local/bin/bobnet"

#######################################
# Configure OpenClaw
#######################################

if [[ -n "$CLAW_CMD" && "$REPO_MODE" != "new" ]]; then
    log "Running: $INSTALL_DIR/scripts/bobnet setup"
    log "CLAW_CMD=$CLAW_CMD"
    log "Checking bobnet cmd_setup:"
    [[ "$VERBOSE" == "true" ]] && grep -A5 "cmd_setup()" "$INSTALL_DIR/scripts/bobnet" | head -10 || true
    ./scripts/bobnet setup
fi

#######################################
# Done
#######################################

echo ""
echo "═══════════════════════════════════════════════════════════"
echo " Done!"
echo "═══════════════════════════════════════════════════════════"
echo "  Repository: $INSTALL_DIR"
echo "  Key:        $KEY_FILE"
echo "  CLI:        ~/.local/bin/bobnet"
[[ ":$PATH:" != *":$HOME/.local/bin:"* ]] && echo "" && echo "  Add to PATH: export PATH=\"\$HOME/.local/bin:\$PATH\""
echo ""
