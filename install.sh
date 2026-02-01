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

BOBNET_CLI_VERSION="3.7.1"
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
AGENTS_SH

    # Main CLI
    cat > ~/.local/lib/bobnet/bobnet.sh << 'BOBNET_SH'
# BobNet CLI v3
BOBNET_CLI_VERSION=$(cat "$HOME/.local/lib/bobnet/version" 2>/dev/null || echo "unknown")

# Config directory
CONFIG_DIR="$HOME/.openclaw"
CONFIG_NAME="openclaw.json"
CLI_NAME="openclaw"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
error() { echo -e "${RED}error:${NC} $*" >&2; exit 1; }
warn() { echo -e "${YELLOW}warn:${NC} $*" >&2; }
success() { echo -e "${GREEN}✓${NC} $*"; }

cmd_status() {
    print_agent_summary
    echo ""; echo "Repository: $BOBNET_ROOT"
    echo "CLI: v$BOBNET_CLI_VERSION"
    command -v git-crypt &>/dev/null && {
        cd "$BOBNET_ROOT"
        git-crypt status &>/dev/null && echo "Encryption: unlocked ✓" || echo "Encryption: locked"
    }
}

cmd_install() {
    echo "Installing BobNet agents into $CLI_NAME..."
    local claw=""
    command -v openclaw &>/dev/null && claw="openclaw"
    [[ -z "$claw" ]] && error "$CLI_NAME not found"
    
    local config="$CONFIG_DIR/$CONFIG_NAME"
    [[ -f "$config" && ! -f "${config}.pre-bobnet" ]] && cp "$config" "${config}.pre-bobnet" && success "backed up config"
    
    local list='[' first=true
    for agent in $(get_all_agents); do
        local id="$agent"; [[ "$agent" == "bob" ]] && id="main"
        $first || list+=','; first=false
        list+="{\"id\":\"$id\",\"workspace\":\"$(get_workspace "$agent")\",\"agentDir\":\"$(get_agent_dir "$agent")\"}"
        success "agent: $id"
    done
    list+=']'
    
    local bindings=$(jq -c '[.bindings[] | {agentId, match: {channel, peer: {kind: "group", id: .groupId}}}]' "$AGENTS_SCHEMA" 2>/dev/null || echo '[]')
    local bind_count=$(echo "$bindings" | jq length)
    
    $claw config set agents.defaults.workspace "$(get_workspace bob)"
    $claw config set agents.list "$list" --json
    [[ "$bind_count" -gt 0 ]] && $claw config set bindings "$bindings" --json && success "bindings: $bind_count"
    
    echo ""; success "BobNet installed"
    echo "  Run '$claw gateway restart' to apply"
    echo ""
    cmd_validate
}

cmd_uninstall() {
    local force=false remove_cli=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force) force=true; shift ;;
            --cli) remove_cli=true; shift ;;
            -h|--help) 
                cat <<'EOF'
Usage: bobnet uninstall [--force] [--cli]

Uninstall BobNet from OpenClaw.

OPTIONS:
  --force    Skip confirmation prompts
  --cli      Also remove CLI (~/.local/bin/bobnet, ~/.local/lib/bobnet/)

You will be prompted for what to do with the repo:
  [M]ove   → Move to ~/<repo-name> (visible, preserved)
  [K]eep   → Keep in ~/.bobnet/ (hidden, preserved)  
  [D]elete → Delete entirely (destructive)
