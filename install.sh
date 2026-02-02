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

BOBNET_CLI_VERSION="4.0.10"
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
# Schema location (try new name, fall back to old)
if [[ -f "$BOBNET_ROOT/config/agents-schema.json" ]]; then
    AGENTS_SCHEMA="${AGENTS_SCHEMA:-$BOBNET_ROOT/config/agents-schema.json}"
elif [[ -f "$BOBNET_ROOT/config/agents-schema.v3.json" ]]; then
    AGENTS_SCHEMA="${AGENTS_SCHEMA:-$BOBNET_ROOT/config/agents-schema.v3.json}"
else
    AGENTS_SCHEMA="${AGENTS_SCHEMA:-$BOBNET_ROOT/config/agents-schema.json}"
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
    [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { echo "Usage: bobnet status"; echo ""; echo "Show agents, repo status, and encryption state."; return 0; }
    print_agent_summary
    echo ""; echo "Repository: $BOBNET_ROOT"
    echo "CLI: v$BOBNET_CLI_VERSION"
    command -v git-crypt &>/dev/null && {
        cd "$BOBNET_ROOT"
        git-crypt status &>/dev/null && echo "Encryption: unlocked ✓" || echo "Encryption: locked"
    }
}

cmd_install() {
    [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && {
        cat <<'EOF'
Usage: bobnet install

Configure OpenClaw with BobNet agents, bindings, and channels from schema.

This will:
  • Backup existing config (if not already backed up)
  • Add all agents from schema to OpenClaw
  • Apply bindings from schema
  • Apply channel configs from schema
  • Run validation

Run 'openclaw gateway restart' after to apply changes.
EOF
        return 0
    }
    echo "Installing BobNet agents into $CLI_NAME..."
    local claw=""
    command -v openclaw &>/dev/null && claw="openclaw"
    [[ -z "$claw" ]] && error "$CLI_NAME not found"
    
    local config="$CONFIG_DIR/$CONFIG_NAME"
    [[ -f "$config" && ! -f "${config}.pre-bobnet" ]] && cp "$config" "${config}.pre-bobnet" && success "backed up config"
    
    # Build agents list - all agents get BobNet paths
    local list='[' first=true
    
    for agent in $(get_all_agents); do
        local is_default=$(jq -r --arg a "$agent" '.agents[$a].default // false' "$AGENTS_SCHEMA")
        $first || list+=','
        first=false
        list+="{\"id\":\"$agent\",\"workspace\":\"$(get_workspace "$agent")\",\"agentDir\":\"$(get_agent_dir "$agent")\""
        [[ "$is_default" == "true" ]] && list+=",\"default\":true"
        list+="}"
        success "agent: $agent"
    done
    list+=']'
    
    local bindings=$(jq -c '[.bindings[] | {agentId, match: {channel, peer: {kind: "group", id: .groupId}}}]' "$AGENTS_SCHEMA" 2>/dev/null || echo '[]')
    local bind_count=$(echo "$bindings" | jq length)
    
    $claw config set agents.defaults.workspace "$(get_workspace bob)"
    $claw config set agents.list "$list" --json
    [[ "$bind_count" -gt 0 ]] && $claw config set bindings "$bindings" --json && success "bindings: $bind_count"
    
    # Apply channel configs from schema
    for channel in $(jq -r '.channels // {} | keys[]' "$AGENTS_SCHEMA" 2>/dev/null); do
        local channel_config=$(jq -c ".channels.$channel" "$AGENTS_SCHEMA")
        $claw config set "channels.$channel" "$channel_config" --json 2>/dev/null && success "channel: $channel"
    done
    
    # Migrate main agent files from OpenClaw defaults to BobNet structure
    local oc_main_ws="$CONFIG_DIR/workspace"
    local oc_main_ad="$CONFIG_DIR/agents/main"
    local bn_main_ws=$(get_workspace main)
    local bn_main_ad=$(get_agent_dir main)
    
    # Migrate workspace
    if [[ -d "$oc_main_ws" && ! -d "$bn_main_ws" ]]; then
        echo ""
        echo "Migrating main agent to BobNet structure..."
        mkdir -p "$(dirname "$bn_main_ws")"
        mv "$oc_main_ws" "$bn_main_ws" && success "workspace: $oc_main_ws → $bn_main_ws"
        # Remove nested .git if present (OpenClaw sometimes creates one)
        if [[ -d "$bn_main_ws/.git" ]]; then
            rm -rf "$bn_main_ws/.git"
            success "removed nested .git from workspace/main"
        fi
    fi
    
    # Migrate agent dir
    if [[ -d "$oc_main_ad" && ! -d "$bn_main_ad" ]]; then
        mkdir -p "$(dirname "$bn_main_ad")"
        mv "$oc_main_ad" "$bn_main_ad" && success "agentDir: $oc_main_ad → $bn_main_ad"
    fi
    
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
    
    [[ "$force" == "false" ]] && { echo "This will clear BobNet from $CLI_NAME config."; read -p "Continue? [y/N]  " -r; [[ ! $REPLY =~ ^[Yy]$ ]] && return 0; }
    
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
        read -p "Choice [m/K/d]:  " -r
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
                # cd out if we're inside the repo being moved
                [[ "$PWD" == "$BOBNET_ROOT"* ]] && cd ~
                mv "$BOBNET_ROOT" "$dest"
                success "moved repo to ~/$repo_name"
                # Clean up .bobnet if empty
                rmdir ~/.bobnet 2>/dev/null && success "removed empty ~/.bobnet/"
            fi
            ;;
        delete)
            # cd out if we're inside the repo being deleted
            [[ "$PWD" == "$BOBNET_ROOT"* ]] && cd ~
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
    echo "Agents to migrate to OpenClaw paths:"
    for agent in $(get_all_agents); do
        if [[ "$agent" == "main" ]]; then
            echo "  • main → $CONFIG_DIR/workspace (default)"
        else
            echo "  • $agent → $CONFIG_DIR/workspace/$agent"
        fi
    done
    echo ""
    
    [[ "$force" == "false" ]] && { read -p "Continue? [y/N]  " -r; [[ ! $REPLY =~ ^[Yy]$ ]] && return 0; }
    
    mkdir -p "$CONFIG_DIR/agents" "$CONFIG_DIR/workspace"
    local list='[' first=true
    
    for agent in $(get_all_agents); do
        local src_a=$(get_agent_dir "$agent") src_w=$(get_workspace "$agent")
        local dst_a dst_w
        
        if [[ "$agent" == "main" ]]; then
            # Main goes to OpenClaw defaults (no subfolder)
            dst_a="$CONFIG_DIR/agents/main"
            dst_w="$CONFIG_DIR/workspace"
        else
            dst_a="$CONFIG_DIR/agents/$agent"
            dst_w="$CONFIG_DIR/workspace/$agent"
        fi
        
        [[ -d "$src_a" ]] && cp -r "$src_a" "$dst_a" && success "agents/$agent"
        [[ -d "$src_w" ]] && cp -r "$src_w" "$dst_w" && success "workspace/$agent"
        $first || list+=','
        first=false
        list+="{\"id\":\"$agent\",\"workspace\":\"$dst_w\",\"agentDir\":\"$dst_a\"}"
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
                local id="$agent"
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
            local schema_name="$name"
            if ! jq -e --arg a "$schema_name" '.agents[$a]' "$AGENTS_SCHEMA" >/dev/null 2>&1; then
                error "Agent '$name' not in schema. Add to agents-schema.json first."
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
                
                # Clean up nested .git directories (BobNet uses one repo, not per-agent repos)
                [[ -d "$ws/.git" ]] && rm -rf "$ws/.git" && success "Removed nested .git from workspace"
                [[ -d "$ad/.git" ]] && rm -rf "$ad/.git" && success "Removed nested .git from agent dir"
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
        default)
            local name="${1:-}"
            [[ -z "$name" ]] && error "Usage: bobnet agent default <name>"
            
            # Normalize name
            local schema_name="$name"
            
            # Check agent exists in schema
            if ! jq -e --arg a "$schema_name" '.agents[$a]' "$AGENTS_SCHEMA" >/dev/null 2>&1; then
                error "Agent '$name' not in schema"
            fi
            
            # Update schema: clear all defaults, set this one
            jq --arg a "$schema_name" '
                .agents |= with_entries(
                    if .key == $a then .value.default = true
                    else .value |= del(.default)
                    end
                )
            ' "$AGENTS_SCHEMA" > "${AGENTS_SCHEMA}.tmp" && mv "${AGENTS_SCHEMA}.tmp" "$AGENTS_SCHEMA"
            success "schema: $name is now default"
            
            # Apply to live config
            if [[ -n "$claw" ]]; then
                # Get current list, update default flags
                local list=$($claw config get agents.list 2>/dev/null)
                local new_list=$(echo "$list" | jq --arg id "$name" '
                    map(if .id == $id then .default = true else del(.default) end)
                ')
                $claw config set agents.list "$new_list" --json
                success "config: $name is now default"
                echo "  Run 'openclaw gateway restart' to apply"
            fi
            ;;
        -h|--help|help)
            cat <<'EOF'