EOF
                return 0 ;;
            *) shift ;;
        esac
    done
    
    local claw=""; command -v openclaw &>/dev/null && claw="openclaw"
    [[ -z "$claw" ]] && error "$CLI_NAME not found"
    local config="$CONFIG_DIR/$CONFIG_NAME"
    
    [[ "$force" == "false" ]] && { echo "This will clear BobNet from $CLI_NAME config."; read -p "Continue? [y/N] " -n 1 -r; echo ""; [[ ! $REPLY =~ ^[Yy]$ ]] && return 0; }
    
    if [[ -f "${config}.pre-bobnet" ]]; then
        cp "${config}.pre-bobnet" "$config"; success "restored config backup"
    else
        $claw config set agents.list '[]' --json
        $claw config set agents.defaults.workspace "$HOME/.openclaw/workspace/"
        $claw config set bindings '[]' --json
        success "cleared config"
    fi
    
    # Lock the repo
    if command -v git-crypt &>/dev/null && [[ -d "$BOBNET_ROOT/.git" ]]; then
        (cd "$BOBNET_ROOT" && git-crypt lock 2>/dev/null) && success "locked repo"
    fi
    
    # Ask about repo
    local repo_action="keep"
    local repo_name=$(basename "$BOBNET_ROOT")
    if [[ -d "$BOBNET_ROOT" && "$force" == "false" ]]; then
        echo ""
        echo "What to do with the repo ($BOBNET_ROOT)?"
        echo "  [M]ove   → Move to ~/$repo_name"
        echo "  [K]eep   → Keep in ~/.bobnet/ (default)"
        echo "  [D]elete → Delete entirely"
        read -p "Choice [m/K/d]: " -n 1 -r; echo ""
        case "$REPLY" in
            [Mm]) repo_action="move" ;;
            [Dd]) repo_action="delete" ;;
            *) repo_action="keep" ;;
        esac
    fi
    
    case "$repo_action" in
        move)
            local dest="$HOME/$repo_name"
            if [[ -e "$dest" ]]; then
                warn "~/$repo_name already exists, keeping in ~/.bobnet/"
            else
                mv "$BOBNET_ROOT" "$dest"
                success "moved repo to ~/$repo_name"
                # Clean up .bobnet if empty
                rmdir ~/.bobnet 2>/dev/null && success "removed empty ~/.bobnet/"
            fi
            ;;
        delete)
            rm -rf "$BOBNET_ROOT"
            success "deleted $BOBNET_ROOT"
            rmdir ~/.bobnet 2>/dev/null && success "removed empty ~/.bobnet/"
            ;;
        keep)
            echo "  Repo kept at $BOBNET_ROOT"
            ;;
    esac
    
    [[ "$remove_cli" == "true" ]] && rm -f ~/.local/bin/bobnet && rm -rf ~/.local/lib/bobnet && success "removed CLI"
    success "BobNet uninstalled"
    
    # Validate if repo still exists and cli not removed
    if [[ -d "$BOBNET_ROOT" && "$remove_cli" == "false" ]]; then
        echo ""
        cmd_validate --uninstall
    fi
}

cmd_eject() {
    local force=false
    while [[ $# -gt 0 ]]; do
        case "$1" in --force) force=true; shift ;; -h|--help) echo "Usage: bobnet eject [--force]"; return 0 ;; *) shift ;; esac
    done
    
    local claw=""; command -v openclaw &>/dev/null && claw="openclaw"
    [[ -z "$claw" ]] && error "$CLI_NAME not found"
    
    echo "=== BobNet Eject ==="
    echo "Agents to migrate:"
    for agent in $(get_all_agents); do
        local id="$agent"; [[ "$agent" == "bob" ]] && id="main"
        echo "  • $id → $CONFIG_DIR/agents/$id"
    done
    echo ""
    
    [[ "$force" == "false" ]] && { read -p "Continue? [y/N] " -n 1 -r; echo ""; [[ ! $REPLY =~ ^[Yy]$ ]] && return 0; }
    
    mkdir -p "$CONFIG_DIR/agents" "$CONFIG_DIR/workspace"
    local list='[' first=true
    for agent in $(get_all_agents); do
        local id="$agent"; [[ "$agent" == "bob" ]] && id="main"
        local src_a=$(get_agent_dir "$agent") src_w=$(get_workspace "$agent")
        local dst_a="$CONFIG_DIR/agents/$id" dst_w="$CONFIG_DIR/workspace/$id"
        [[ -d "$src_a" ]] && cp -r "$src_a" "$dst_a" && success "agents/$id"
        [[ -d "$src_w" ]] && cp -r "$src_w" "$dst_w" && success "workspace/$id"
        $first || list+=','; first=false
        list+="{\"id\":\"$id\",\"workspace\":\"$dst_w\",\"agentDir\":\"$dst_a\"}"
    done
    list+=']'
    
    $claw config set agents.defaults.workspace "$CONFIG_DIR/workspace/main"
    $claw config set agents.list "$list" --json
    $claw config set bindings '[]' --json
    success "Eject complete — run '$claw gateway restart'"
}

cmd_agent() {
    local subcmd="${1:-list}"; shift 2>/dev/null || true
    local claw=""; command -v openclaw &>/dev/null && claw="openclaw"
    
    case "$subcmd" in
        list|ls)
            echo "=== BobNet Agents ==="
            for agent in $(get_all_agents); do
                local id="$agent"; [[ "$agent" == "bob" ]] && id="main"
                local ws=$(get_workspace "$agent")
                local ad=$(get_agent_dir "$agent")
                local ws_ok="✓"; [[ -d "$ws" ]] || ws_ok="✗"
                local ad_ok="✓"; [[ -d "$ad" ]] || ad_ok="✗"
                echo "  $id  workspace:$ws_ok  agents:$ad_ok"
            done
            ;;
        add)
            local name="${1:-}"
            [[ -z "$name" ]] && error "Usage: bobnet agent add <name>"
            
            # Check agent in schema
            local schema_name="$name"; [[ "$name" == "main" ]] && schema_name="bob"
            if ! jq -e --arg a "$schema_name" '.agents[$a]' "$AGENTS_SCHEMA" >/dev/null 2>&1; then
                error "Agent '$name' not in schema. Add to agents-schema.v3.json first."
            fi
            
            local ws=$(get_workspace "$schema_name")
            local ad=$(get_agent_dir "$schema_name")
            
            # Create directories
            if [[ ! -d "$ws" ]]; then
                mkdir -p "$ws"
                success "Created $ws"
            else
                echo "  Workspace exists: $ws"
            fi
            
            if [[ ! -d "$ad" ]]; then
                mkdir -p "$ad"
                success "Created $ad"
            else
                echo "  Agent dir exists: $ad"
            fi
            
            # Call openclaw agents add (if not already registered)
            if [[ -n "$claw" ]]; then
                if $claw agents list --json 2>/dev/null | jq -e --arg n "$name" '.[] | select(.id == $n)' >/dev/null 2>&1; then
                    echo "  Agent already in OpenClaw config"
                else
                    $claw agents add "$name" --workspace "$ws" --agent-dir "$ad" --non-interactive
                    success "Added to OpenClaw"
                fi
            else
                warn "OpenClaw not found, skipping config update"
                echo "  Run 'bobnet install' to sync config"
            fi
            
            # Symlink AGENTS.md to shared core
            if [[ -f "$ws/AGENTS.md" && ! -L "$ws/AGENTS.md" ]]; then
                rm "$ws/AGENTS.md"
                ln -s "../../core/AGENTS.md" "$ws/AGENTS.md"
                success "Symlinked AGENTS.md → core/AGENTS.md"
            fi
            ;;
        -h|--help|help)
            cat <<'EOF'
Usage: bobnet agent <command>

Commands:
  list              List agents and directory status
  add <name>        Add agent (create dirs, register with OpenClaw)

Examples:
  bobnet agent list
  bobnet agent add family
EOF
            ;;
        *) error "Unknown agent command: $subcmd" ;;
    esac
}