Usage: bobnet agent <command>

Commands:
  list              List agents and directory status
  add <name>        Add agent (create dirs, register with OpenClaw)
  default <name>    Set default agent for unbound messages

Examples:
  bobnet agent list
  bobnet agent default bob
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
                    local id="$agent"
                    local mark="✓"; [[ -d "$(get_workspace "$agent")" ]] || mark="✗"
                    echo "  $mark $id"
                done
            done ;;
        -h|--help|help) echo "Usage: bobnet scope [list|<scope-name>]" ;;
        *)
            if jq -e --arg s "$subcmd" '.scopes[$s]' "$AGENTS_SCHEMA" >/dev/null 2>&1; then
                echo "=== Scope: $subcmd ==="; for agent in $(get_agents_by_scope "$subcmd"); do local id="$agent"; echo "  $id"; done
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
            [[ "$force" == "false" ]] && { read -p "Overwrite signal-cli data? [y/N]  " -r; [[ ! $REPLY =~ ^[Yy]$ ]] && return 0; }
            mkdir -p "$data_dir" && age -d "$file" | tar -C "$data_dir" -xzf - && success "restored" ;;
        list|ls)
            echo "=== Signal Backups ($backup_dir) ==="; [[ ! -d "$backup_dir" ]] && { echo "(none)"; return 0; }
            ls -1t "$backup_dir"/*.tar.age 2>/dev/null | head -10 | while read -r f; do echo "  $(basename "$f") ($(du -h "$f" | cut -f1))"; done ;;
        -h|--help|help|"") echo "Usage: bobnet signal [backup|restore|list] [--account <num>]" ;;
        *) error "Unknown: $subcmd" ;;
    esac
}

cmd_backup() {
    local with_signal=false label="manual" push=true
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --with-signal) with_signal=true; shift ;;
            --no-push) push=false; shift ;;
            -h|--help)
                cat <<'EOF'
Usage: bobnet backup [label] [--with-signal] [--no-push]

Backup OpenClaw config and optionally signal-cli data.

OPTIONS:
  --with-signal    Also backup signal-cli data (encrypted)
  --no-push        Skip git commit and push
  label            Reason for backup (default: "manual")

EXAMPLES:
  bobnet backup                       # Backup config
  bobnet backup "before migration"    # With label
  bobnet backup --with-signal         # Include signal data
EOF
                return 0 ;;
            -*) error "Unknown option: $1" ;;
            *) label="$1"; shift ;;
        esac
    done
    
    local claw=""; command -v openclaw &>/dev/null && claw="openclaw"
    [[ -z "$claw" ]] && error "$CLI_NAME not found"
    
    local ts=$(date +%Y-%m-%d_%H%M%S)
    local backup_dir="$BOBNET_ROOT/config/backups"
    mkdir -p "$backup_dir"
    
    # Backup openclaw.json
    local config="$CONFIG_DIR/$CONFIG_NAME"
    if [[ -f "$config" ]]; then
        local backup_file="$backup_dir/${CONFIG_NAME%.json}_${ts}.json"
        cp "$config" "$backup_file"
        success "config → $backup_file"
        # Also update latest symlink
        ln -sf "$(basename "$backup_file")" "$backup_dir/${CONFIG_NAME%.json}_latest.json"
    else
        warn "Config not found: $config"
    fi
    
    # Signal backup
    if [[ "$with_signal" == "true" ]]; then
        echo ""
        cmd_signal backup
    fi
    
    # Commit and push
    if [[ "$push" == "true" ]]; then
        echo ""
        cd "$BOBNET_ROOT"
        git add -A
        if git diff --staged --quiet; then
            echo "No changes to commit"
        else
            git commit -m "backup: $label - $(date -u +'%Y-%m-%d %H:%M UTC')"
            git push && success "pushed to remote" || warn "push failed"
        fi
    fi
}

cmd_sync() {
    local force=false dry_run=false yes=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force|-f) force=true; shift ;;
            --dry-run) dry_run=true; shift ;;
            --yes|-y) yes=true; shift ;;
            -h|--help)
                cat <<'EOF'
Usage: bobnet sync [--dry-run] [--yes] [--force]

Sync schema config into OpenClaw (agents, channels, bindings).

OPTIONS:
  --dry-run    Show what would change without applying
  --yes, -y    Skip confirmation prompt
  --force, -f  Replace channels instead of merge (strict mode)

BEHAVIOR:
  Default: Merge - only overwrites fields defined in schema
  Force:   Replace - schema is source of truth, removes extras
EOF
                return 0 ;;
            *) shift ;;
        esac
    done
    
    local claw=""; command -v openclaw &>/dev/null && claw="openclaw"
    [[ -z "$claw" ]] && error "$CLI_NAME not found"
    
    echo "=== BobNet Sync ==="
    echo ""
    
    local changes=()
    
    # 1. Check agents
    echo "--- Agents ---"
    local schema_agents=$(get_all_agents | grep -v '^main$' | sort)
    local config_agents=$($claw config get agents.list 2>/dev/null | jq -r '.[].id' 2>/dev/null | sort)
    
    local missing="" extra=""
    for agent in $schema_agents; do
        echo "$config_agents" | grep -q "^${agent}$" || missing="$missing $agent"
    done
    for agent in $config_agents; do
        [[ -z "$agent" ]] && continue
        echo "$schema_agents" | grep -q "^${agent}$" || extra="$extra $agent"
    done
    
    if [[ -z "$missing" && -z "$extra" ]]; then
        success "Agents in sync"
    else
        if [[ -n "$missing" ]]; then
            echo "  Add:$missing"
            changes+=("agents: add$missing")
        fi
        if [[ -n "$extra" ]]; then
            echo "  Remove:$extra"
            changes+=("agents: remove$extra")
        fi
    fi
    
    # 2. Check channels
    echo ""
    echo "--- Channels ---"
    for channel in $(jq -r '.channels // {} | keys[]' "$AGENTS_SCHEMA" 2>/dev/null); do
        local schema_config=$(jq -c ".channels.$channel" "$AGENTS_SCHEMA")
        local live_config=$($claw config get "channels.$channel" 2>/dev/null | jq -c '.' 2>/dev/null || echo '{}')
        
        local drift_keys=""
        for key in $(echo "$schema_config" | jq -r 'keys[]'); do
            local schema_val=$(echo "$schema_config" | jq -c ".$key")
            local live_val=$(echo "$live_config" | jq -c ".$key // null")
            if [[ "$schema_val" != "$live_val" ]]; then
                drift_keys="$drift_keys $key"
                echo "  $channel.$key:"
                echo "    schema: $schema_val"
                echo "    live:   $live_val"
            fi
        done
        
        if [[ -z "$drift_keys" ]]; then
            success "$channel in sync"
        else
            changes+=("$channel:$drift_keys")
        fi
    done
    
    # 3. Check bindings
    echo ""
    echo "--- Bindings ---"
    local schema_count=$(jq '.bindings | length' "$AGENTS_SCHEMA" 2>/dev/null || echo 0)
    local config_count=$($claw config get bindings 2>/dev/null | jq 'length' 2>/dev/null || echo 0)
    
    if [[ "$schema_count" == "$config_count" ]]; then
        success "Bindings in sync ($schema_count)"
    else
        echo "  Schema: $schema_count bindings"
        echo "  Live:   $config_count bindings"
        changes+=("bindings: $schema_count (schema) vs $config_count (live)")
    fi
    
    echo ""
    
    # Safety check: refuse to wipe everything
    local schema_agent_count=$(get_all_agents | wc -w | tr -d ' ')
    local schema_binding_count=$(jq '.bindings | length' "$AGENTS_SCHEMA" 2>/dev/null || echo 0)
    
    if [[ "$schema_agent_count" -eq 0 ]]; then
        echo -e "${RED}ERROR:${NC} Schema has 0 agents - refusing to sync"
        echo "  This would wipe all agents from config!"
        echo "  Check: $AGENTS_SCHEMA"
        echo ""
        echo "  Did you pull the latest repo?"
        echo "    cd \$BOBNET_ROOT && git pull"
        return 1
    fi
    
    # Summary
    if [[ ${#changes[@]} -eq 0 ]]; then
        success "Everything in sync"
        return 0
    fi
    
    echo "=== Changes Detected ==="
    for change in "${changes[@]}"; do
        echo "  • $change"
    done
    echo ""
    
    if [[ "$dry_run" == "true" ]]; then
        echo "Dry run complete - no changes applied"
        return 0
    fi
    
    # Confirmation
    if [[ "$yes" != "true" ]]; then
        local mode="merge"
        [[ "$force" == "true" ]] && mode="replace"
        read -p "Apply ${#changes[@]} change(s) in $mode mode? [y/N] " -r
        [[ ! $REPLY =~ ^[Yy]$ ]] && { echo "Cancelled"; return 0; }
    fi
    
    echo ""
    echo "Applying changes..."
    
    # Rebuild agents list
    local list='[' first=true
    for agent in $(get_all_agents); do
        local id="$agent"
        $first || list+=','; first=false
        list+="{\"id\":\"$id\",\"workspace\":\"$(get_workspace "$agent")\",\"agentDir\":\"$(get_agent_dir "$agent")\"}"
    done
    list+=']'
    $claw config set agents.list "$list" --json && success "agents applied"
    
    # Apply channels (merge or replace based on --force)
    for channel in $(jq -r '.channels // {} | keys[]' "$AGENTS_SCHEMA" 2>/dev/null); do
        local schema_config=$(jq -c ".channels.$channel" "$AGENTS_SCHEMA")
        if [[ "$force" == "true" ]]; then
            $claw config set "channels.$channel" "$schema_config" --json && success "$channel replaced"
        else
            for key in $(echo "$schema_config" | jq -r 'keys[]'); do
                local val=$(echo "$schema_config" | jq -c ".$key")
                $claw config set "channels.$channel.$key" "$val" --json 2>/dev/null
            done
            success "$channel merged"
        fi
    done
    
    # Apply bindings
    local bindings=$(jq -c '[.bindings[] | {agentId, match: {channel, peer: {kind: "group", id: .groupId}}}]' "$AGENTS_SCHEMA" 2>/dev/null || echo '[]')
    $claw config set bindings "$bindings" --json && success "bindings applied"
    
    echo ""
    success "Sync complete - restart gateway to apply"
    echo "  $claw gateway restart"
}

cmd_unlock() {
    [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { echo "Usage: bobnet unlock [keyfile]"; echo ""; echo "Unlock git-crypt. Default key: ~/.secrets/bobnet-vault.key"; return 0; }
    local key="${1:-$HOME/.secrets/bobnet-vault.key}"
    [[ -f "$key" ]] || error "Key not found: $key"
    cd "$BOBNET_ROOT" && git-crypt unlock "$key" && echo "Unlocked ✓"
}

cmd_lock() {
    [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { echo "Usage: bobnet lock"; echo ""; echo "Lock git-crypt (encrypts agents/ directory)."; return 0; }
    cd "$BOBNET_ROOT" && git-crypt lock && echo "Locked ✓"
}

cmd_update() {
    [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { echo "Usage: bobnet update"; echo ""; echo "Update bobnet CLI to the latest version from GitHub."; return 0; }
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
            local schema_agents=$(get_all_agents | grep -v '^main$' | sort)
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
        
        # 5. git-crypt locked (uninstall mode) - warn only
        if command -v git-crypt &>/dev/null && [[ -d "$BOBNET_ROOT/.git" ]]; then
            if (cd "$BOBNET_ROOT" && git-crypt status &>/dev/null); then
                warn "Repo is still unlocked (run 'bobnet lock' if done)"
            else
                success "Repo locked"
            fi
        fi
    else
        # NORMAL MODE: verify install is correct
        if [[ -n "$claw" ]]; then
            local config_agents=$($claw config get agents.list 2>/dev/null | jq -r '.[].id' | sort)
            local schema_agents=$(get_all_agents | grep -v '^main$' | sort)
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
            
            # 2. No orphan agents in config (include main in check - it's a valid schema agent)
            local all_schema_agents=$(get_all_agents | sort)
            local orphans=""
            for agent in $config_agents; do
                echo "$all_schema_agents" | grep -q "^${agent}$" || orphans="$orphans $agent"
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
                local id="$agent"
                echo ""
                read -p "    Add agent '$id'? [Y/n]  " -r
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
                echo "    bobnet sync"
                ((failures++))
            fi
        fi
        
        # 7. Channel config in sync
        if [[ -n "$claw" ]]; then
            local channel_drift=""
            for channel in $(jq -r '.channels // {} | keys[]' "$AGENTS_SCHEMA" 2>/dev/null); do
                local schema_config=$(jq -c ".channels.$channel" "$AGENTS_SCHEMA")
                local live_config=$($claw config get "channels.$channel" 2>/dev/null | jq -c '.' 2>/dev/null || echo '{}')
                for key in $(echo "$schema_config" | jq -r 'keys[]'); do
                    local schema_val=$(echo "$schema_config" | jq -c ".$key")
                    local live_val=$(echo "$live_config" | jq -c ".$key // null")
                    if [[ "$schema_val" != "$live_val" ]]; then
                        channel_drift="$channel_drift $channel.$key"
                    fi
                done
            done
            if [[ -z "$channel_drift" ]]; then
                success "Channel config in sync"
            else
                echo -e "${RED}✗${NC} Channel config drift:$channel_drift"
                echo "    bobnet sync"
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
  validate            Validate BobNet configuration
  sync                Sync schema to OpenClaw config
  backup              Backup OpenClaw config to repo
  eject               Migrate agents to standard OpenClaw structure
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
        sync) shift; cmd_sync "$@" ;;
        backup) shift; cmd_backup "$@" ;;
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
elif [[ -f "./config/agents-schema.json" ]]; then BOBNET_ROOT="$(pwd)"
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
export AGENTS_SCHEMA="$BOBNET_ROOT/config/agents-schema.json"
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