cmd_scope() {
    local subcmd="${1:-list}"; shift 2>/dev/null || true
    case "$subcmd" in
        list|ls)
            echo "=== BobNet Scopes ==="
            for scope in $(get_all_scopes); do
                local label=$(jq -r --arg s "$scope" '.scopes[$s].label // $s' "$AGENTS_SCHEMA")
                echo ""; echo "[$label] ($scope)"
                for agent in $(get_agents_by_scope "$scope"); do
                    local id="$agent"; [[ "$agent" == "bob" ]] && id="main"
                    local mark="✓"; [[ -d "$(get_workspace "$agent")" ]] || mark="✗"
                    echo "  $mark $id"
                done
            done ;;
        -h|--help|help) echo "Usage: bobnet scope [list|<scope-name>]" ;;
        *)
            if jq -e --arg s "$subcmd" '.scopes[$s]' "$AGENTS_SCHEMA" >/dev/null 2>&1; then
                echo "=== Scope: $subcmd ==="; for agent in $(get_agents_by_scope "$subcmd"); do local id="$agent"; [[ "$agent" == "bob" ]] && id="main"; echo "  $id"; done
            else error "Unknown scope: $subcmd"; fi ;;
    esac
}

cmd_binding() {
    local subcmd="${1:-list}"; shift 2>/dev/null || true
    local claw=""; command -v openclaw &>/dev/null && claw="openclaw"
    case "$subcmd" in
        list|ls)
            echo "=== Agent Bindings ==="; echo ""; echo "Schema:"
            jq -r '.bindings[] | "  \(.agentId) → \(.channel) group:\(.groupId[:16])..."' "$AGENTS_SCHEMA" 2>/dev/null || echo "  (none)"
            echo ""; echo "Config:"
            [[ -n "$claw" ]] && $claw config get bindings 2>/dev/null | jq -r '.[] | "  \(.agentId) → \(.match.channel // "any") \(.match.peer.kind):\(.match.peer.id[:16])..."' 2>/dev/null || echo "  (none)" ;;
        add)
            local agent_id="${1:-}" group_name="${2:-$1}"
            [[ -z "$agent_id" ]] && error "Usage: bobnet binding add <agent> [group-name]"
            local sessions="$CONFIG_DIR/agents/main/sessions/sessions.json"
            [[ -f "$sessions" ]] || error "Sessions not found: $sessions"
            local group_key=$(jq -r --arg g "$group_name" 'to_entries[] | select(.value.label != null) | select(.value.label | ascii_downcase | contains($g | ascii_downcase)) | .key' "$sessions" 2>/dev/null | head -1)
            [[ -z "$group_key" ]] && { echo "Group '$group_name' not found. Available:"; jq -r 'to_entries[] | select(.value.label != null) | "  - \(.value.label)"' "$sessions" | sort -u; return 1; }
            local group_id=$(jq -r --arg k "$group_key" '.[$k].deliveryContext.to // empty' "$sessions" | sed 's/^group://')
            local group_label=$(jq -r --arg k "$group_key" '.[$k].label' "$sessions")
            echo "Found: $group_label ($group_id)"
            jq --argjson b "{\"agentId\":\"$agent_id\",\"channel\":\"signal\",\"groupId\":\"$group_id\"}" '.bindings += [$b]' "$AGENTS_SCHEMA" > "${AGENTS_SCHEMA}.tmp" && mv "${AGENTS_SCHEMA}.tmp" "$AGENTS_SCHEMA"
            success "added to schema"
            [[ -n "$claw" ]] && { local bindings=$(jq -c '[.bindings[] | {agentId, match: {channel, peer: {kind: "group", id: .groupId}}}]' "$AGENTS_SCHEMA"); $claw config set bindings "$bindings" --json; success "applied to config"; } ;;
        remove|rm)
            local agent_id="${1:-}"; [[ -z "$agent_id" ]] && error "Usage: bobnet binding remove <agent>"
            jq --arg a "$agent_id" '.bindings = [.bindings[] | select(.agentId != $a)]' "$AGENTS_SCHEMA" > "${AGENTS_SCHEMA}.tmp" && mv "${AGENTS_SCHEMA}.tmp" "$AGENTS_SCHEMA"
            success "removed from schema"
            [[ -n "$claw" ]] && { local bindings=$(jq -c '[.bindings[] | {agentId, match: {channel, peer: {kind: "group", id: .groupId}}}]' "$AGENTS_SCHEMA"); $claw config set bindings "$bindings" --json; success "applied to config"; } ;;
        sync)
            [[ -z "$claw" ]] && error "$CLI_NAME not found"
            local bindings=$(jq -c '[.bindings[] | {agentId, match: {channel, peer: {kind: "group", id: .groupId}}}]' "$AGENTS_SCHEMA")
            $claw config set bindings "$bindings" --json; success "synced $(echo "$bindings" | jq length) bindings" ;;
        -h|--help|help) echo "Usage: bobnet binding [list|add|remove|sync]" ;;
        *) error "Unknown: $subcmd" ;;
    esac
}

cmd_signal() {
    local subcmd="${1:-help}"; shift 2>/dev/null || true
    local backup_dir="$BOBNET_ROOT/backups/signal" data_dir="$HOME/.local/share/signal-cli/data"
    signal_check_age() { command -v age &>/dev/null || error "age required. Install: sudo apt install age"; }
    signal_get_account() { local a=""; while [[ $# -gt 0 ]]; do case "$1" in --account|-a) a="$2"; shift 2 ;; *) shift ;; esac; done; [[ -z "$a" && -f "$data_dir/accounts.json" ]] && a=$(jq -r '.accounts[0].number // empty' "$data_dir/accounts.json"); [[ -z "$a" ]] && error "No account. Use --account <num>"; echo "$a"; }
    signal_get_path() { jq -r --arg n "$1" '.accounts[] | select(.number == $n) | .path' "$data_dir/accounts.json" 2>/dev/null; }
    case "$subcmd" in
        backup)
            signal_check_age; local acct=$(signal_get_account "$@") path=$(signal_get_path "$acct")
            [[ -z "$path" ]] && error "No data path for $acct"
            local safe="${acct//+/}" ts=$(date +%Y-%m-%d_%H%M%S) out="$backup_dir/${safe}_${ts}.tar.age"
            mkdir -p "$backup_dir"; echo "Backing up $acct..."
            local items="$path accounts.json"; [[ -d "$data_dir/${path}.d" ]] && items="$items ${path}.d"
            tar -C "$data_dir" -czf - $items | age -p -o "$out" && ln -sf "$(basename "$out")" "$backup_dir/${safe}_latest.tar.age" && success "saved: $out" ;;
        restore)
            signal_check_age; local acct="" file="" force=false
            while [[ $# -gt 0 ]]; do case "$1" in --account|-a) acct="$2"; shift 2 ;; --file|-f) file="$2"; shift 2 ;; --force) force=true; shift ;; *) shift ;; esac; done
            [[ -z "$file" ]] && { [[ -n "$acct" ]] && file="$backup_dir/${acct//+/}_latest.tar.age" || file=$(ls -t "$backup_dir"/*_latest.tar.age 2>/dev/null | head -1); }
            [[ -z "$file" || ! -f "$file" ]] && error "No backup found"
            [[ -L "$file" ]] && file="$backup_dir/$(readlink "$file")"
            echo "Restoring from $file..."
            [[ "$force" == "false" ]] && { read -p "Overwrite signal-cli data? [y/N] " -n 1 -r; echo ""; [[ ! $REPLY =~ ^[Yy]$ ]] && return 0; }
            mkdir -p "$data_dir" && age -d "$file" | tar -C "$data_dir" -xzf - && success "restored" ;;
        list|ls)
            echo "=== Signal Backups ($backup_dir) ==="; [[ ! -d "$backup_dir" ]] && { echo "(none)"; return 0; }
            ls -1t "$backup_dir"/*.tar.age 2>/dev/null | head -10 | while read -r f; do echo "  $(basename "$f") ($(du -h "$f" | cut -f1))"; done ;;
        -h|--help|help|"") echo "Usage: bobnet signal [backup|restore|list] [--account <num>]" ;;
        *) error "Unknown: $subcmd" ;;
    esac
}

cmd_unlock() {
    local key="${1:-$HOME/.secrets/bobnet-vault.key}"
    [[ -f "$key" ]] || error "Key not found: $key"
    cd "$BOBNET_ROOT" && git-crypt unlock "$key" && echo "Unlocked ✓"
}

cmd_lock() { cd "$BOBNET_ROOT" && git-crypt lock && echo "Locked ✓"; }

cmd_update() {
    echo "Checking for updates..."
    local current="$BOBNET_CLI_VERSION"
    local remote=$(curl -fsSL "https://raw.githubusercontent.com/buildzero-tech/bobnet-cli/main/install.sh" 2>/dev/null | grep '^BOBNET_CLI_VERSION="' | cut -d'"' -f2)
    [[ -z "$remote" ]] && error "Could not fetch remote version"
    
    if [[ "$current" == "$remote" ]]; then
        echo "Already at v$current"
    else
        echo "Updating v$current → v$remote..."
        curl -fsSL "https://raw.githubusercontent.com/buildzero-tech/bobnet-cli/main/install.sh" | bash -s -- --update
    fi
}

cmd_validate() {
    local failures=0
    local uninstall_mode=false
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --uninstall) uninstall_mode=true; shift ;;
            -h|--help) echo "Usage: bobnet validate [--uninstall]"; return 0 ;;
            *) shift ;;
        esac
    done
    
    local claw=""; command -v openclaw &>/dev/null && claw="openclaw"
    
    if [[ "$uninstall_mode" == "true" ]]; then
        echo "=== BobNet Validate (uninstall) ==="
    else
        echo "=== BobNet Validate ==="
    fi
    echo ""
    
    if [[ "$uninstall_mode" == "true" ]]; then
        # UNINSTALL MODE: verify config is clean
        if [[ -n "$claw" ]]; then
            # 1. No BobNet agents in config
            local config_agents=$($claw config get agents.list 2>/dev/null | jq -r '.[].id' | sort)
            local schema_agents=$(get_all_agents | while read a; do [[ "$a" == "bob" ]] && echo "main" || echo "$a"; done | sort)
            local remaining=""
            for agent in $schema_agents; do
                echo "$config_agents" | grep -q "^${agent}$" && remaining="$remaining $agent"
            done
            if [[ -z "$remaining" ]]; then
                success "No BobNet agents in config"
            else
                echo -e "${RED}✗${NC} BobNet agents still in config:$remaining"
                echo "    bobnet uninstall"
                ((failures++))
            fi
            
            # 2. Bindings empty
            local config_count=$($claw config get bindings 2>/dev/null | jq 'length' || echo 0)
            if [[ "$config_count" == "0" ]]; then
                success "Bindings empty"
            else
                echo -e "${RED}✗${NC} Bindings still configured ($config_count)"
                echo "    bobnet uninstall"
                ((failures++))
            fi
            
            # 3. Default workspace reset
            local ws_default=$($claw config get agents.defaults.workspace 2>/dev/null | tr -d '"')
            if [[ "$ws_default" == "$HOME/.openclaw/workspace/" || "$ws_default" == "" ]]; then
                success "Default workspace reset"
            else
                echo -e "${RED}✗${NC} Default workspace still set to: $ws_default"
                echo "    Expected: ~/.openclaw/workspace/"
                ((failures++))
            fi
            
            # 4. OpenClaw reachable
            if $claw gateway call config.get &>/dev/null; then
                success "OpenClaw reachable"
            else
                echo -e "${RED}✗${NC} OpenClaw gateway not running"
                echo "    openclaw gateway start"
                ((failures++))
            fi
        else
            success "OpenClaw not found (config checks skipped)"
        fi
        
        # 5. git-crypt locked (uninstall mode)
        if command -v git-crypt &>/dev/null && [[ -d "$BOBNET_ROOT/.git" ]]; then
            if (cd "$BOBNET_ROOT" && git-crypt status &>/dev/null); then
                echo -e "${RED}✗${NC} Repo is still unlocked"
                echo "    bobnet lock"
                ((failures++))
            else
                success "Repo locked"
            fi
        fi
    else
        # NORMAL MODE: verify install is correct
        if [[ -n "$claw" ]]; then
            local config_agents=$($claw config get agents.list 2>/dev/null | jq -r '.[].id' | sort)
            local schema_agents=$(get_all_agents | while read a; do [[ "$a" == "bob" ]] && echo "main" || echo "$a"; done | sort)
            local missing=""
            for agent in $schema_agents; do
                echo "$config_agents" | grep -q "^${agent}$" || missing="$missing $agent"
            done
            if [[ -z "$missing" ]]; then
                success "Schema agents in config ($(echo "$schema_agents" | wc -w | tr -d ' '))"
            else
                echo -e "${RED}✗${NC} Schema agents missing from config:$missing"
                echo "    bobnet install"
                ((failures++))
            fi
            
            # 2. No orphan agents in config
            local orphans=""
            for agent in $config_agents; do
                echo "$schema_agents" | grep -q "^${agent}$" || orphans="$orphans $agent"
            done
            if [[ -z "$orphans" ]]; then
                success "No orphan agents in config"
            else
                echo -e "${RED}✗${NC} Orphan agents in config:$orphans"
                echo "    bobnet install"
                ((failures++))
            fi
        else
            success "OpenClaw not found (config checks skipped)"
        fi
        
        # 3 & 4. Agent directories exist (workspace + agents)
        local agents_incomplete=""
        for agent in $(get_all_agents); do
            local ws=$(get_workspace "$agent")
            local ad=$(get_agent_dir "$agent")
            if [[ ! -d "$ws" || ! -d "$ad" ]]; then
                agents_incomplete="$agents_incomplete $agent"
            fi
        done
        if [[ -z "$agents_incomplete" ]]; then
            success "Agent directories exist ($(get_all_agents | wc -w | tr -d ' '))"
        else
            echo -e "${RED}✗${NC} Missing directories for:$agents_incomplete"
            for agent in $agents_incomplete; do
                local id="$agent"; [[ "$agent" == "bob" ]] && id="main"
                echo ""
                read -p "    Add agent '$id'? [Y/n] " -n 1 -r; echo ""
                if [[ ! $REPLY =~ ^[Nn]$ ]]; then
                    cmd_agent add "$id"
                else
                    echo "    Skipped. Run manually: bobnet agent add $id"
                    ((failures++))
                fi
            done
        fi
        
        # 5. Binding agents valid
        local binding_agents=$(jq -r '.bindings[].agentId' "$AGENTS_SCHEMA" 2>/dev/null)
        local schema_agents_raw=$(get_all_agents)
        local invalid_bindings=""
        for agent in $binding_agents; do
            local found=false
            for sa in $schema_agents_raw; do
                [[ "$sa" == "$agent" ]] && found=true && break
            done
            [[ "$found" == "false" ]] && invalid_bindings="$invalid_bindings $agent"
        done
        if [[ -z "$invalid_bindings" ]]; then
            local bc=$(echo "$binding_agents" | wc -w | tr -d ' ')
            success "Bindings valid ($bc)"
        else
            echo -e "${RED}✗${NC} Bindings reference unknown agents:$invalid_bindings"
            for agent in $invalid_bindings; do
                echo "    bobnet binding remove $agent"
            done
            ((failures++))
        fi
        
        # 6. Bindings in sync
        if [[ -n "$claw" ]]; then
            local schema_count=$(jq '.bindings | length' "$AGENTS_SCHEMA" 2>/dev/null || echo 0)
            local config_count=$($claw config get bindings 2>/dev/null | jq 'length' || echo 0)
            if [[ "$schema_count" == "$config_count" ]]; then
                success "Bindings in sync ($schema_count)"
            else
                echo -e "${RED}✗${NC} Bindings out of sync (schema: $schema_count, config: $config_count)"
                echo "    bobnet binding sync"
                ((failures++))
            fi
        fi
        # 7. git-crypt unlocked (install mode only)
        if command -v git-crypt &>/dev/null && [[ -d "$BOBNET_ROOT/.git" ]]; then
            if (cd "$BOBNET_ROOT" && git-crypt status &>/dev/null); then
                success "git-crypt unlocked"
            else
                echo -e "${RED}✗${NC} Repo is locked"
                echo "    bobnet unlock"
                ((failures++))
            fi
        else
            success "git-crypt not applicable"
        fi
        
        # 8. OpenClaw reachable (install mode only)
        if [[ -n "$claw" ]]; then
            if $claw gateway call config.get &>/dev/null; then
                success "OpenClaw reachable"
            else
                echo -e "${RED}✗${NC} OpenClaw gateway not running"
                echo "    openclaw gateway start"
                ((failures++))
            fi
        fi
    fi
    
    echo ""
    if [[ $failures -eq 0 ]]; then
        success "All checks passed"
        return 0
    else
        echo -e "${RED}$failures check(s) failed${NC}"
        return 1
    fi
}

cmd_help() {
    cat <<EOF
BobNet CLI v$BOBNET_CLI_VERSION

USAGE:
  bobnet <command> [options]

COMMANDS:
  status              Show agents and repo status
  install             Configure OpenClaw with BobNet agents
  uninstall           Remove BobNet config from OpenClaw
  eject               Migrate agents to standard OpenClaw structure
  validate            Validate BobNet configuration
  agent [cmd]         Manage agents (list, add)
  scope [cmd]         List scopes and agents
  binding [cmd]       Manage agent bindings
  signal [cmd]        Signal backup/restore
  unlock [key]        Unlock git-crypt
  lock                Lock git-crypt
  update              Update CLI to latest version

Run 'bobnet <command> --help' for details.
EOF
}

bobnet_main() {
    case "${1:-help}" in
        status) cmd_status ;;
        install|setup) shift; cmd_install "$@" ;;
        uninstall) shift; cmd_uninstall "$@" ;;
        eject) shift; cmd_eject "$@" ;;
        validate) shift; cmd_validate "$@" ;;
        agent) shift; cmd_agent "$@" ;;
        scope) shift; cmd_scope "$@" ;;
        binding) shift; cmd_binding "$@" ;;
        signal) shift; cmd_signal "$@" ;;
        unlock) shift; cmd_unlock "$@" ;;
        lock) cmd_lock ;;
        update) cmd_update ;;
        help|--help|-h) cmd_help ;;
        --version) echo "bobnet v$BOBNET_CLI_VERSION" ;;
        *) error "Unknown command: $1" ;;
    esac
}
BOBNET_SH

    # Wrapper script
    cat > ~/.local/bin/bobnet << 'WRAPPER'
#!/bin/bash
set -euo pipefail

# Find BOBNET_ROOT (may not exist)
if [[ -n "${BOBNET_ROOT:-}" ]]; then :
elif [[ -f "./config/agents-schema.v3.json" ]]; then BOBNET_ROOT="$(pwd)"
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
        curl -fsSL "https://raw.githubusercontent.com/buildzero-tech/bobnet-cli/main/install.sh" | bash -s -- --update
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
                        [[ ! " ${repos[*]} " =~ " $org/ultima-thule " ]] && repos+=("$org/ultima-thule")
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
esac

# All other commands require BOBNET_ROOT
if [[ -z "$BOBNET_ROOT" ]]; then
    echo "BOBNET_ROOT not found" >&2
    echo "Run: bobnet help" >&2
    exit 1
fi

export BOBNET_ROOT
export AGENTS_SCHEMA="$BOBNET_ROOT/config/agents-schema.v3.json"
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
