#!/usr/bin/env bash
# BobNet CLI v3
# shellcheck disable=SC2155  # Allow declare and assign on same line
BOBNET_CLI_VERSION=$(cat "$HOME/.local/lib/bobnet/version" 2>/dev/null || echo "unknown")

# Config directory
CONFIG_DIR="$HOME/.openclaw"
CONFIG_NAME="openclaw.json"
CLI_NAME="openclaw"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
error() { echo -e "${RED}error:${NC} $*" >&2; exit 1; }
warn() { echo -e "${YELLOW}warn:${NC} $*" >&2; }
success() { echo -e "${GREEN}✓${NC} $*"; }


# Symlink ~/.openclaw/agents → BobNet agents directory
setup_agents_symlink() {
    local oc_agents="$CONFIG_DIR/agents"
    local bn_agents="$BOBNET_ROOT/agents"
    
    if [[ -L "$oc_agents" ]]; then
        local target=$(readlink "$oc_agents")
        if [[ "$target" == "$bn_agents" ]]; then
            return 0
        fi
    fi
    
    if [[ -d "$oc_agents" && ! -L "$oc_agents" ]]; then
        local file_count=$(find "$oc_agents" -type f 2>/dev/null | wc -l | tr -d ' ')
        if [[ "$file_count" -gt 0 ]]; then
            warn "~/.openclaw/agents/ exists with $file_count files - run 'bobnet link setup' to migrate"
            return 1
        else
            rmdir "$oc_agents" 2>/dev/null || rm -rf "$oc_agents"
        fi
    fi
    
    mkdir -p "$bn_agents"
    ln -sf "$bn_agents" "$oc_agents"
}

check_agents_symlink() {
    local oc_agents="$CONFIG_DIR/agents"
    local bn_agents="$BOBNET_ROOT/agents"
    
    if [[ -L "$oc_agents" ]]; then
        local target=$(readlink "$oc_agents")
        if [[ "$target" == "$bn_agents" ]]; then
            echo "Sessions: symlinked ✓"
        else
            echo "Sessions: symlinked (wrong target: $target)"
        fi
    elif [[ -d "$oc_agents" ]]; then
        echo "Sessions: ~/.openclaw/agents/ (not symlinked)"
    else
        echo "Sessions: not configured"
    fi
}

# Global variables and utilities
BOBNET_ROOT="${BOBNET_ROOT:-$HOME/.bobnet/ultima-thule}"
AGENTS_SCHEMA="$BOBNET_ROOT/config/bobnet.json"

# Schema helper functions
get_all_agents() {
    jq -r '.agents | keys[]' "$AGENTS_SCHEMA" 2>/dev/null || echo ""
}

get_all_scopes() {
    jq -r '.scopes | keys[]' "$AGENTS_SCHEMA" 2>/dev/null || echo ""
}

get_agents_by_scope() {
    local scope="$1"
    jq -r --arg s "$scope" '.agents | to_entries[] | select(.value.scope == $s) | .key' "$AGENTS_SCHEMA" 2>/dev/null || echo ""
}

get_workspace() {
    local agent="$1"
    echo "$BOBNET_ROOT/workspace/$agent"
}

get_agent_dir() {
    local agent="$1"
    echo "$BOBNET_ROOT/agents/$agent"
}

get_spawn_permissions() {
    local agent="$1"
    # Check for agent-specific permissions first, then fall back to default
    local agent_perms=$(jq -c --arg a "$agent" '.spawning.permissions[$a]' "$AGENTS_SCHEMA" 2>/dev/null)
    if [[ "$agent_perms" != "null" && "$agent_perms" != "[]" ]]; then
        echo "$agent_perms"
    else
        # Use default permissions
        local default_perms=$(jq -c '.spawning.permissions.default' "$AGENTS_SCHEMA" 2>/dev/null)
        [[ "$default_perms" == "null" || "$default_perms" == "[]" ]] && echo "" || echo "$default_perms"
    fi
}

get_agent_model() {
    local agent="$1"
    jq -r --arg a "$agent" '.agents[$a].model // empty' "$AGENTS_SCHEMA" 2>/dev/null
}

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
  • Apply spawn permissions (subagents.allowAgents)
  • Apply bindings from schema
  • Apply channel configs from schema
  • Link agent directories (symlinks from ~/.openclaw/agents/ to BobNet)
  • Back up any existing OpenClaw data before linking
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
    
    # Build agents list - all agents get BobNet paths + spawn permissions
    local list='[' first=true
    
    for agent in $(get_all_agents); do
        local is_default=$(jq -r --arg a "$agent" '.agents[$a].default // false' "$AGENTS_SCHEMA")
        local spawn_perms=$(get_spawn_permissions "$agent")
        local model=$(get_agent_model "$agent")
        $first || list+=','
        first=false
        list+="{\"id\":\"$agent\",\"workspace\":\"$(get_workspace "$agent")\",\"agentDir\":\"$(get_agent_dir "$agent")\""
        [[ "$is_default" == "true" ]] && list+=",\"default\":true"
        [[ -n "$model" ]] && list+=",\"model\":\"$model\""
        [[ -n "$spawn_perms" ]] && list+=",\"subagents\":{\"allowAgents\":$spawn_perms}"
        list+="}"
        success "agent: $agent"
    done
    list+=']'
    
    local bindings=$(jq -c '[.bindings[] | {agentId, match: {channel, peer: {kind: (if .groupId then "group" else "dm" end), id: (.groupId // .dmId)}}}]' "$AGENTS_SCHEMA" 2>/dev/null || echo '[]')
    local bind_count=$(echo "$bindings" | jq length)
    
    $claw config set agents.defaults.workspace "$(get_workspace bob)"
    local default_model=$(get_default_model)
    [[ -n "$default_model" ]] && $claw config set agents.defaults.model.primary "$default_model"
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
    fi
    
    # Migrate agent dir
    if [[ -d "$oc_main_ad" && ! -d "$bn_main_ad" ]]; then
        mkdir -p "$(dirname "$bn_main_ad")"
        mv "$oc_main_ad" "$bn_main_ad" && success "agentDir: $oc_main_ad → $bn_main_ad"
    fi
    
    # Create agent directory symlinks (with backup)
    echo ""
    cmd_link create
    
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

This will:
  • Unlink agent directories (convert symlinks to real dirs, copying from BobNet)
  • Restore pre-BobNet config (if backup exists)
  • Optionally move/keep/delete the BobNet repo

OPTIONS:
  --force    Skip confirmation prompts
  --cli      Also remove CLI (~/.local/bin/bobnet, ~/.local/lib/bobnet/)

You will be prompted for what to do with the repo:
  [M]ove   → Move to ~/<repo-name> (visible, preserved)
  [K]eep   → Keep in ~/.bobnet/ (hidden, preserved)  
  [D]elete → Delete entirely (destructive)

To restore from backup instead of copying from BobNet:
  bobnet link unlink --restore
EOF
                return 0 ;;
            *) shift ;;
        esac
    done
    
    local claw=""; command -v openclaw &>/dev/null && claw="openclaw"
    [[ -z "$claw" ]] && error "$CLI_NAME not found"
    local config="$CONFIG_DIR/$CONFIG_NAME"
    
    [[ "$force" == "false" ]] && { echo "This will clear BobNet from $CLI_NAME config."; read -p "Continue? [y/N]  " -r; [[ ! $REPLY =~ ^[Yy]$ ]] && return 0; }
    
    # Unlink agent directories (convert symlinks back to real dirs)
    echo ""
    echo "Unlinking agent directories..."
    cmd_link unlink 2>/dev/null || true
    
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
            # Parse arguments
            local name="" scope="" description="" model="" is_default=false standalone=false
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --scope) scope="$2"; shift 2 ;;
                    --description) description="$2"; shift 2 ;;
                    --model) model="$2"; shift 2 ;;
                    --default) is_default=true; shift ;;
                    --standalone) standalone=true; shift ;;
                    --help|-h)
                        echo "Usage: bobnet agent add <name> [options]"
                        echo ""
                        echo "Options:"
                        echo "  --scope <scope>       Required for new agents. Scope (meta/work/personal)."
                        echo "  --description <text>  Optional. Description for schema."
                        echo "  --model <id>          Optional. Default model for this agent."
                        echo "  --default             Optional. Mark as default agent."
                        echo "  --standalone          Optional. Keep OpenClaw's AGENTS.md (no core symlink)."
                        echo ""
                        echo "Examples:"
                        echo "  bobnet agent add olivia --scope personal --standalone"
                        echo "  bobnet agent add bill --scope work --description 'R&D specialist'"
                        return 0 ;;
                    -*) error "Unknown option: $1" ;;
                    *) [[ -z "$name" ]] && name="$1" || error "Unexpected argument: $1"; shift ;;
                esac
            done
            
            [[ -z "$name" ]] && error "Usage: bobnet agent add <name> --scope <scope> [options]"
            
            # Check if agent exists in schema
            local in_schema=false
            if jq -e --arg a "$name" '.agents[$a]' "$AGENTS_SCHEMA" >/dev/null 2>&1; then
                in_schema=true
            fi
            
            # If not in schema, require --scope and add it
            if [[ "$in_schema" == "false" ]]; then
                [[ -z "$scope" ]] && error "Agent '$name' not in schema. Use --scope to add it."
                
                # Validate scope exists
                if ! jq -e --arg s "$scope" '.scopes[$s]' "$AGENTS_SCHEMA" >/dev/null 2>&1; then
                    error "Scope '$scope' not found. Available: $(jq -r '.scopes | keys | join(", ")' "$AGENTS_SCHEMA")"
                fi
                
                # Build agent entry
                local agent_json="{\"scope\": \"$scope\""
                [[ -n "$description" ]] && agent_json="$agent_json, \"description\": \"$description\""
                [[ "$is_default" == "true" ]] && agent_json="$agent_json, \"default\": true"
                agent_json="$agent_json}"
                
                # Add to schema
                jq --arg name "$name" --argjson entry "$agent_json" '.agents[$name] = $entry' "$AGENTS_SCHEMA" > "$AGENTS_SCHEMA.tmp"
                mv "$AGENTS_SCHEMA.tmp" "$AGENTS_SCHEMA"
                success "Added '$name' to schema (scope: $scope)"
            else
                echo "  Agent '$name' already in schema"
                # Update description if provided
                if [[ -n "$description" ]]; then
                    jq --arg name "$name" --arg desc "$description" '.agents[$name].description = $desc' "$AGENTS_SCHEMA" > "$AGENTS_SCHEMA.tmp"
                    mv "$AGENTS_SCHEMA.tmp" "$AGENTS_SCHEMA"
                    success "Updated description"
                fi
            fi
            
            local ws=$(get_workspace "$name")
            local ad=$(get_agent_dir "$name")
            
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
                    local claw_args=("$name" --workspace "$ws" --agent-dir "$ad" --non-interactive)
                    [[ -n "$model" ]] && claw_args+=(--model "$model")
                    $claw agents add "${claw_args[@]}"
                    success "Added to OpenClaw"
                fi
                
                # Clean up nested .git directories (BobNet uses one repo, not per-agent repos)
                [[ -d "$ws/.git" ]] && rm -rf "$ws/.git" && success "Removed nested .git from workspace"
                [[ -d "$ad/.git" ]] && rm -rf "$ad/.git" && success "Removed nested .git from agent dir"
                
                # Apply spawn permissions from schema
                local spawn_perms=$(get_spawn_permissions "$name")
                if [[ -n "$spawn_perms" ]]; then
                    # Find agent index and update subagents.allowAgents
                    local agents_list=$($claw config get agents.list 2>/dev/null)
                    local updated=$(echo "$agents_list" | jq --arg id "$name" --argjson perms "$spawn_perms" '
                        map(if .id == $id then .subagents.allowAgents = $perms else . end)
                    ')
                    $claw config set agents.list "$updated" --json 2>/dev/null
                    success "Applied spawn permissions: $spawn_perms"
                fi
            else
                warn "OpenClaw not found, skipping config update"
                echo "  Run 'bobnet install' to sync config"
            fi
            
            # Copy auth-profiles.json from bob if it exists and target doesn't have it
            local bob_auth="$BOBNET_ROOT/agents/bob/auth-profiles.json"
            local target_auth="$ad/auth-profiles.json"
            if [[ -f "$bob_auth" && ! -f "$target_auth" ]]; then
                cp "$bob_auth" "$target_auth"
                success "Copied auth-profiles.json from bob"
            fi
            
            # Symlink AGENTS.md to shared core (unless --standalone)
            if [[ "$standalone" == "false" ]]; then
                if [[ ! -e "$ws/AGENTS.md" ]]; then
                    # Doesn't exist - create symlink
                    ln -s "../../core/AGENTS.md" "$ws/AGENTS.md"
                    success "Symlinked AGENTS.md → core/AGENTS.md"
                elif [[ -f "$ws/AGENTS.md" && ! -L "$ws/AGENTS.md" ]]; then
                    # Exists as file, not symlink - replace with symlink
                    rm "$ws/AGENTS.md"
                    ln -s "../../core/AGENTS.md" "$ws/AGENTS.md"
                    success "Symlinked AGENTS.md → core/AGENTS.md"
                fi
            else
                echo "  Standalone mode: keeping OpenClaw's AGENTS.md"
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

Options for 'add':
  --scope <scope>       Required for new agents
  --description <text>  Optional description
  --model <id>          Optional default model
  --default             Mark as default agent
  --standalone          Keep OpenClaw's AGENTS.md (no core symlink)

Examples:
  bobnet agent list
  bobnet agent default bob
  bobnet agent add olivia --scope personal --standalone
  bobnet agent add bill --scope work --description "R&D specialist"
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
            jq -r '.bindings[] | "  \(.agentId) → \(.channel) \(if .groupId then "group:" + .groupId[:16] else "dm:" + .dmId[:16] end)..."' "$AGENTS_SCHEMA" 2>/dev/null || echo "  (none)"
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
            [[ -n "$claw" ]] && { local bindings=$(jq -c '[.bindings[] | {agentId, match: {channel, peer: {kind: (if .groupId then "group" else "dm" end), id: (.groupId // .dmId)}}}]' "$AGENTS_SCHEMA"); $claw config set bindings "$bindings" --json; success "applied to config"; } ;;
        remove|rm)
            local agent_id="${1:-}"; [[ -z "$agent_id" ]] && error "Usage: bobnet binding remove <agent>"
            jq --arg a "$agent_id" '.bindings = [.bindings[] | select(.agentId != $a)]' "$AGENTS_SCHEMA" > "${AGENTS_SCHEMA}.tmp" && mv "${AGENTS_SCHEMA}.tmp" "$AGENTS_SCHEMA"
            success "removed from schema"
            [[ -n "$claw" ]] && { local bindings=$(jq -c '[.bindings[] | {agentId, match: {channel, peer: {kind: (if .groupId then "group" else "dm" end), id: (.groupId // .dmId)}}}]' "$AGENTS_SCHEMA"); $claw config set bindings "$bindings" --json; success "applied to config"; } ;;
        sync)
            [[ -z "$claw" ]] && error "$CLI_NAME not found"
            local bindings=$(jq -c '[.bindings[] | {agentId, match: {channel, peer: {kind: (if .groupId then "group" else "dm" end), id: (.groupId // .dmId)}}}]' "$AGENTS_SCHEMA")
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
    
    signal_update_group() {
        local group_id="" new_name="" new_description="" account="" force=false
        
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --name) new_name="$2"; shift 2 ;;
                --description) new_description="$2"; shift 2 ;;
                --account|-a) account="$2"; shift 2 ;;
                --force) force=true; shift ;;
                -h|--help)
                    cat <<'EOF'
Usage: bobnet signal updateGroup <groupId> [options]

Update Signal group name and/or description.

ARGUMENTS:
  groupId                 Signal group ID (with or without signal:group: prefix)

OPTIONS:
  --name <name>           New group name
  --description <desc>    New group description  
  --account <num>         Signal account (auto-detected if not specified)
  --force                 Skip confirmation prompt

EXAMPLES:
  bobnet signal updateGroup P1JlWw/uMmoc/h8JWVXYqT/2UsRQ+Llfal6xSNojcJ8= --name "OpenClaw"
  bobnet signal updateGroup signal:group:P1J... --description "OpenClaw development"

WARNING: This temporarily stops OpenClaw Signal daemon (gateway restart required).
EOF
                    return 0 ;;
                -*) error "Unknown option: $1" ;;
                *) 
                    if [[ -z "$group_id" ]]; then
                        group_id="$1"
                    else
                        error "Unexpected argument: $1"
                    fi
                    shift ;;
            esac
        done
        
        # Validate required arguments
        [[ -z "$group_id" ]] && error "Usage: bobnet signal updateGroup <groupId> [--name <name>] [--description <desc>]"
        [[ -z "$new_name" && -z "$new_description" ]] && error "At least one of --name or --description is required"
        
        # Normalize group ID (remove signal:group: prefix if present)
        group_id="${group_id#signal:group:}"
        
        # Check dependencies
        command -v signal-cli &>/dev/null || error "signal-cli not found. Install with: brew install signal-cli"
        
        # Get Signal account
        if [[ -z "$account" ]]; then
            account=$(signal_get_account)
        fi
        
        # Check if OpenClaw is running
        local claw=""
        command -v openclaw &>/dev/null && claw="openclaw"
        [[ -z "$claw" ]] && error "openclaw not found"
        
        local gateway_running=false
        if $claw gateway call config.get &>/dev/null; then
            gateway_running=true
        fi
        
        echo "=== Signal Group Update ==="
        echo "Group: $group_id"
        [[ -n "$new_name" ]] && echo "Name: → \"$new_name\""
        [[ -n "$new_description" ]] && echo "Description: → \"$new_description\""
        echo "Account: $account"
        echo ""
        
        if [[ "$gateway_running" == "true" ]]; then
            echo "⚠️  WARNING: This will temporarily restart OpenClaw gateway"
            echo "   Signal daemon must be stopped to avoid file lock conflicts"
            echo ""
        fi
        
        if [[ "$force" != "true" ]]; then
            read -p "Continue? [y/N] " -r
            [[ ! $REPLY =~ ^[Yy]$ ]] && { echo "Cancelled"; return 0; }
        fi
        
        # Step 1: Disable Signal autoStart if gateway is running
        local autostart_was_enabled=false
        if [[ "$gateway_running" == "true" ]]; then
            echo "Checking Signal autoStart setting..."
            local current_autostart=$($claw config get channels.signal.autoStart 2>/dev/null || echo "null")
            if [[ "$current_autostart" == "true" ]]; then
                autostart_was_enabled=true
                echo "Disabling Signal autoStart..."
                $claw config set channels.signal.autoStart false
                success "Signal autoStart disabled"
            fi
            
            echo "Restarting gateway to stop Signal daemon..."
            $claw gateway restart --no-broadcast --yes >/dev/null 2>&1 && success "Gateway restarted" || warn "Gateway restart may have failed"
            
            # Brief pause for daemon to fully stop
            sleep 3
        fi
        
        # Step 2: Run signal-cli updateGroup command
        echo "Updating Signal group..."
        local cmd=("signal-cli" "-a" "$account" "updateGroup")
        cmd+=("-g" "$group_id")
        [[ -n "$new_name" ]] && cmd+=(--name "$new_name")
        [[ -n "$new_description" ]] && cmd+=(--description "$new_description")
        
        echo "Running: ${cmd[*]}"
        if "${cmd[@]}"; then
            success "Group updated successfully"
        else
            error "signal-cli command failed"
        fi
        
        # Step 3: Re-enable autoStart and restart gateway if needed
        if [[ "$gateway_running" == "true" ]]; then
            if [[ "$autostart_was_enabled" == "true" ]]; then
                echo "Re-enabling Signal autoStart..."
                $claw config set channels.signal.autoStart true
                success "Signal autoStart re-enabled"
            fi
            
            echo "Restarting gateway to resume normal operation..."
            $claw gateway restart --no-broadcast --yes >/dev/null 2>&1 && success "Gateway restarted - Signal daemon restored" || warn "Gateway restart may have failed"
        fi
        
        echo ""
        success "Signal group update complete"
    }
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
        updateGroup)
            signal_update_group "$@" ;;
        list|ls)
            echo "=== Signal Backups ($backup_dir) ==="; [[ ! -d "$backup_dir" ]] && { echo "(none)"; return 0; }
            ls -1t "$backup_dir"/*.tar.age 2>/dev/null | head -10 | while read -r f; do echo "  $(basename "$f") ($(du -h "$f" | cut -f1))"; done ;;
        -h|--help|help|"")
            cat <<'EOF'
Usage: bobnet signal <command> [options]

Signal-cli integration with OpenClaw daemon coordination.

COMMANDS:
  backup [--account <num>]      Backup Signal data (encrypted)
  restore [--file <path>]       Restore Signal data from backup
  list                          List available backups
  updateGroup <groupId>         Update group name/description

EXAMPLES:
  bobnet signal backup                                    # Backup Signal data
  bobnet signal updateGroup <groupId> --name "OpenClaw"   # Update group name
  bobnet signal updateGroup <groupId> --description "..."  # Update description
  bobnet signal updateGroup <groupId> --name "..." --description "..."  # Both

updateGroup coordinates with OpenClaw gateway (stops daemon, runs command, restarts).
EOF
            ;;
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
    
    # Rebuild agents list with spawn permissions + model + extraPaths (always includes PROXY.md)
    local list='[' first=true
    for agent in $(get_all_agents); do
        local id="$agent"
        local is_default=$(jq -r --arg a "$agent" '.agents[$a].default // false' "$AGENTS_SCHEMA")
        local spawn_perms=$(get_spawn_permissions "$agent")
        local model=$(get_agent_model "$agent")
        local ws=$(get_workspace "$agent")
        $first || list+=','; first=false
        list+="{\"id\":\"$id\",\"workspace\":\"$ws\",\"agentDir\":\"$(get_agent_dir "$agent")\""
        [[ "$is_default" == "true" ]] && list+=",\"default\":true"
        [[ -n "$model" ]] && list+=",\"model\":\"$model\""
        [[ -n "$spawn_perms" ]] && list+=",\"subagents\":{\"allowAgents\":$spawn_perms}"
        # Always include PROXY.md in memorySearch.extraPaths (file presence controls proxy mode)
        list+=",\"memorySearch\":{\"extraPaths\":[\"$ws/PROXY.md\"]}"
        list+="}"
    done
    list+=']'
    local default_model=$(get_default_model)
    [[ -n "$default_model" ]] && $claw config set agents.defaults.model.primary "$default_model"
    $claw config set agents.list "$list" --json && success "agents + spawn permissions applied"
    
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
    local bindings=$(jq -c '[.bindings[] | {agentId, match: {channel, peer: {kind: (if .groupId then "group" else "dm" end), id: (.groupId // .dmId)}}}]' "$AGENTS_SCHEMA" 2>/dev/null || echo '[]')
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
            -h|--help) echo "Usage: bobnet validate [--uninstall]"; echo ""; echo "Alias for 'bobnet sync --dry-run' (detailed state report)."; echo "Use --uninstall to verify clean uninstall state."; return 0 ;;
            *) shift ;;
        esac
    done
    
    # Default mode: delegate to sync --dry-run for detailed state report
    if [[ "$uninstall_mode" == "false" ]]; then
        cmd_sync --dry-run
        return $?
    fi
    
    # Uninstall mode: verify config is clean
    local claw=""; command -v openclaw &>/dev/null && claw="openclaw"
    local failures=0
    
    echo "=== BobNet Validate (uninstall) ==="
    echo ""
    
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
    
    echo ""
    if [[ $failures -eq 0 ]]; then
        success "All checks passed"
        return 0
    else
        echo -e "${RED}$failures check(s) failed${NC}"
        return 1
    fi
}

cmd_report() {
    [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && {
        echo "Usage: bobnet report"
        echo ""
        echo "Run systems health check for Matrix1."
        echo "Checks disk, memory, OpenClaw, Signal, Tailscale, and repo status."
        return 0
    }
    local script="$BOBNET_ROOT/scripts/systems-report"
    if [[ -x "$script" ]]; then
        "$script"
    else
        error "Systems report script not found: $script"
    fi
}

cmd_memory() {
    local subcmd="${1:-help}"
    shift 2>/dev/null || true
    
    case "$subcmd" in
        -h|--help|help)
            cat <<'EOF'
Usage: bobnet memory <command> [options]

Manage memory search indexes for agents.

COMMANDS:
  status              Show index status for all agents
  rebuild [agent]     Rebuild indexes (all agents or specific agent)

EXAMPLES:
  bobnet memory status
  bobnet memory rebuild
  bobnet memory rebuild bob
EOF
            return 0
            ;;
        status)
            command -v openclaw &>/dev/null || error "openclaw not found"
            echo "Memory Search Index Status"
            echo "=========================="
            for agent in $(openclaw agents list --json 2>/dev/null | jq -r '.[].id' 2>/dev/null); do
                local status_output indexed total chunks
                status_output=$(openclaw memory status --agent "$agent" 2>&1)
                indexed=$(echo "$status_output" | grep "^Indexed:" | sed 's/Indexed: //' | cut -d'/' -f1)
                total=$(echo "$status_output" | grep "^Indexed:" | sed 's/Indexed: //' | cut -d'/' -f2 | cut -d' ' -f1)
                chunks=$(echo "$status_output" | grep "^Indexed:" | grep -o '[0-9]* chunks' | grep -o '[0-9]*' || echo "0")
                
                if [[ -z "$total" || "$total" == "0" ]]; then
                    echo "  $agent: no memory files"
                elif [[ "$indexed" == "$total" ]]; then
                    echo -e "  $agent: ${GREEN}✓${NC} $indexed/$total files ($chunks chunks)"
                else
                    echo -e "  $agent: ${YELLOW}⚠${NC} $indexed/$total files (needs rebuild)"
                fi
            done
            ;;
        rebuild)
            command -v openclaw &>/dev/null || error "openclaw not found"
            local target_agent="${1:-}"
            local rebuilt=0 skipped=0 failed=0
            
            echo "Memory Index Rebuild"
            echo "===================="
            
            local agents
            if [[ -n "$target_agent" ]]; then
                agents="$target_agent"
            else
                agents=$(openclaw agents list --json 2>/dev/null | jq -r '.[].id' 2>/dev/null)
            fi
            
            for agent in $agents; do
                echo -n "  [$agent] "
                
                # Check if agent has memory files
                local status_output total
                status_output=$(openclaw memory status --agent "$agent" 2>&1)
                total=$(echo "$status_output" | grep "^Indexed:" | sed 's/Indexed: //' | cut -d'/' -f2 | cut -d' ' -f1)
                
                if [[ -z "$total" || "$total" == "0" ]]; then
                    echo "no memory files (skipped)"
                    ((skipped++))
                    continue
                fi
                
                # Rebuild index
                if openclaw memory index --agent "$agent" --force &>/dev/null; then
                    local new_status indexed chunks
                    new_status=$(openclaw memory status --agent "$agent" 2>&1)
                    indexed=$(echo "$new_status" | grep "^Indexed:" | sed 's/Indexed: //' | cut -d'/' -f1)
                    total=$(echo "$new_status" | grep "^Indexed:" | sed 's/Indexed: //' | cut -d'/' -f2 | cut -d' ' -f1)
                    chunks=$(echo "$new_status" | grep "^Indexed:" | grep -o '[0-9]* chunks' | grep -o '[0-9]*')
                    echo -e "${GREEN}✓${NC} indexed $indexed/$total files ($chunks chunks)"
                    ((rebuilt++))
                else
                    echo -e "${RED}✗${NC} failed"
                    ((failed++))
                fi
            done
            
            echo ""
            echo "Summary: $rebuilt rebuilt, $skipped skipped, $failed failed"
            [[ $failed -gt 0 ]] && return 1
            return 0
            ;;
        *)
            error "Unknown memory command: $subcmd (try 'bobnet memory help')"
            ;;
    esac
}

cmd_search() {
    local TRANSCRIPTS_BASE="$CONFIG_DIR/agents"
    
    search_all() {
        local pattern="$1"
        echo "Searching transcripts for: $pattern"
        echo ""
        
        for agent_dir in "$TRANSCRIPTS_BASE"/*/; do
            local agent=$(basename "$agent_dir")
            [[ -d "$agent_dir/sessions" ]] || continue
            
            local count=$(grep -rci "$pattern" "$agent_dir/sessions/"*.jsonl 2>/dev/null | awk -F: '{sum+=$2} END {print sum+0}')
            if [[ "${count:-0}" -gt 0 ]]; then
                echo "  $agent: $count matches"
            fi
        done
    }
    
    search_agent() {
        local agent="$1" pattern="$2"
        echo "Searching $agent transcripts for: $pattern"
        grep -ci "$pattern" "$TRANSCRIPTS_BASE/$agent/sessions/"*.jsonl 2>/dev/null || echo "No matches"
    }
    
    find_errors() {
        echo "=== Common Error Patterns ==="
        echo ""
        
        local patterns=("error" "failed" "exception" "401" "403" "timeout" "not found" "unable to")
        
        for pattern in "${patterns[@]}"; do
            local total=$(grep -rci "$pattern" "$TRANSCRIPTS_BASE"/*/sessions/*.jsonl 2>/dev/null | awk -F: '{sum+=$2} END {print sum+0}')
            if [[ "${total:-0}" -gt 0 ]]; then
                printf "  %-20s %d occurrences\n" "$pattern" "$total"
            fi
        done
    }
    
    summarize() {
        echo "=== Transcript Summary ==="
        echo ""
        
        for agent_dir in "$TRANSCRIPTS_BASE"/*/; do
            local agent=$(basename "$agent_dir")
            [[ -d "$agent_dir/sessions" ]] || continue
            
            local count=$(ls "$agent_dir/sessions/"*.jsonl 2>/dev/null | wc -l | tr -d ' ')
            local size=$(du -sh "$agent_dir/sessions" 2>/dev/null | cut -f1)
            
            if [[ "${count:-0}" -gt 0 ]]; then
                echo "  $agent: $count sessions, $size"
            fi
        done
    }
    
    case "${1:-}" in
        -h|--help|"")
            cat <<'EOF'
Usage: bobnet search [agent] <pattern>
       bobnet search --errors
       bobnet search --summary

Search agent session transcripts.

EXAMPLES:
  bobnet search error           Search all agents for 'error'
  bobnet search bob failed      Search bob's transcripts for 'failed'
  bobnet search --errors        Find common error patterns
  bobnet search --summary       Show transcript sizes per agent
EOF
            return 0
            ;;
        --errors)
            find_errors
            ;;
        --summary)
            summarize
            ;;
        *)
            if [[ -d "$TRANSCRIPTS_BASE/$1/sessions" ]]; then
                local agent="$1"
                local pattern="${2:-}"
                [[ -z "$pattern" ]] && { echo "Usage: bobnet search <agent> <pattern>"; return 1; }
                search_agent "$agent" "$pattern"
            else
                search_all "$1"
            fi
            ;;
    esac
}

cmd_link() {
    # NOTE: Currently we symlink each agent individually:
    #   ~/.openclaw/agents/bob -> ~/.bobnet/ultima-thule/agents/bob
    #
    # OpenClaw stores sessions/auth in ~/.openclaw/agents/<agent>/ regardless
    # of the agentDir config. If OpenClaw changes to respect agentDir for
    # sessions/auth/etc, we could simplify to a single directory symlink:
    #   ~/.openclaw/agents -> ~/.bobnet/ultima-thule/agents
    #
    # That would eliminate per-agent linking entirely. Watch for this change.
    
    local OC_AGENTS="$CONFIG_DIR/agents"
    local BN_AGENTS="$BOBNET_ROOT/agents"
    
    case "${1:-status}" in
        -h|--help|help)
            cat <<'EOF'
Usage: bobnet link [command] [options]

Manage symlinks from ~/.openclaw/agents/ to BobNet agents directory.

COMMANDS:
  status    Show link status for all agents (default)
  create    Create missing symlinks (backs up existing data first)
  unlink    Remove symlinks, restore real directories
  check     Validate all links are correct (exit 1 if issues)

OPTIONS (unlink):
  --restore   Restore from backup instead of copying from BobNet
  --agent X   Only unlink specific agent

EXAMPLES:
  bobnet link              # Show status
  bobnet link create       # Create/fix all symlinks
  bobnet link unlink       # Remove symlinks, copy data from BobNet
  bobnet link unlink --restore  # Restore from agents-backup/
  bobnet link check        # Validate (for CI/scripts)

SAFETY:
  'create' backs up to ~/.openclaw/agents-backup/<agent>-<timestamp>/
  'unlink --restore' recovers from the most recent backup
EOF
            return 0
            ;;
        status)
            echo "Agent Directory Links"
            echo "====================="
            echo "OpenClaw: $OC_AGENTS"
            echo "BobNet:   $BN_AGENTS"
            echo ""
            
            local issues=0
            for agent_dir in "$BN_AGENTS"/*/; do
                [[ -d "$agent_dir" ]] || continue
                local agent=$(basename "$agent_dir")
                local oc_path="$OC_AGENTS/$agent"
                
                if [[ -L "$oc_path" ]]; then
                    local target=$(readlink "$oc_path")
                    if [[ "$target" == "$BN_AGENTS/$agent" ]]; then
                        echo -e "  ${GREEN}✓${NC} $agent → linked"
                    else
                        echo -e "  ${YELLOW}⚠${NC} $agent → wrong target: $target"
                        ((issues++))
                    fi
                elif [[ -d "$oc_path" ]]; then
                    echo -e "  ${YELLOW}⚠${NC} $agent → real directory (needs migration)"
                    ((issues++))
                else
                    echo -e "  ${YELLOW}⚠${NC} $agent → missing"
                    ((issues++))
                fi
            done
            
            echo ""
            if [[ $issues -gt 0 ]]; then
                echo "Run 'bobnet link create' to fix $issues issue(s)"
                return 1
            else
                echo "All links OK"
            fi
            ;;
        create)
            echo "Creating agent directory links..."
            mkdir -p "$OC_AGENTS"
            
            for agent_dir in "$BN_AGENTS"/*/; do
                [[ -d "$agent_dir" ]] || continue
                local agent=$(basename "$agent_dir")
                local oc_path="$OC_AGENTS/$agent"
                local bn_path="$BN_AGENTS/$agent"
                
                if [[ -L "$oc_path" ]]; then
                    local target=$(readlink "$oc_path")
                    if [[ "$target" == "$bn_path" ]]; then
                        success "$agent: already linked"
                    else
                        rm "$oc_path"
                        ln -s "$bn_path" "$oc_path"
                        success "$agent: relinked (was: $target)"
                    fi
                elif [[ -d "$oc_path" ]]; then
                    echo "  Migrating $agent..."
                    
                    local backup_dir="$CONFIG_DIR/agents-backup"
                    local timestamp=$(date +%Y%m%d-%H%M%S)
                    
                    # Always backup OpenClaw directory if it has content
                    if [[ -n "$(ls -A "$oc_path" 2>/dev/null)" ]]; then
                        local backup_path="$backup_dir/${agent}-oc-${timestamp}"
                        mkdir -p "$backup_dir"
                        cp -r "$oc_path" "$backup_path"
                        echo "    Backed up OpenClaw: $backup_path"
                    fi
                    
                    # Migrate items from OC to BN
                    local has_conflicts=false
                    for item in "$oc_path"/*; do
                        [[ -e "$item" ]] || continue
                        local name=$(basename "$item")
                        
                        if [[ ! -e "$bn_path/$name" ]]; then
                            # Doesn't exist in BN - just copy
                            cp -r "$item" "$bn_path/"
                            echo "    Migrated: $name"
                        elif [[ "$name" == "sessions" && -d "$item" && -d "$bn_path/$name" ]]; then
                            # Sessions directory - merge individual session files
                            local merged=0
                            for sess in "$item"/*; do
                                [[ -e "$sess" ]] || continue
                                local sess_name=$(basename "$sess")
                                if [[ ! -e "$bn_path/$name/$sess_name" ]]; then
                                    cp -r "$sess" "$bn_path/$name/"
                                    ((merged++))
                                fi
                            done
                            echo "    Merged sessions: $merged new session(s)"
                        else
                            # Conflict - backup BobNet version too, keep BN
                            has_conflicts=true
                            if [[ ! -d "$backup_dir/${agent}-bn-${timestamp}" ]]; then
                                mkdir -p "$backup_dir/${agent}-bn-${timestamp}"
                            fi
                            cp -r "$bn_path/$name" "$backup_dir/${agent}-bn-${timestamp}/"
                            echo "    Conflict: $name (keeping BobNet, both backed up)"
                        fi
                    done
                    
                    if [[ "$has_conflicts" == "true" ]]; then
                        echo "    ${YELLOW}⚠${NC} Conflicts backed up to $backup_dir/${agent}-bn-${timestamp}/"
                        echo "      Review and merge manually if needed"
                    fi
                    
                    # Remove OC directory and create symlink
                    rm -rf "$oc_path"
                    ln -s "$bn_path" "$oc_path"
                    success "$agent: migrated and linked"
                else
                    ln -s "$bn_path" "$oc_path"
                    success "$agent: linked"
                fi
            done
            
            echo ""
            echo "Done. Restart gateway to apply: openclaw gateway restart"
            ;;
        unlink)
            local restore=false
            local target_agent=""
            shift 2>/dev/null || true
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --restore|-r) restore=true; shift ;;
                    --agent|-a) target_agent="$2"; shift 2 ;;
                    *) error "Unknown option: $1" ;;
                esac
            done
            
            local backup_dir="$CONFIG_DIR/agents-backup"
            
            if [[ "$restore" == "true" ]]; then
                # Restore from backup
                if [[ ! -d "$backup_dir" ]]; then
                    error "No backups found at $backup_dir"
                fi
                
                echo "Available backups:"
                local backups=()
                for b in "$backup_dir"/*; do
                    [[ -d "$b" ]] || continue
                    backups+=("$b")
                    local name=$(basename "$b")
                    local agent="${name%-*}"  # strip timestamp
                    echo "  $(( ${#backups[@]} )). $name"
                done
                
                if [[ ${#backups[@]} -eq 0 ]]; then
                    error "No backups found"
                fi
                
                echo ""
                read -rp "Restore which backup? [1-${#backups[@]}, or 'all' for most recent per agent]: " choice
                
                if [[ "$choice" == "all" ]]; then
                    # Find most recent backup for each agent
                    declare -A latest
                    for b in "${backups[@]}"; do
                        local name=$(basename "$b")
                        local agent="${name%-*}"
                        latest[$agent]="$b"  # later ones overwrite (sorted by timestamp)
                    done
                    
                    for agent in "${!latest[@]}"; do
                        local backup_path="${latest[$agent]}"
                        local oc_path="$OC_AGENTS/$agent"
                        
                        echo "Restoring $agent from $(basename "$backup_path")..."
                        
                        # Remove existing (symlink or dir)
                        if [[ -L "$oc_path" ]]; then
                            rm "$oc_path"
                        elif [[ -d "$oc_path" ]]; then
                            rm -rf "$oc_path"
                        fi
                        
                        cp -r "$backup_path" "$oc_path"
                        success "$agent: restored"
                    done
                else
                    local idx=$((choice - 1))
                    if [[ $idx -lt 0 || $idx -ge ${#backups[@]} ]]; then
                        error "Invalid choice"
                    fi
                    
                    local backup_path="${backups[$idx]}"
                    local name=$(basename "$backup_path")
                    local agent="${name%-*}"
                    local oc_path="$OC_AGENTS/$agent"
                    
                    echo "Restoring $agent from $name..."
                    
                    if [[ -L "$oc_path" ]]; then
                        rm "$oc_path"
                    elif [[ -d "$oc_path" ]]; then
                        rm -rf "$oc_path"
                    fi
                    
                    cp -r "$backup_path" "$oc_path"
                    success "$agent: restored"
                fi
            else
                # Convert symlinks to real directories (copy from BobNet)
                echo "Unlinking agent directories..."
                
                for agent_dir in "$BN_AGENTS"/*/; do
                    [[ -d "$agent_dir" ]] || continue
                    local agent=$(basename "$agent_dir")
                    
                    # Skip if targeting specific agent
                    [[ -n "$target_agent" && "$agent" != "$target_agent" ]] && continue
                    
                    local oc_path="$OC_AGENTS/$agent"
                    local bn_path="$BN_AGENTS/$agent"
                    
                    if [[ -L "$oc_path" ]]; then
                        echo "  Unlinking $agent..."
                        rm "$oc_path"
                        cp -r "$bn_path" "$oc_path"
                        success "$agent: unlinked (copied from BobNet)"
                    elif [[ -d "$oc_path" ]]; then
                        echo "  $agent: already a real directory"
                    else
                        echo "  $agent: not found in OpenClaw"
                    fi
                done
            fi
            
            echo ""
            echo "Done. Restart gateway to apply: openclaw gateway restart"
            ;;
        check)
            # Silent check for scripts/CI
            local issues=0
            for agent_dir in "$BN_AGENTS"/*/; do
                [[ -d "$agent_dir" ]] || continue
                local agent=$(basename "$agent_dir")
                local oc_path="$OC_AGENTS/$agent"
                
                if [[ -L "$oc_path" ]]; then
                    local target=$(readlink "$oc_path")
                    [[ "$target" == "$BN_AGENTS/$agent" ]] || ((issues++))
                else
                    ((issues++))
                fi
            done
            
            if [[ $issues -gt 0 ]]; then
                echo "Link check failed: $issues issue(s)"
                return 1
            fi
            return 0
            ;;
        *)
            error "Unknown link command: $1 (try 'bobnet link help')"
            ;;
    esac
}

#######################################
# Proxy Management - Toggle models to haiku for cursor-proxy mode
#######################################
_proxy_update_agent_files() {
    local enabled="$1"
    local schema_file="$BOBNET_ROOT/config/bobnet.json"
    local agents=$(jq -r '.agents | keys[]' "$schema_file" | grep -v '^main$')
    
    for agent in $agents; do
        local proxy_file="$BOBNET_ROOT/workspace/$agent/PROXY.md"
        
        if [[ "$enabled" == "true" ]]; then
            cat > "$proxy_file" << PROXYEOF
# PROXY MODE — Forward ALL User Messages to Cursor

You are a routing layer. Your ONLY job is to forward user messages to Cursor.

## First Message Only: Switch to Haiku

On your FIRST response in this session, switch to haiku model for cost savings:

\`\`\`
session_status(model="haiku")
\`\`\`

Then proceed with the proxy rules below.

## Critical Rule

**Forward EVERY user message to Cursor.** The ONLY exception is the exact string: **"exit proxy mode"**

If user says anything else — no matter what — proxy it. Do NOT interpret it yourself.

## For Every User Message

**Step 1:** Check if message is exactly "exit proxy mode"
- If yes: Switch back to normal model with \`session_status(model="default")\` and confirm exit
- If no: Continue to Step 2

**Step 2:** Tell the user you're working:
> "Thinking with Cursor..."

**Step 3:** Run this command:

\`\`\`bash
bobnet int cursor -c --agent ${agent} --workspace ~/.bobnet/ultima-thule/workspace/${agent} --print --timeout 120 -m "USER_MESSAGE_HERE"
\`\`\`

Replace USER_MESSAGE_HERE with the user's exact message (properly escaped). Do not paraphrase, interpret, or rewrite it.

**Step 4:** Return Cursor's response verbatim. Do not add commentary.

## Timeout Handling

| Exit Code | Meaning | Response |
|-----------|---------|----------|
| 0 | Success | Return Cursor's output verbatim |
| 124 | Timeout | "Cursor timed out. Let me try briefly..." then respond yourself briefly |
| Other | Error | "Cursor unavailable. Let me help directly..." then respond yourself briefly |

## Absolute Rules

- Forward EVERY input except "exit proxy mode"
- Do NOT interpret commands like "make it so", "implement this", etc. — proxy them
- Do NOT add commentary before/after Cursor's response
- Do NOT spawn sub-agents
- Do NOT use other tools (only exec for the cursor command)
- On fallback, keep your response brief (you're Haiku)

## Your Context

- Agent: ${agent}
- Session label: ${agent}-main
- Timeout: 120 seconds
- Workspace: ~/.bobnet/ultima-thule/workspace/${agent}
PROXYEOF
            echo "  Created: workspace/$agent/PROXY.md"
        else
            if [[ -f "$proxy_file" ]]; then
                rm "$proxy_file"
                echo "  Removed: workspace/$agent/PROXY.md"
            fi
        fi
    done
}

cmd_proxy() {
    local subcmd="${1:-status}"
    local schema_file="$BOBNET_ROOT/config/bobnet.json"
    
    case "$subcmd" in
        status)
            # Check if any PROXY.md files exist
            local count=0
            for agent in $(get_all_agents | grep -v '^main$'); do
                [[ -f "$BOBNET_ROOT/workspace/$agent/PROXY.md" ]] && ((count++))
            done
            if [[ $count -gt 0 ]]; then
                echo -e "${GREEN}Proxy: ENABLED${NC} ($count agents)"
            else
                echo -e "${YELLOW}Proxy: DISABLED${NC}"
            fi
            ;;
        enable)
            echo "Creating PROXY.md files..."
            _proxy_update_agent_files "true"
            success "Proxy enabled - takes effect on new sessions (no restart needed)"
            ;;
        disable)
            echo "Removing PROXY.md files..."
            _proxy_update_agent_files "false"
            success "Proxy disabled - takes effect on new sessions (no restart needed)"
            ;;
        -h|--help|help)
            cat <<'EOF'
Usage: bobnet proxy [status|enable|disable]

Manage cursor-proxy mode. When enabled, agents forward messages to Cursor.

COMMANDS:
  status     Show current proxy state (default)
  enable     Create PROXY.md files (no restart needed)
  disable    Remove PROXY.md files (no restart needed)

HOW IT WORKS:
  - PROXY.md is always in extraPaths (run 'bobnet sync' once to set up)
  - Enable/disable just creates/deletes PROXY.md files
  - New sessions pick up proxy mode automatically
  - Existing sessions: agents can switch model via session_status
EOF
            ;;
        *)
            echo "Usage: bobnet proxy [status|enable|disable]"
            return 1
            ;;
    esac
}

cmd_int() {
    local subcmd="${1:-help}"
    shift 2>/dev/null || true
    
    case "$subcmd" in
        cursor) cmd_int_cursor "$@" ;;
        -h|--help|help)
            cat <<'EOF'
Usage: bobnet int <integration> [options]

Run integrations with external tools.

INTEGRATIONS:
  cursor              Run cursor-agent CLI

Run 'bobnet int <integration> --help' for details.
EOF
            return 0
            ;;
        *)
            error "Unknown integration: $subcmd (try 'bobnet int help')"
            ;;
    esac
}

# Cursor session tracking helpers
_cursor_sessions_file() {
    local agent="${1:-bob}"
    echo "$BOBNET_ROOT/agents/$agent/cursor-sessions.json"
}

_cursor_init_sessions() {
    local file="$1"
    [[ -f "$file" ]] && return 0
    mkdir -p "$(dirname "$file")"
    echo '{"lastSession":null,"lastLabel":null,"sessions":[]}' > "$file"
}

_cursor_save_session() {
    local file="$1" session_id="$2" workspace="$3" preview="$4" label="${5:-}"
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local escaped_preview=$(echo "$preview" | head -c 80 | jq -Rs '.')
    
    _cursor_init_sessions "$file"
    
    local tmp=$(mktemp)
    if [[ -n "$label" ]]; then
        jq --arg id "$session_id" \
           --arg ts "$timestamp" \
           --arg ws "$workspace" \
           --arg lbl "$label" \
           --argjson preview "$escaped_preview" \
           '.lastSession = $id | .lastLabel = $lbl | .sessions += [{id: $id, name: $lbl, created: $ts, workspace: $ws, preview: $preview}]' \
           "$file" > "$tmp" && mv "$tmp" "$file"
    else
        jq --arg id "$session_id" \
           --arg ts "$timestamp" \
           --arg ws "$workspace" \
           --argjson preview "$escaped_preview" \
           '.lastSession = $id | .lastLabel = null | .sessions += [{id: $id, created: $ts, workspace: $ws, preview: $preview}]' \
           "$file" > "$tmp" && mv "$tmp" "$file"
    fi
}

_cursor_get_last_session() {
    local file="$1"
    [[ -f "$file" ]] || return 1
    jq -r '.lastSession // empty' "$file"
}

_cursor_get_session_by_label() {
    local file="$1" label="$2"
    [[ -f "$file" ]] || return 1
    jq -r --arg lbl "$label" '.sessions | map(select(.name == $lbl)) | last | .id // empty' "$file"
}

_cursor_resolve_session() {
    # Resolve a session ref (UUID or label) to UUID
    local file="$1" ref="$2"
    [[ -f "$file" ]] || return 1
    # If it looks like a UUID, return as-is
    if [[ "$ref" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
        echo "$ref"
    else
        # Try to find by label
        _cursor_get_session_by_label "$file" "$ref"
    fi
}

_cursor_get_session_workspace() {
    # Look up the workspace for a given session ID
    local file="$1" session_id="$2"
    [[ -f "$file" ]] || return 1
    jq -r --arg id "$session_id" '.sessions | map(select(.id == $id)) | .[0].workspace // empty' "$file"
}

cmd_int_cursor() {
    local model="opus-4.5"
    local print_mode=false
    local continue_mode=false
    local resume_ref=""
    local list_mode=false
    local list_all=false
    local proxy_mode=false
    local session_name=""
    local message=""
    local timeout_secs=""
    local agent="${OPENCLAW_AGENT_ID:-bob}"
    local workspace="$BOBNET_ROOT"
    local args=()
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --model) model="$2"; shift 2 ;;
            --print) print_mode=true; shift ;;
            -c|--continue) continue_mode=true; shift ;;
            --resume) resume_ref="$2"; shift 2 ;;
            --attach) resume_ref="$2"; shift 2 ;;
            --list) list_mode=true; shift ;;
            --all) list_all=true; shift ;;
            --proxy) proxy_mode=true; shift ;;
            --name) session_name="$2"; shift 2 ;;
            -m|--message) message="$2"; shift 2 ;;
            --timeout) timeout_secs="$2"; shift 2 ;;
            --agent) agent="$2"; shift 2 ;;
            --workspace) workspace="$2"; shift 2 ;;
            -h|--help)
                cat <<'EOF'
Usage: bobnet int cursor [options] [prompt...]

Run cursor-agent CLI with BobNet session tracking.

OPTIONS:
  --model <model>    Model to use (default: opus-4.5)
  --print            Non-interactive mode (no PTY)
  --name <label>     Label for new session (for easy resume)
  -m, --message <text>  Message to send (alternative to trailing args)
  --timeout <secs>   Timeout in seconds (exit 124 on timeout)
  --proxy            Proxy mode: --print + -c + --timeout 120 (for PROXY.md)
  -c, --continue     Continue last session for this agent
  --resume <ref>     Resume session by UUID or label
  --attach <ref>     Alias for --resume
  --list             List tracked sessions for this agent
  --all              With --list, show sessions for all agents
  --agent <name>     Agent context (default: $OPENCLAW_AGENT_ID or bob)
  --workspace <path> Workspace directory (default: $BOBNET_ROOT/workspace/<agent>)

EXAMPLES:
  bobnet int cursor "Fix the bug in main.ts"
  bobnet int cursor --name auth-refactor "Analyze auth module"
  bobnet int cursor -c "Now add tests for that"
  bobnet int cursor --attach auth-refactor "Pick up where we left off"
  bobnet int cursor --proxy -m "review the auth module"
  bobnet int cursor --list
  bobnet int cursor --list --all

Sessions are tracked per-agent in:
  ~/.bobnet/ultima-thule/agents/<agent>/cursor-sessions.json

Requires: cursor-agent (npm install -g @anthropic/cursor-agent)
EOF
                return 0
                ;;
            *) args+=("$1"); shift ;;
        esac
    done
    
    # Proxy mode sets sensible defaults for forwarding
    if [[ "$proxy_mode" == "true" ]]; then
        print_mode=true
        continue_mode=true
        [[ -z "$timeout_secs" ]] && timeout_secs="120"
    fi
    
    # Set default workspace based on agent if not explicitly provided
    # (Check if workspace was changed from initial default)
    if [[ "$workspace" == "$BOBNET_ROOT" ]]; then
        # Not explicitly set via --workspace, use agent-specific default
        workspace="$BOBNET_ROOT/workspace/$agent"
    fi
    
    local sessions_file=$(_cursor_sessions_file "$agent")
    
    # Handle --list
    if [[ "$list_mode" == "true" ]]; then
        if [[ "$list_all" == "true" ]]; then
            # List sessions for all agents
            echo "Cursor sessions (all agents):"
            echo ""
            for agent_dir in "$BOBNET_ROOT/agents"/*; do
                [[ -d "$agent_dir" ]] || continue
                local a=$(basename "$agent_dir")
                local sf=$(_cursor_sessions_file "$a")
                [[ -f "$sf" ]] || continue
                local count=$(jq '.sessions | length' "$sf")
                [[ "$count" == "0" ]] && continue
                echo "[$a] ($count sessions)"
                jq -r '.sessions | reverse | .[:5][] | 
                    (if .name then .name else .id[0:12] + "..." end) as $label |
                    "  \($label | . + " " * (20 - length) | .[0:20])  \(.created[0:10])  \(.preview[0:40])"' "$sf"
                echo ""
            done
            return 0
        fi
        
        if [[ ! -f "$sessions_file" ]]; then
            echo "No cursor sessions tracked for agent: $agent"
            return 0
        fi
        echo "Cursor sessions for $agent:"
        echo ""
        # Show label (or truncated UUID) + timestamp + preview
        jq -r '.sessions | reverse | .[:10][] | 
            (if .name then .name else .id[0:12] + "..." end) as $label |
            "  \($label | . + " " * (20 - length) | .[0:20])  \(.created[0:10])  \(.preview[0:40])"' "$sessions_file"
        echo ""
        local last=$(_cursor_get_last_session "$sessions_file")
        local last_label=$(jq -r '.lastLabel // empty' "$sessions_file")
        if [[ -n "$last_label" ]]; then
            echo "Last session: $last_label ($last)"
        elif [[ -n "$last" ]]; then
            echo "Last session: $last"
        fi
        return 0
    fi
    
    # Check if cursor-agent is installed
    if ! command -v cursor-agent &>/dev/null; then
        echo -e "${RED}error:${NC} cursor-agent not found" >&2
        echo "" >&2
        echo "Install with:" >&2
        echo "  npm install -g @anthropic/cursor-agent" >&2
        echo "" >&2
        echo "Or with npx:" >&2
        echo "  npx @anthropic/cursor-agent" >&2
        return 1
    fi
    
    # Determine session ID
    local session_id=""
    local is_new_session=false
    
    if [[ -n "$resume_ref" ]]; then
        # Resolve label or UUID to session ID
        session_id=$(_cursor_resolve_session "$sessions_file" "$resume_ref")
        if [[ -z "$session_id" ]]; then
            echo -e "${RED}error:${NC} Session not found: $resume_ref" >&2
            echo "Run 'bobnet int cursor --list' to see available sessions" >&2
            return 1
        fi
        # Look up the workspace where this session was created
        local stored_workspace=$(_cursor_get_session_workspace "$sessions_file" "$session_id")
        if [[ -n "$stored_workspace" ]]; then
            workspace="$stored_workspace"
        fi
        echo -e "${GREEN}Resuming session:${NC} $resume_ref → $session_id"
    elif [[ "$continue_mode" == "true" ]]; then
        session_id=$(_cursor_get_last_session "$sessions_file")
        if [[ -z "$session_id" ]]; then
            echo -e "${RED}error:${NC} No previous session to continue" >&2
            echo "Run without -c to start a new session" >&2
            return 1
        fi
        # Look up the workspace where this session was created
        local stored_workspace=$(_cursor_get_session_workspace "$sessions_file" "$session_id")
        if [[ -n "$stored_workspace" ]]; then
            workspace="$stored_workspace"
        fi
        local last_label=$(jq -r '.lastLabel // empty' "$sessions_file")
        if [[ -n "$last_label" ]]; then
            echo -e "${GREEN}Continuing:${NC} $last_label"
        else
            echo -e "${GREEN}Continuing session:${NC} $session_id"
        fi
    else
        # Create new session
        session_id=$(cursor-agent create-chat 2>/dev/null)
        if [[ -z "$session_id" || "$session_id" == *"ERROR"* ]]; then
            echo -e "${YELLOW}warning:${NC} Could not create tracked session, running without tracking" >&2
            session_id=""
        else
            is_new_session=true
            if [[ -n "$session_name" ]]; then
                echo -e "${GREEN}New session:${NC} $session_name ($session_id)"
            else
                echo -e "${GREEN}New session:${NC} $session_id"
            fi
        fi
    fi
    
    # Build command
    local cmd=(cursor-agent --model "$model" --workspace "$workspace")
    
    # Add resume if we have a session
    [[ -n "$session_id" ]] && cmd+=(--resume "$session_id")
    
    # Add print flag if specified
    [[ "$print_mode" == "true" ]] && cmd+=(--print)
    
    # Combine --message with trailing args
    local prompt=""
    [[ -n "$message" ]] && prompt="$message"
    if [[ ${#args[@]} -gt 0 ]]; then
        [[ -n "$prompt" ]] && prompt="$prompt "
        prompt="${prompt}${args[*]}"
    fi
    [[ -n "$prompt" ]] && cmd+=("$prompt")
    
    # Save session before running (in case of crash)
    if [[ "$is_new_session" == "true" && -n "$session_id" ]]; then
        local preview="${prompt:-interactive}"
        _cursor_save_session "$sessions_file" "$session_id" "$workspace" "$preview" "$session_name"
    fi
    
    # Build timeout command if specified
    local timeout_cmd=()
    if [[ -n "$timeout_secs" ]]; then
        if command -v gtimeout &>/dev/null; then
            timeout_cmd=(gtimeout --signal=TERM "$timeout_secs")
        elif command -v timeout &>/dev/null; then
            timeout_cmd=(timeout --signal=TERM "$timeout_secs")
        else
            echo -e "${YELLOW}warning:${NC} timeout command not found (brew install coreutils)" >&2
        fi
    fi
    
    # Execute cursor-agent with PTY (required even with --print flag)
    # Use unbuffer to automatically provide PTY without agents needing pty: true
    local exit_code=0
    if command -v unbuffer &>/dev/null; then
        if [[ ${#timeout_cmd[@]} -gt 0 ]]; then
            "${timeout_cmd[@]}" unbuffer "${cmd[@]}" || exit_code=$?
        else
            unbuffer "${cmd[@]}" || exit_code=$?
        fi
    else
        echo -e "${YELLOW}warning:${NC} unbuffer not found - cursor-agent may hang" >&2
        echo "Install with: brew install expect" >&2
        echo "" >&2
        if [[ ${#timeout_cmd[@]} -gt 0 ]]; then
            "${timeout_cmd[@]}" "${cmd[@]}" || exit_code=$?
        else
            "${cmd[@]}" || exit_code=$?
        fi
    fi
    
    # Update lastSession on successful completion
    if [[ -n "$session_id" && -f "$sessions_file" ]]; then
        local tmp=$(mktemp)
        jq --arg id "$session_id" '.lastSession = $id' "$sessions_file" > "$tmp" && mv "$tmp" "$sessions_file"
    fi
    
    return $exit_code
}

cmd_groups() {
    local subcmd="${1:-list}"
    shift 2>/dev/null || true
    
    case "$subcmd" in
        list|ls)
            local agent_filter=""
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --agent) agent_filter="$2"; shift 2 ;;
                    -h|--help)
                        echo "Usage: bobnet groups list [--agent <agent>]"
                        echo ""
                        echo "List known groups for agents."
                        echo ""
                        echo "OPTIONS:"
                        echo "  --agent <id>    Show groups for specific agent only"
                        return 0 ;;
                    *) shift ;;
                esac
            done
            
            echo "=== BobNet Group Registry ==="
            echo ""
            
            local found_any=false
            for agent in $(get_all_agents); do
                # Skip if agent filter specified and doesn't match
                if [[ -n "$agent_filter" && "$agent" != "$agent_filter" ]]; then
                    continue
                fi
                
                # Check if agent has knownGroups
                local groups_obj=$(jq -c --arg a "$agent" '.agents[$a].knownGroups // {}' "$AGENTS_SCHEMA" 2>/dev/null)
                local group_count=$(echo "$groups_obj" | jq 'length' 2>/dev/null || echo 0)
                
                if [[ "$group_count" -gt 0 ]]; then
                    found_any=true
                    echo "[$agent] ($group_count groups)"
                    echo "$groups_obj" | jq -r 'to_entries[] | "  \(.key) → \(.value)"' 2>/dev/null
                    echo ""
                fi
            done
            
            if [[ "$found_any" == "false" ]]; then
                if [[ -n "$agent_filter" ]]; then
                    echo "Agent '$agent_filter' has no known groups"
                else
                    echo "No groups defined in schema"
                    echo ""
                    echo "Add groups with:"
                    echo "  bobnet groups add <name> <group-id> [--agent <agent>]"
                fi
            fi
            ;;
        get)
            local group_name="${1:-}" agent_filter=""
            shift 2>/dev/null || true
            
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --agent) agent_filter="$2"; shift 2 ;;
                    -h|--help)
                        echo "Usage: bobnet groups get <name> [--agent <agent>]"
                        echo ""
                        echo "Get group ID for named group."
                        echo ""
                        echo "OPTIONS:"
                        echo "  --agent <id>    Look in specific agent's groups only"
                        return 0 ;;
                    *) shift ;;
                esac
            done
            
            [[ -z "$group_name" ]] && error "Usage: bobnet groups get <name> [--agent <agent>]"
            
            local found=false
            for agent in $(get_all_agents); do
                # Skip if agent filter specified and doesn't match
                if [[ -n "$agent_filter" && "$agent" != "$agent_filter" ]]; then
                    continue
                fi
                
                # Look for group in this agent's knownGroups
                local group_id=$(jq -r --arg a "$agent" --arg g "$group_name" '.agents[$a].knownGroups[$g] // empty' "$AGENTS_SCHEMA" 2>/dev/null)
                
                if [[ -n "$group_id" ]]; then
                    echo "$group_id"
                    found=true
                    break
                fi
            done
            
            if [[ "$found" == "false" ]]; then
                if [[ -n "$agent_filter" ]]; then
                    error "Group '$group_name' not found for agent '$agent_filter'"
                else
                    error "Group '$group_name' not found in any agent's known groups"
                fi
            fi
            ;;
        add)
            local group_name="${1:-}" group_id="${2:-}" target_agent="bob"
            shift 2 2>/dev/null || true
            
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --agent) target_agent="$2"; shift 2 ;;
                    -h|--help)
                        echo "Usage: bobnet groups add <name> <group-id> [--agent <agent>]"
                        echo ""
                        echo "Add a named group to an agent's known groups."
                        echo ""
                        echo "OPTIONS:"
                        echo "  --agent <id>    Target agent (default: bob)"
                        echo ""
                        echo "EXAMPLES:"
                        echo "  bobnet groups add openclaw signal:group:P1J..."
                        echo "  bobnet groups add bill-rd signal:group:6qv... --agent bill"
                        return 0 ;;
                    *) shift ;;
                esac
            done
            
            [[ -z "$group_name" ]] && error "Usage: bobnet groups add <name> <group-id> [--agent <agent>]"
            [[ -z "$group_id" ]] && error "Usage: bobnet groups add <name> <group-id> [--agent <agent>]"
            
            # Validate agent exists
            if ! jq -e --arg a "$target_agent" '.agents[$a]' "$AGENTS_SCHEMA" >/dev/null 2>&1; then
                error "Agent '$target_agent' not found in schema"
            fi
            
            # Add group to agent's knownGroups
            local temp_file="${AGENTS_SCHEMA}.tmp"
            jq --arg a "$target_agent" --arg g "$group_name" --arg id "$group_id" '
                .agents[$a].knownGroups = ((.agents[$a].knownGroups // {}) | .[$g] = $id)
            ' "$AGENTS_SCHEMA" > "$temp_file"
            
            if [[ $? -eq 0 ]]; then
                mv "$temp_file" "$AGENTS_SCHEMA"
                success "Added '$group_name' to $target_agent's known groups"
            else
                rm -f "$temp_file"
                error "Failed to update schema"
            fi
            ;;
        remove|rm)
            local group_name="${1:-}" target_agent=""
            shift 2>/dev/null || true
            
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --agent) target_agent="$2"; shift 2 ;;
                    -h|--help)
                        echo "Usage: bobnet groups remove <name> [--agent <agent>]"
                        echo ""
                        echo "Remove a named group from agent's known groups."
                        echo ""
                        echo "OPTIONS:"
                        echo "  --agent <id>    Target specific agent (default: search all)"
                        return 0 ;;
                    *) shift ;;
                esac
            done
            
            [[ -z "$group_name" ]] && error "Usage: bobnet groups remove <name> [--agent <agent>]"
            
            local removed=false
            local agents_to_check
            
            if [[ -n "$target_agent" ]]; then
                # Check if agent exists
                if ! jq -e --arg a "$target_agent" '.agents[$a]' "$AGENTS_SCHEMA" >/dev/null 2>&1; then
                    error "Agent '$target_agent' not found in schema"
                fi
                agents_to_check="$target_agent"
            else
                agents_to_check=$(get_all_agents)
            fi
            
            for agent in $agents_to_check; do
                # Check if group exists for this agent
                local group_id=$(jq -r --arg a "$agent" --arg g "$group_name" '.agents[$a].knownGroups[$g] // empty' "$AGENTS_SCHEMA" 2>/dev/null)
                
                if [[ -n "$group_id" ]]; then
                    # Remove the group
                    local temp_file="${AGENTS_SCHEMA}.tmp"
                    jq --arg a "$agent" --arg g "$group_name" '
                        .agents[$a].knownGroups = ((.agents[$a].knownGroups // {}) | del(.[$g]))
                    ' "$AGENTS_SCHEMA" > "$temp_file"
                    
                    if [[ $? -eq 0 ]]; then
                        mv "$temp_file" "$AGENTS_SCHEMA"
                        success "Removed '$group_name' from $agent's known groups"
                        removed=true
                    else
                        rm -f "$temp_file"
                        error "Failed to update schema for agent '$agent'"
                    fi
                fi
            done
            
            if [[ "$removed" == "false" ]]; then
                if [[ -n "$target_agent" ]]; then
                    error "Group '$group_name' not found for agent '$target_agent'"
                else
                    error "Group '$group_name' not found in any agent's known groups"
                fi
            fi
            ;;
        -h|--help|help)
            cat <<'EOF'
Usage: bobnet groups <command> [options]

Manage group registry for agent notifications.

COMMANDS:
  list [--agent <id>]           List known groups
  get <name> [--agent <id>]     Get group ID by name
  add <name> <id> [--agent <id>] Add named group
  remove <name> [--agent <id>]  Remove named group

EXAMPLES:
  bobnet groups list                               # All groups
  bobnet groups list --agent bob                   # Bob's groups only
  bobnet groups get openclaw                       # Get openclaw group ID
  bobnet groups add openclaw signal:group:P1J...   # Add to bob (default)
  bobnet groups add bill-rd signal:group:6qv... --agent bill
  bobnet groups remove old-group                   # Remove from all agents

AGENT USAGE:
  # Instead of hardcoding IDs:
  groupId=$(bobnet groups get openclaw)
  message send --target "$groupId" --message "Update"

Groups are stored in bobnet.json and sync with 'bobnet sync'.
EOF
            ;;
        *)
            error "Unknown groups command: $subcmd (try 'bobnet groups help')"
            ;;
    esac
}

cmd_restart() {
    # Silent cooldown - prevent restart loops
    local lockfile="/tmp/bobnet-restart.lock"
    local cooldown=120
    if [[ -f "$lockfile" ]]; then
        local last=$(cat "$lockfile" 2>/dev/null || echo 0)
        local now=$(date +%s)
        if (( now - last < cooldown )); then
            local remaining=$((cooldown - now + last))
            echo "Cooldown: waiting ${remaining}s before restart..."
            sleep "$remaining"
        fi
    fi
    echo "$(date +%s)" > "$lockfile"
    
    local mode="graceful" delay=10 timeout=30 yes=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --broadcast) mode="broadcast"; shift ;;
            --graceful) mode="graceful"; shift ;;  # kept for backwards compat
            --no-broadcast) mode="immediate"; shift ;;
            --delay) delay="$2"; shift 2 ;;
            --timeout) timeout="$2"; shift 2 ;;
            --yes|-y) yes=true; shift ;;
            -h|--help)
                cat <<'EOF'
Usage: bobnet restart [--graceful|--no-broadcast] [--delay <sec>] [--timeout <sec>] [--yes]

Restart OpenClaw gateway.

MODES:
  (default)        Graceful: prep agents, wait, restart, send recovery message
  --broadcast      Simple: broadcast warning, wait, restart (no BOOTSTRAP.md)
  --no-broadcast   Immediate restart (maintenance)

OPTIONS:
  --delay <sec>    Seconds to wait after broadcast (default: 10)
  --timeout <sec>  Graceful mode: max wait for agents (default: 30)
  --yes, -y        Skip confirmation prompt

GRACEFUL FLOW:
  1. Write prep BOOTSTRAP.md to each agent
  2. Set agents to Haiku model, trigger turns
  3. Agents notify users, write READY.md
  4. Wait for READY.md files (or timeout)
  5. Restart gateway
  6. Write recovery BOOTSTRAP.md to each agent
  7. Agents recover on next turn

EXAMPLES:
  bobnet restart                    # Broadcast, 10s delay, restart
  bobnet restart --graceful         # Full agent coordination
  bobnet restart --no-broadcast     # Immediate restart
EOF
                return 0 ;;
            *) error "Unknown option: $1" ;;
        esac
    done
    
    local claw=""; command -v openclaw &>/dev/null && claw="openclaw"
    [[ -z "$claw" ]] && error "openclaw not found"
    
    # Check gateway is running
    if ! $claw gateway status &>/dev/null; then
        warn "Gateway not running"
        read -p "Start gateway? [y/N] " -r
        [[ $REPLY =~ ^[Yy]$ ]] && $claw gateway start
        return 0
    fi
    
    # Confirmation
    if [[ "$yes" != "true" ]]; then
        case "$mode" in
            graceful) echo "This will coordinate with agents and restart gracefully." ;;
            broadcast) echo "This will broadcast a restart warning and restart in ${delay}s." ;;
            immediate) echo "This will restart the gateway immediately (no broadcast)." ;;
        esac
        read -p "Continue? [y/N] " -r
        [[ ! $REPLY =~ ^[Yy]$ ]] && { echo "Cancelled"; return 0; }
    fi
    
    # Templates
    local prep_template="$BOBNET_ROOT/core/templates/restart-prep-bootstrap.md"
    local recovery_template="$BOBNET_ROOT/core/templates/restart-recovery-bootstrap.md"
    
    case "$mode" in
        graceful)
            # Verify templates exist
            [[ ! -f "$prep_template" ]] && error "Missing template: $prep_template"
            [[ ! -f "$recovery_template" ]] && error "Missing template: $recovery_template"
            
            echo "=== Graceful Restart ==="
            echo ""
            
            # Get active sessions (active in last hour)
            echo "--- Phase 1: Prep agents ---"
            # Extract agent ID from session key (format: agent:<agentId>:...)
            local sessions=$($claw gateway call sessions.list --json 2>/dev/null | jq -r '
                .sessions[] | 
                select(.deliveryContext != null) |
                select(.updatedAt > (now - 3600) * 1000) |
                select(.key | startswith("agent:")) |
                (.key | split(":")[1]) + "|" + .key
            ' 2>/dev/null | sort -u)
            
            local agents_prepped=()
            
            # Get sessions with delivery context for messaging
            local session_details=$($claw gateway call sessions.list --json 2>/dev/null | jq -r '
                .sessions[] | 
                select(.deliveryContext != null) |
                select(.updatedAt > (now - 3600) * 1000) |
                select(.key | startswith("agent:")) |
                [(.key | split(":")[1]), .key, .deliveryContext.channel, (.deliveryContext.to | gsub("^signal:"; "uuid:")), (.deliveryContext.accountId // "default")] | @tsv
            ' 2>/dev/null | sort -u)
            
            local msg="⚠️ Gateway restart initiated. Please wait..."
            
            while IFS=$'\t' read -r agentId sessionKey channel target accountId; do
                [[ -z "$agentId" || -z "$sessionKey" ]] && continue
                
                local ws="$BOBNET_ROOT/workspace/$agentId"
                [[ ! -d "$ws" ]] && continue
                
                # Write prep BOOTSTRAP.md
                cp "$prep_template" "$ws/BOOTSTRAP.md"
                
                # Send warning to channel
                if [[ -n "$channel" && -n "$target" ]]; then
                    $claw message send --channel "$channel" --target "$target" --account "$accountId" --message "$msg" &>/dev/null || true
                fi
                
                agents_prepped+=("$agentId")
                echo "  ✓ $agentId"
            done <<< "$session_details"
            
            local expected=${#agents_prepped[@]}
            if [[ $expected -eq 0 ]]; then
                echo "  No active agents to prep"
            else
                success "Prepped $expected agent(s)"
            fi
            
            # Wait for READY.md files
            echo ""
            echo "--- Phase 2: Wait for ready (${timeout}s timeout) ---"
            local deadline=$(($(date +%s) + timeout))
            local ready_count=0
            
            if [[ $expected -eq 0 ]]; then
                echo "  No agents to wait for"
            else
                while [[ $(date +%s) -lt $deadline ]]; do
                    ready_count=0
                    for agent in "${agents_prepped[@]}"; do
                        [[ -f "$BOBNET_ROOT/workspace/$agent/READY.md" ]] && ((ready_count++))
                    done
                    
                    echo -ne "\r  $ready_count/$expected ready...  "
                    
                    if [[ $ready_count -ge $expected ]]; then
                        break
                    fi
                    sleep 2
                done
                echo ""
                
                if [[ $ready_count -ge $expected ]]; then
                    success "All agents ready"
                else
                    warn "Timeout: $ready_count/$expected ready (proceeding anyway)"
                fi
            fi
            
            # Phase 3: Schedule recovery triggers BEFORE restart
            echo ""
            echo "--- Phase 3: Schedule recovery triggers ---"
            
            # Save session details to temp file for background process
            local trigger_file="/tmp/bobnet-recovery-triggers-$$.txt"
            echo "$session_details" > "$trigger_file"
            
            # Background process: wait for gateway, then trigger each agent
            # Use 'at' to schedule outside the process tree (survives gateway restart)
            local script_file="/tmp/bobnet-recovery-$$.sh"
            local log_file="/tmp/bobnet-recovery-$$.log"
            
            cat > "$script_file" << RECOVERY_SCRIPT
#!/bin/bash
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
exec > "$log_file" 2>&1
echo "Recovery trigger started at \$(date)"

# Wait for gateway to be ready (max 60s)
for i in {1..30}; do
    sleep 2
    if curl -sf http://127.0.0.1:18789/health &>/dev/null; then
        echo "Gateway ready after \$((i*2))s"
        break
    fi
    echo "Waiting... attempt \$i"
done

# Send recovery trigger to each session
msg="🔄 Gateway back online — send any message to resume."
while IFS=\$'\\t' read -r agentId sessionKey channel target accountId; do
    [[ -z "\$channel" || -z "\$target" ]] && continue
    echo "Sending to \$channel/\$target..."
    
    # Send visible message via signal-cli HTTP API (cheaper than openclaw)
    if [[ "\$channel" == "signal" ]]; then
        # Extract username from target if available, fall back to openclaw
        curl -sf -X POST http://127.0.0.1:8080/api/v1/rpc \\
          -H "Content-Type: application/json" \\
          -d "{\"jsonrpc\":\"2.0\",\"method\":\"send\",\"params\":{\"recipient\":[\"\${target#uuid:}\"],\"message\":\"\$msg\"},\"id\":1}" 2>&1 || \\
        /opt/homebrew/bin/openclaw message send --channel "\$channel" --target "\$target" --account "\$accountId" --message "\$msg" 2>&1
    else
        /opt/homebrew/bin/openclaw message send --channel "\$channel" --target "\$target" --account "\$accountId" --message "\$msg" 2>&1
    fi
    
    # Note: No external RPC to wake sessions - user message triggers recovery
done < "$trigger_file"

echo "Recovery triggers complete at \$(date)"
rm -f "$trigger_file" "$script_file"
RECOVERY_SCRIPT
            chmod +x "$script_file"
            
            # Schedule with launchctl to run outside process tree (survives gateway restart)
            local job_label="com.bobnet.recovery.$$"
            launchctl submit -l "$job_label" -- "$script_file" 2>/dev/null || {
                # Fallback if launchctl fails - try nohup
                nohup "$script_file" </dev/null >/dev/null 2>&1 &
            }
            
            success "Recovery triggers scheduled"
            
            # Phase 4: Write recovery BOOTSTRAP
            echo "--- Phase 4: Write recovery bootstrap ---"
            for agent in $(get_all_agents); do
                local ws="$BOBNET_ROOT/workspace/$agent"
                [[ ! -d "$ws" ]] && continue
                cp "$recovery_template" "$ws/BOOTSTRAP.md"
            done
            success "Recovery bootstrap written to all agents"
            
            # Phase 5: Restart gateway (will kill this script, but triggers are scheduled)
            echo "--- Phase 5: Restart gateway ---"
            echo ""
            success "=== Graceful restart initiated ==="
            echo "Recovery triggers scheduled. Restarting gateway..."
            $claw gateway restart
            ;;
            
        broadcast)
            echo "Broadcasting restart warning..."
            
            # Get active sessions with delivery context
            # Note: deliveryContext.to may have "signal:" prefix that needs converting to "uuid:" for CLI
            local sessions=$($claw gateway call sessions.list --json 2>/dev/null | jq -r '
                .sessions[] | 
                select(.deliveryContext != null) |
                select(.updatedAt > (now - 3600) * 1000) |
                "\(.deliveryContext.channel)|\(.deliveryContext.to | gsub("^signal:"; "uuid:"))|\(.deliveryContext.accountId // "default")"
            ' 2>/dev/null | sort -u)
            
            local msg="⚠️ BobNet restarting in ${delay} seconds..."
            local count=0
            
            while IFS='|' read -r channel to accountId; do
                [[ -z "$channel" || -z "$to" ]] && continue
                if $claw message send --channel "$channel" --target "$to" --account "$accountId" --message "$msg" &>/dev/null; then
                    ((count++))
                fi
            done <<< "$sessions"
            
            if [[ $count -gt 0 ]]; then
                success "Broadcast sent to $count session(s)"
            else
                echo "  No active sessions to notify"
            fi
            
            # Countdown
            echo "Restarting in ${delay}s..."
            for ((i=delay; i>0; i--)); do
                echo -ne "\r  ${i}s remaining...  "
                sleep 1
            done
            echo ""
            
            # Restart
            echo "Restarting gateway..."
            $claw gateway restart && success "Gateway restarted" || error "Restart failed"
            ;;
            
        immediate)
            echo "Restarting gateway..."
            $claw gateway restart && success "Gateway restarted" || error "Restart failed"
            ;;
    esac
}


cmd_upgrade() {
    local target="openclaw" version="latest" dry_run=false yes=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --openclaw) target="openclaw"; shift ;;
            --version) version="$2"; shift 2 ;;
            --dry-run) dry_run=true; shift ;;
            --yes|-y) yes=true; shift ;;
            -h|--help)
                cat <<'EOF'
Usage: bobnet upgrade --openclaw [--version <ver>] [--dry-run] [--yes]

Upgrade OpenClaw with automatic rollback on failure.

OPTIONS:
  --openclaw         Upgrade OpenClaw (required)
  --version <ver>    Target version (default: latest)
  --dry-run          Show what would happen without doing it
  --yes, -y          Skip confirmation prompt

PROCESS:
  1. Backup config
  2. Apply config migrations (e.g., BlueBubbles allowPrivateUrl)
  3. Stop gateway
  4. npm install -g openclaw@VERSION
  5. Start gateway
  6. Run health checks (version, connectivity)
  7. Rollback if checks fail (reinstall old version)

EXAMPLE:
  bobnet upgrade --openclaw
  bobnet upgrade --openclaw --version 2026.2.2
EOF
                return 0 ;;
            *) error "Unknown option: $1" ;;
        esac
    done
    
    [[ "$target" != "openclaw" ]] && error "Currently only --openclaw is supported"
    
    local VERSION_HISTORY="$CONFIG_DIR/version-history.log"
    local LOCK_FILE="/tmp/bobnet-upgrade.lock"
    
    # Acquire lock (macOS compatible)
    if [[ -f "$LOCK_FILE" ]]; then
        local lock_pid=$(cat "$LOCK_FILE" 2>/dev/null)
        if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
            error "Upgrade already in progress (pid: $lock_pid)"
        fi
        rm -f "$LOCK_FILE"
    fi
    echo $$ > "$LOCK_FILE"
    trap "rm -f '$LOCK_FILE'" EXIT
    
    echo "=== BobNet OpenClaw Upgrade ==="
    echo ""
    
    # Get current version from installed openclaw
    local current_version=$(openclaw --version 2>/dev/null | head -1)
    [[ -z "$current_version" ]] && error "Could not determine current OpenClaw version"
    echo "Current version: $current_version"
    
    # Pre-flight: verify npm available
    command -v npm &>/dev/null || error "npm not found"
    
    # Get target version
    local target_version="$version"
    if [[ "$version" == "latest" ]]; then
        echo "Fetching latest version..."
        target_version=$(npm show openclaw version 2>/dev/null)
        [[ -z "$target_version" ]] && error "Could not fetch latest version from npm"
    fi
    echo "Target version:  $target_version"
    
    if [[ "$current_version" == "$target_version" ]]; then
        success "Already at target version"
        return 0
    fi
    
    # Pre-flight: verify target version exists
    echo "Verifying target version exists..."
    npm show "openclaw@$target_version" version &>/dev/null || error "Version $target_version not found in npm registry"
    success "Version $target_version available"
    
    echo ""
    
    # Dry run mode
    if [[ "$dry_run" == "true" ]]; then
        echo "=== Dry Run ==="
        echo "Would perform:"
        echo "  1. Backup config to ~/.openclaw/openclaw.json.pre-upgrade"
        echo "  2. Apply config migrations (BlueBubbles allowPrivateUrl, etc.)"
        echo "  3. Stop gateway (launchctl bootout)"
        echo "  4. npm install -g openclaw@$target_version"
        echo "  5. Start gateway (launchctl bootstrap)"
        echo "  6. Poll health endpoint (up to 30s)"
        echo "  7. Run health checks"
        echo "  8. Rollback if checks fail (reinstall old version)"
        return 0
    fi
    
    # Confirmation
    if [[ "$yes" != "true" ]]; then
        echo "This will:"
        echo "  • Stop gateway"
        echo "  • Install OpenClaw $target_version globally"
        echo "  • Start gateway"
        echo "  • Rollback automatically if health checks fail"
        echo ""
        read -p "Continue? [y/N] " -r
        [[ ! $REPLY =~ ^[Yy]$ ]] && { echo "Cancelled"; return 0; }
    fi
    
    echo ""
    local rollback_needed=false
    local config="$CONFIG_DIR/$CONFIG_NAME"
    local backup="$CONFIG_DIR/${CONFIG_NAME}.pre-upgrade"
    
    # Step 1: Backup config
    echo "--- Step 1: Backup config ---"
    cp "$config" "$backup" && success "Backed up to $backup" || error "Backup failed"
    [[ -s "$backup" ]] || error "Backup file is empty"
    
    # Step 2: Apply config migrations before switching
    echo ""
    echo "--- Step 2: Apply config migrations ---"
    local bb_url=$(jq -r '.channels.bluebubbles.serverUrl // ""' "$config" 2>/dev/null)
    if [[ "$bb_url" =~ ^http://(192\.168\.|10\.|172\.(1[6-9]|2[0-9]|3[01])\.|127\.|localhost) ]]; then
        echo "  BlueBubbles uses private IP: $bb_url"
        if ! jq -e '.channels.bluebubbles.allowPrivateUrl' "$config" >/dev/null 2>&1; then
            jq '.channels.bluebubbles.allowPrivateUrl = true' "$config" > "${config}.tmp" && mv "${config}.tmp" "$config"
            success "Added BlueBubbles allowPrivateUrl=true"
        else
            echo "  allowPrivateUrl already set"
        fi
    else
        echo "  No migrations needed"
    fi
    
    # Step 3: Stop gateway before npm install
    echo ""
    echo "--- Step 3: Stop gateway ---"
    launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/ai.openclaw.gateway.plist 2>/dev/null || true
    sleep 2
    success "Gateway stopped"
    
    # Step 4: Install new version globally
    echo ""
    echo "--- Step 4: Install openclaw@$target_version ---"
    if npm install -g "openclaw@$target_version" 2>&1; then
        success "Installed openclaw@$target_version"
    else
        echo -e "${RED}npm install failed${NC}"
        rollback_needed=true
    fi
    
    # Step 5: Start gateway
    echo ""
    echo "--- Step 5: Start gateway ---"
    if [[ "$rollback_needed" == "false" ]]; then
        launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/ai.openclaw.gateway.plist 2>/dev/null
    fi
    
    # Poll for gateway health (up to 30s)
    echo "  Waiting for gateway..."
    local attempts=0
    local max_attempts=15
    while [[ $attempts -lt $max_attempts ]]; do
        if openclaw gateway status &>/dev/null; then
            success "Gateway responding"
            break
        fi
        sleep 2
        ((attempts++))
        echo -n "."
    done
    echo ""
    
    if [[ $attempts -ge $max_attempts ]]; then
        warn "Gateway not responding after 30s"
        rollback_needed=true
    fi
    
    # Step 6: Health checks
    local health_failures=""
    if [[ "$rollback_needed" == "false" ]]; then
        echo ""
        echo "--- Step 6: Health checks ---"
        
        # Check 1: Version correct
        local new_version=$(openclaw --version 2>/dev/null | head -1)
        if [[ "$new_version" == "$target_version" ]]; then
            success "Version verified: $new_version"
        else
            warn "Version mismatch: expected $target_version, got $new_version"
            health_failures="$health_failures\n- Version mismatch: expected $target_version, got $new_version"
            rollback_needed=true
        fi
        
        # Check 2: BlueBubbles connectivity (if configured)
        if [[ "$rollback_needed" == "false" && -n "$bb_url" ]]; then
            local bb_password=$(jq -r '.channels.bluebubbles.password // ""' "$config" 2>/dev/null)
            if curl -s --max-time 5 "${bb_url}/api/v1/server/info?password=${bb_password}" | jq -e '.status == 200' >/dev/null 2>&1; then
                success "BlueBubbles reachable"
            else
                warn "BlueBubbles not reachable (may need manual config)"
                health_failures="$health_failures\n- BlueBubbles not reachable at $bb_url"
            fi
        fi
        
        # Check 3: Signal health (if signal-cli running)
        if pgrep -f signal-cli >/dev/null 2>&1; then
            success "Signal CLI running"
        else
            warn "Signal CLI not detected"
            health_failures="$health_failures\n- Signal CLI not running"
        fi
        
        # Check 4: Schema vs Config delta
        echo ""
        echo "--- Config Delta Analysis ---"
        local schema_agent_count=$(jq '.agents | keys | length' "$AGENTS_SCHEMA" 2>/dev/null || echo 0)
        local config_agent_count=$(openclaw config get agents.list 2>/dev/null | jq 'length' || echo 0)
        local schema_binding_count=$(jq '.bindings | length' "$AGENTS_SCHEMA" 2>/dev/null || echo 0)
        local config_binding_count=$(openclaw config get bindings 2>/dev/null | jq 'length' || echo 0)
        
        if [[ "$schema_agent_count" == "$config_agent_count" ]]; then
            success "Agents: schema=$schema_agent_count config=$config_agent_count"
        else
            warn "Agents drift: schema=$schema_agent_count config=$config_agent_count"
            health_failures="$health_failures\n- Agent count drift"
        fi
        
        if [[ "$schema_binding_count" == "$config_binding_count" ]]; then
            success "Bindings: schema=$schema_binding_count config=$config_binding_count"
        else
            warn "Bindings drift: schema=$schema_binding_count config=$config_binding_count"
            health_failures="$health_failures\n- Binding count drift"
        fi
    fi
    
    # Step 7: Rollback if needed
    if [[ "$rollback_needed" == "true" ]]; then
        echo ""
        echo "--- Step 7: ROLLBACK ---"
        echo -e "${RED}Upgrade failed, rolling back...${NC}"
        
        # Save failure report
        local failure_report="$CONFIG_DIR/upgrade-failure-$(date +%Y%m%d_%H%M%S).log"
        {
            echo "=== OpenClaw Upgrade Failure Report ==="
            echo "Date: $(date)"
            echo "From: $current_version"
            echo "To: $target_version"
            echo ""
            echo "=== Failed Health Checks ==="
            echo -e "$health_failures"
            echo ""
            echo "=== Gateway Status ==="
            openclaw gateway status 2>&1 || echo "(not responding)"
            echo ""
            echo "=== Recent Logs ==="
            openclaw logs --limit 50 2>&1 || echo "(unavailable)"
        } > "$failure_report" 2>&1
        
        # Rollback: reinstall previous version
        echo "Reinstalling openclaw@$current_version..."
        if npm install -g "openclaw@$current_version" 2>&1; then
            success "Reinstalled openclaw@$current_version"
        else
            echo -e "${RED}Rollback npm install failed!${NC}"
        fi
        
        # Restore config
        cp "$backup" "$config" && success "Restored config backup"
        
        # Start gateway with old version
        launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/ai.openclaw.gateway.plist 2>/dev/null
        sleep 3
        
        # Verify rollback
        local rolled_version=$(openclaw --version 2>/dev/null | head -1)
        if [[ "$rolled_version" == "$current_version" ]]; then
            success "Rolled back to $current_version"
        else
            echo -e "${RED}Rollback may have failed. Manual recovery:${NC}"
            echo "  npm install -g openclaw@$current_version"
            echo "  cp $backup $config"
            echo "  launchctl bootstrap gui/\$(id -u) ~/Library/LaunchAgents/ai.openclaw.gateway.plist"
        fi
        
        echo ""
        echo "Failure report: $failure_report"
        return 1
    fi
    
    # Success!
    echo ""
    success "=== Upgrade complete: $current_version → $target_version ==="
    
    # Record in version history
    echo "$(date -Iseconds): $current_version → $target_version (success)" >> "$VERSION_HISTORY"
    
    # Save success report
    local success_report="$CONFIG_DIR/upgrade-success-$(date +%Y%m%d_%H%M%S).log"
    {
        echo "=== OpenClaw Upgrade Success Report ==="
        echo "Date: $(date)"
        echo "From: $current_version"
        echo "To: $target_version"
        echo ""
        echo "=== Config Changes ==="
        diff <(jq -S . "$backup" 2>/dev/null) <(jq -S . "$config" 2>/dev/null) || echo "(no changes)"
    } > "$success_report" 2>&1
    
    echo ""
    echo "Report: $success_report"
    echo "History: $VERSION_HISTORY"
    echo ""
    echo "Rollback (if needed):"
    echo "  npm install -g openclaw@$current_version"
    echo "  cp $backup $config"
    echo "  launchctl kickstart -k gui/\$(id -u)/ai.openclaw.gateway"
}


cmd_git() {
    local subcmd="${1:-help}"
    shift 2>/dev/null || true
    
    case "$subcmd" in
        commit)
            local script="$(dirname "${BASH_SOURCE[0]}")/scripts/git-agent-commit"
            [[ -x "$script" ]] || error "git-agent-commit script not found: $script"
            "$script" "$@"
            ;;
        check|check-attribution)
            local script="$(dirname "${BASH_SOURCE[0]}")/scripts/check-git-attribution"
            [[ -x "$script" ]] || error "check-git-attribution script not found: $script"
            "$script" "$@"
            ;;
        help|-h|--help)
            cat <<'EOF'
Usage: bobnet git <command> [options]

Git attribution commands for BobNet agents.

COMMANDS:
  commit <message> [--full]    Commit with agent attribution
  check [timeframe]            Check recent commits for proper attribution

EXAMPLES:
  bobnet git commit "feat(ops): add deployment pipeline"
  bobnet git commit "fix: resolve auth bug" --full
  bobnet git check "24 hours ago"
  bobnet git check "1 week ago"

The commit command auto-detects the agent from your current workspace directory.
EOF
            ;;
        *)
            error "Unknown git command: $subcmd (try 'bobnet git help')"
            ;;
    esac
}

cmd_github() {
    local subcmd="${1:-help}"
    shift 2>/dev/null || true
    
    case "$subcmd" in
        issue)
            local action="${1:-help}"
            shift 2>/dev/null || true
            case "$action" in
                create)
                    cmd_github_issue_create "$@"
                    ;;
                link)
                    cmd_github_issue_link "$@"
                    ;;
                help|-h|--help)
                    cat <<'EOF'
Usage: bobnet github issue <command> [options]

GitHub issue commands.

COMMANDS:
  create <title> [options]     Create a new issue
  link <commit-hash>           Link a commit to its referenced issues

EXAMPLES:
  bobnet github issue create "Add OAuth provider" --body "..." --label enhancement
  bobnet github issue link abc1234
EOF
                    ;;
                *)
                    error "Unknown issue command: $action (try 'bobnet github issue help')"
                    ;;
            esac
            ;;
        milestone)
            local action="${1:-help}"
            shift 2>/dev/null || true
            case "$action" in
                status)
                    cmd_github_milestone_status "$@"
                    ;;
                help|-h|--help)
                    cat <<'EOF'
Usage: bobnet github milestone <command> [options]

GitHub milestone commands.

COMMANDS:
  status [milestone]           Show milestone status and progress

EXAMPLES:
  bobnet github milestone status "v1.0.0"
  bobnet github milestone status              # List all milestones
EOF
                    ;;
                *)
                    error "Unknown milestone command: $action (try 'bobnet github milestone help')"
                    ;;
            esac
            ;;
        project)
            local action="${1:-help}"
            shift 2>/dev/null || true
            case "$action" in
                create)
                    cmd_github_project_create "$@"
                    ;;
                list)
                    cmd_github_project_list "$@"
                    ;;
                add)
                    cmd_github_project_add "$@"
                    ;;
                status)
                    cmd_github_project_status "$@"
                    ;;
                sync)
                    cmd_github_project_sync "$@"
                    ;;
                set-status)
                    cmd_github_project_set_status "$@"
                    ;;
                help|-h|--help)
                    cat <<'EOF'
Usage: bobnet github project <command> [options]

GitHub Project commands for cross-repo work tracking.

COMMANDS:
  create <title>       Create a new project
  list                 List projects for organization
  add <issue-url>      Add issue to default project
  status [project-num] Show project status
  sync [--project N]   Sync project field metadata to cache
  set-status <issue> <status> [--project N]  Set issue status in project

EXAMPLES:
  bobnet github project create "Q1 Work"
  bobnet github project add https://github.com/owner/repo/issues/123
  bobnet github project status 4
  bobnet github project sync
  bobnet github project set-status 42 in-progress
  bobnet github project set-status owner/repo#42 done
EOF
                    ;;
                *)
                    error "Unknown project command: $action (try 'bobnet github project help')"
                    ;;
            esac
            ;;
        help|-h|--help)
            cat <<'EOF'
Usage: bobnet github <command> [subcommand] [options]

GitHub integration commands for project tracking.

COMMANDS:
  issue create        Create a new GitHub issue
  issue link          Link commits to issues
  milestone status    Query milestone progress
  project create      Create a GitHub Project
  project list        List organization projects
  project add         Add issue to project
  project status      Show project status

EXAMPLES:
  bobnet github issue create "Feature: Add SSO" --label enhancement
  bobnet github milestone status "Q1 2026"
  bobnet github project create "BobNet Work"
  bobnet github project add https://github.com/owner/repo/issues/5

See 'bobnet github <command> help' for more information on a specific command.
EOF
            ;;
        *)
            error "Unknown github command: $subcmd (try 'bobnet github help')"
            ;;
    esac
}

cmd_github_issue_create() {
    # Parse arguments
    local title="" body="" labels=() assignees=() milestone="" repo=""
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --body|-b)
                body="$2"
                shift 2
                ;;
            --label|-l)
                labels+=("$2")
                shift 2
                ;;
            --assignee|-a)
                assignees+=("$2")
                shift 2
                ;;
            --milestone|-m)
                milestone="$2"
                shift 2
                ;;
            --repo|-R)
                repo="$2"
                shift 2
                ;;
            -h|--help)
                cat <<'EOF'
Usage: bobnet github issue create <title> [options]

Create a new GitHub issue in the current repository.

OPTIONS:
  --body, -b <text>        Issue body/description
  --label, -l <label>      Add label (can be repeated)
  --assignee, -a <user>    Assign to user (can be repeated)
  --milestone, -m <name>   Add to milestone
  --repo, -R <owner/repo>  Target repository (default: current repo)

EXAMPLES:
  bobnet github issue create "Add OAuth support" \
    --body "Need to implement OAuth2 flow" \
    --label enhancement \
    --label auth \
    --assignee bob

  bobnet github issue create "Fix login bug" \
    --body "Users can't log in after password reset" \
    --label bug \
    --milestone "v1.5.0"
EOF
                return 0
                ;;
            *)
                if [[ -z "$title" ]]; then
                    title="$1"
                    shift
                else
                    error "Unexpected argument: $1"
                fi
                ;;
        esac
    done
    
    [[ -z "$title" ]] && error "Title is required"
    
    # Build gh command
    local cmd=(gh issue create --title "$title")
    
    [[ -n "$body" ]] && cmd+=(--body "$body")
    [[ -n "$milestone" ]] && cmd+=(--milestone "$milestone")
    [[ -n "$repo" ]] && cmd+=(--repo "$repo")
    
    if [[ ${#labels[@]} -gt 0 ]]; then
        for label in "${labels[@]}"; do
            cmd+=(--label "$label")
        done
    fi
    
    if [[ ${#assignees[@]} -gt 0 ]]; then
        for assignee in "${assignees[@]}"; do
            cmd+=(--assignee "$assignee")
        done
    fi
    
    # Execute
    echo "Creating issue: $title" >&2
    "${cmd[@]}" || error "Failed to create issue"
}

cmd_github_issue_link() {
    local commit_hash="$1"
    
    if [[ "$commit_hash" == "-h" || "$commit_hash" == "--help" ]]; then
        cat <<'EOF'
Usage: bobnet github issue link <commit-hash>

Link a commit to the issues it references (via #123 syntax).

This command:
1. Extracts issue numbers from the commit message
2. Adds a comment to each issue with the commit reference
3. Updates issue labels if the commit type indicates resolution

EXAMPLES:
  bobnet github issue link abc1234
  bobnet github issue link HEAD
  bobnet github issue link main~3
EOF
        return 0
    fi
    
    [[ -z "$commit_hash" ]] && error "Commit hash is required"
    
    # Get commit message
    local commit_msg
    commit_msg=$(git log -1 --format=%B "$commit_hash" 2>/dev/null) || error "Invalid commit: $commit_hash"
    
    # Extract issue numbers (#123, #456, etc.)
    local issue_numbers
    issue_numbers=$(echo "$commit_msg" | grep -oE '#[0-9]+' | tr -d '#' | sort -u)
    
    if [[ -z "$issue_numbers" ]]; then
        echo "No issue references found in commit $commit_hash"
        return 0
    fi
    
    # Get short hash for comments
    local short_hash
    short_hash=$(git rev-parse --short "$commit_hash")
    
    # Get commit subject (first line)
    local commit_subject
    commit_subject=$(git log -1 --format=%s "$commit_hash")
    
    echo "Found issue references in commit $short_hash:"
    echo "$issue_numbers" | while read -r issue_num; do
        echo "  #$issue_num"
    done
    
    # Add comment to each issue
    echo
    echo "$issue_numbers" | while read -r issue_num; do
        local comment="Referenced in commit $short_hash: $commit_subject"
        
        echo "Adding comment to issue #$issue_num..."
        gh issue comment "$issue_num" --body "$comment" 2>/dev/null || {
            warn "Failed to comment on issue #$issue_num (may not exist or no access)"
        }
    done
    
    success "Linked commit $short_hash to referenced issues"
}

cmd_github_milestone_status() {
    local milestone_name="${1:-}"
    local repo="${2:-}"
    
    if [[ "$milestone_name" == "-h" || "$milestone_name" == "--help" ]]; then
        cat <<'EOF'
Usage: bobnet github milestone status [milestone-name] [repo]

Show milestone progress and issue status.

If no milestone name is provided, lists all milestones.

OPTIONS:
  milestone-name    Name or number of the milestone
  repo             Repository (default: current repo)

EXAMPLES:
  bobnet github milestone status
  bobnet github milestone status "v1.0.0"
  bobnet github milestone status "Q1 2026" buildzero-tech/finmindful
EOF
        return 0
    fi
    
    if [[ -z "$milestone_name" ]]; then
        # List all milestones
        echo "Milestones:"
        if [[ -n "$repo" ]]; then
            gh api repos/:owner/:repo/milestones --repo "$repo" \
                --jq '.[] | "  \(.title) - \(.open_issues) open / \(.closed_issues) closed (\(.state))"' 2>/dev/null || {
                error "Failed to fetch milestones (are you in a git repo?)"
            }
        else
            gh api repos/:owner/:repo/milestones \
                --jq '.[] | "  \(.title) - \(.open_issues) open / \(.closed_issues) closed (\(.state))"' 2>/dev/null || {
                error "Failed to fetch milestones (are you in a git repo?)"
            }
        fi
        return 0
    fi
    
    # Get specific milestone
    local milestone_data
    if [[ -n "$repo" ]]; then
        milestone_data=$(gh api repos/:owner/:repo/milestones --repo "$repo" \
            --jq ".[] | select(.title == \"$milestone_name\")" 2>/dev/null)
    else
        milestone_data=$(gh api repos/:owner/:repo/milestones \
            --jq ".[] | select(.title == \"$milestone_name\")" 2>/dev/null)
    fi
    
    if [[ -z "$milestone_data" ]]; then
        error "Milestone not found: $milestone_name"
    fi
    
    # Parse milestone data
    local title state open_issues closed_issues due_on description
    title=$(echo "$milestone_data" | jq -r '.title')
    state=$(echo "$milestone_data" | jq -r '.state')
    open_issues=$(echo "$milestone_data" | jq -r '.open_issues')
    closed_issues=$(echo "$milestone_data" | jq -r '.closed_issues')
    due_on=$(echo "$milestone_data" | jq -r '.due_on // "No due date"')
    description=$(echo "$milestone_data" | jq -r '.description // "No description"')
    
    # Calculate progress
    local total_issues=$((open_issues + closed_issues))
    local progress=0
    if [[ $total_issues -gt 0 ]]; then
        progress=$((closed_issues * 100 / total_issues))
    fi
    
    # Display
    echo "Milestone: $title"
    echo "Status: $state"
    echo "Progress: $closed_issues/$total_issues issues ($progress%)"
    echo "Due: $due_on"
    echo
    echo "Description:"
    echo "$description"
    echo
    
    # Show open issues
    if [[ $open_issues -gt 0 ]]; then
        echo "Open issues ($open_issues):"
        if [[ -n "$repo" ]]; then
            gh issue list --milestone "$milestone_name" --state open --repo "$repo" \
                --json number,title,labels \
                --template '{{range .}}  #{{.number}} {{.title}}{{range .labels}} [{{.name}}]{{end}}
{{end}}'
        else
            gh issue list --milestone "$milestone_name" --state open \
                --json number,title,labels \
                --template '{{range .}}  #{{.number}} {{.title}}{{range .labels}} [{{.name}}]{{end}}
{{end}}'
        fi
    fi
}

# GitHub Project commands
cmd_github_project_create() {
    local title="${1:-}"
    local owner=""
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --owner|-o)
                owner="$2"
                shift 2
                ;;
            -h|--help)
                cat <<'EOF'
Usage: bobnet github project create <title> [options]

Create a new GitHub Project.

OPTIONS:
  --owner, -o <org>   Organization owner (default: from current repo)

EXAMPLES:
  bobnet github project create "Q1 Work"
  bobnet github project create "BobNet Work" --owner buildzero-tech
EOF
                return 0
                ;;
            *)
                if [[ -z "$title" ]]; then
                    title="$1"
                fi
                shift
                ;;
        esac
    done
    
    [[ -z "$title" ]] && error "Usage: bobnet github project create <title> [--owner <org>]"
    
    # Get owner from current repo if not specified
    if [[ -z "$owner" ]]; then
        owner=$(gh repo view --json owner -q '.owner.login' 2>/dev/null) || {
            error "Could not detect owner. Use --owner or run from a git repo."
        }
    fi
    
    echo "Creating project: $title (owner: $owner)"
    
    local result
    result=$(gh project create --owner "$owner" --title "$title" --format json 2>&1) || {
        error "Failed to create project: $result"
    }
    
    local url number
    url=$(echo "$result" | jq -r '.url')
    number=$(echo "$result" | jq -r '.number')
    
    success "Created project #$number"
    echo "$url"
}

cmd_github_project_list() {
    local owner=""
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --owner|-o)
                owner="$2"
                shift 2
                ;;
            -h|--help)
                cat <<'EOF'
Usage: bobnet github project list [options]

List GitHub Projects for an organization.

OPTIONS:
  --owner, -o <org>   Organization owner (default: from current repo)

EXAMPLES:
  bobnet github project list
  bobnet github project list --owner buildzero-tech
EOF
                return 0
                ;;
            *)
                shift
                ;;
        esac
    done
    
    # Get owner from current repo if not specified
    if [[ -z "$owner" ]]; then
        owner=$(gh repo view --json owner -q '.owner.login' 2>/dev/null) || {
            error "Could not detect owner. Use --owner or run from a git repo."
        }
    fi
    
    echo "Projects for $owner:"
    gh project list --owner "$owner" --format json | jq -r '.projects[] | "  #\(.number): \(.title) (\(.items.totalCount) items)"'
}

cmd_github_project_add() {
    local url="${1:-}"
    local project=""
    local owner=""
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --project|-p)
                project="$2"
                shift 2
                ;;
            --owner|-o)
                owner="$2"
                shift 2
                ;;
            -h|--help)
                cat <<'EOF'
Usage: bobnet github project add <issue-url> [options]

Add an issue or PR to a GitHub Project.

OPTIONS:
  --project, -p <num>  Project number (default: from BOBNET_PROJECT env or 4)
  --owner, -o <org>    Organization owner (default: from current repo)

EXAMPLES:
  bobnet github project add https://github.com/owner/repo/issues/123
  bobnet github project add https://github.com/owner/repo/issues/5 --project 4
EOF
                return 0
                ;;
            *)
                if [[ -z "$url" ]]; then
                    url="$1"
                fi
                shift
                ;;
        esac
    done
    
    [[ -z "$url" ]] && error "Usage: bobnet github project add <issue-url> [--project <num>]"
    
    # Get owner from current repo if not specified
    if [[ -z "$owner" ]]; then
        owner=$(gh repo view --json owner -q '.owner.login' 2>/dev/null) || {
            error "Could not detect owner. Use --owner or run from a git repo."
        }
    fi
    
    # Default project from env or 4 (BobNet Work)
    project="${project:-${BOBNET_PROJECT:-4}}"
    
    echo "Adding to project #$project: $url"
    gh project item-add "$project" --owner "$owner" --url "$url" 2>&1 || {
        error "Failed to add item to project"
    }
    success "Added to project"
}

cmd_github_project_status() {
    local project="${1:-}"
    local owner=""
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --owner|-o)
                owner="$2"
                shift 2
                ;;
            -h|--help)
                cat <<'EOF'
Usage: bobnet github project status [project-num] [options]

Show GitHub Project status and items.

OPTIONS:
  project-num         Project number (default: from BOBNET_PROJECT env or 4)
  --owner, -o <org>   Organization owner (default: from current repo)

EXAMPLES:
  bobnet github project status
  bobnet github project status 4
  bobnet github project status 4 --owner buildzero-tech
EOF
                return 0
                ;;
            *)
                if [[ -z "$project" && "$1" =~ ^[0-9]+$ ]]; then
                    project="$1"
                fi
                shift
                ;;
        esac
    done
    
    # Get owner from current repo if not specified
    if [[ -z "$owner" ]]; then
        owner=$(gh repo view --json owner -q '.owner.login' 2>/dev/null) || {
            error "Could not detect owner. Use --owner or run from a git repo."
        }
    fi
    
    # Default project from env or 4
    project="${project:-${BOBNET_PROJECT:-4}}"
    
    echo "Project #$project ($owner):"
    echo
    
    # Get project info
    local items
    items=$(gh project item-list "$project" --owner "$owner" --format json 2>&1) || {
        error "Failed to fetch project: $items"
    }
    
    # Display items grouped by repo
    echo "$items" | jq -r '.items | group_by(.content.repository) | .[] | "[\(.[0].content.repository // "Draft")]", (.[] | "  #\(.content.number // "draft"): \(.content.title)"), ""'
}

cmd_github_project_sync() {
    local project=""
    local owner=""
    local refresh=false
    local schema_file="${BOBNET_SCHEMA:-$HOME/.bobnet/ultima-thule/config/bobnet.json}"
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --project|-p)
                project="$2"
                shift 2
                ;;
            --owner|-o)
                owner="$2"
                shift 2
                ;;
            --refresh|-r)
                refresh=true
                shift
                ;;
            --schema)
                schema_file="$2"
                shift 2
                ;;
            -h|--help)
                cat <<'EOF'
Usage: bobnet github project sync [options]

Sync GitHub Project field metadata to local cache.

OPTIONS:
  --project, -p <num>   Project number (default: from config)
  --owner, -o <org>     Organization (default: from config)
  --refresh, -r         Force refresh even if cache is valid
  --schema <path>       Path to bobnet.json

Caches Status and Priority field IDs and option values for use
by set-status and other project commands.

EXAMPLES:
  bobnet github project sync
  bobnet github project sync --project 4 --refresh
EOF
                return 0
                ;;
            *)
                if [[ "$1" =~ ^[0-9]+$ ]]; then
                    project="$1"
                fi
                shift
                ;;
        esac
    done
    
    # Load config
    if [[ ! -f "$schema_file" ]]; then
        error "Schema file not found: $schema_file"
    fi
    
    # Get defaults from config
    if [[ -z "$owner" ]]; then
        owner=$(jq -r '.github.org // empty' "$schema_file")
        [[ -z "$owner" ]] && owner=$(gh repo view --json owner -q '.owner.login' 2>/dev/null)
    fi
    [[ -z "$owner" ]] && error "Could not determine organization. Use --owner or configure github.org in schema."
    
    if [[ -z "$project" ]]; then
        project=$(jq -r '.github.defaultProject // empty' "$schema_file")
    fi
    [[ -z "$project" ]] && error "No project specified and no default configured."
    
    # Check cache TTL (24 hours)
    local cached_at
    cached_at=$(jq -r ".github.projects[\"$project\"].cachedAt // empty" "$schema_file")
    if [[ -n "$cached_at" && "$refresh" != "true" ]]; then
        local cached_ts now_ts
        cached_ts=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$cached_at" "+%s" 2>/dev/null || echo 0)
        now_ts=$(date "+%s")
        local age=$((now_ts - cached_ts))
        if [[ $age -lt 86400 ]]; then
            echo "Cache valid (age: $((age / 3600))h). Use --refresh to force update."
            return 0
        fi
    fi
    
    echo "Syncing project #$project from $owner..."
    
    # Get project node ID first
    local project_id
    project_id=$(gh project view "$project" --owner "$owner" --format json 2>/dev/null | jq -r '.id // empty')
    if [[ -z "$project_id" ]]; then
        error "Could not find project #$project for $owner"
    fi
    
    # Get project name
    local project_name
    project_name=$(gh project view "$project" --owner "$owner" --format json 2>/dev/null | jq -r '.title // empty')
    
    echo "  Project: $project_name ($project_id)"
    
    # Get fields
    local fields
    fields=$(gh project field-list "$project" --owner "$owner" --format json 2>&1) || {
        error "Failed to fetch fields: $fields"
    }
    
    # Extract Status field
    local status_field_id status_options
    status_field_id=$(echo "$fields" | jq -r '.fields[] | select(.name == "Status") | .id // empty')
    
    if [[ -n "$status_field_id" ]]; then
        echo "  Status field: $status_field_id"
        status_options=$(echo "$fields" | jq -c '[.fields[] | select(.name == "Status") | .options[]? | {key: .name, value: .id}] | from_entries')
        echo "  Status options: $(echo "$status_options" | jq -r 'keys | join(", ")')"
    else
        echo "  ⚠ No Status field found"
        status_options="{}"
    fi
    
    # Extract Priority field
    local priority_field_id priority_options
    priority_field_id=$(echo "$fields" | jq -r '.fields[] | select(.name == "Priority") | .id // empty')
    
    if [[ -n "$priority_field_id" ]]; then
        echo "  Priority field: $priority_field_id"
        priority_options=$(echo "$fields" | jq -c '[.fields[] | select(.name == "Priority") | .options[]? | {key: .name, value: .id}] | from_entries')
        echo "  Priority options: $(echo "$priority_options" | jq -r 'keys | join(", ")')"
    else
        echo "  ⚠ No Priority field found"
        priority_options="{}"
    fi
    
    # Update schema file
    local now_iso
    now_iso=$(date -u "+%Y-%m-%dT%H:%M:%SZ")
    
    local tmp_file
    tmp_file=$(mktemp)
    jq --arg proj "$project" \
       --arg pid "$project_id" \
       --arg name "$project_name" \
       --arg sfid "$status_field_id" \
       --argjson sopts "$status_options" \
       --arg pfid "$priority_field_id" \
       --argjson popts "$priority_options" \
       --arg cached "$now_iso" \
       '.github.projects[$proj] = {
          "name": $name,
          "projectId": $pid,
          "statusField": (if $sfid != "" then {"id": $sfid, "options": $sopts} else null end),
          "priorityField": (if $pfid != "" then {"id": $pfid, "options": $popts} else null end),
          "cachedAt": $cached
        }' "$schema_file" > "$tmp_file" && mv "$tmp_file" "$schema_file"
    
    success "Cached project metadata for #$project"
}

cmd_github_project_set_status() {
    local issue=""
    local status=""
    local project=""
    local owner=""
    local repo=""
    local schema_file="${BOBNET_SCHEMA:-$HOME/.bobnet/ultima-thule/config/bobnet.json}"
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --project|-p)
                project="$2"
                shift 2
                ;;
            --owner|-o)
                owner="$2"
                shift 2
                ;;
            --repo|-r)
                repo="$2"
                shift 2
                ;;
            --schema)
                schema_file="$2"
                shift 2
                ;;
            -h|--help)
                cat <<'EOF'
Usage: bobnet github project set-status <issue> <status> [options]

Set the status of an issue in a GitHub Project.

ARGUMENTS:
  issue           Issue number or owner/repo#num
  status          Status value (todo, in-progress, done, or exact name)

OPTIONS:
  --project, -p <num>   Project number (default: from config)
  --owner, -o <org>     Organization (default: from config)
  --repo, -r <name>     Repository name (default: from current dir)

STATUS ALIASES:
  todo, backlog, open       → "Todo"
  in-progress, wip, doing   → "In Progress"
  done, closed, complete    → "Done"

EXAMPLES:
  bobnet github project set-status 42 in-progress
  bobnet github project set-status buildzero-tech/bobnet-cli#42 done
  bobnet github project set-status 42 "In Progress" --project 4
EOF
                return 0
                ;;
            *)
                if [[ -z "$issue" ]]; then
                    issue="$1"
                elif [[ -z "$status" ]]; then
                    status="$1"
                fi
                shift
                ;;
        esac
    done
    
    [[ -z "$issue" ]] && error "Issue number required"
    [[ -z "$status" ]] && error "Status value required"
    
    # Parse issue reference (owner/repo#num or just num)
    local issue_num
    if [[ "$issue" =~ ^([^/]+)/([^#]+)#([0-9]+)$ ]]; then
        owner="${BASH_REMATCH[1]}"
        repo="${BASH_REMATCH[2]}"
        issue_num="${BASH_REMATCH[3]}"
    elif [[ "$issue" =~ ^#?([0-9]+)$ ]]; then
        issue_num="${BASH_REMATCH[1]}"
    else
        error "Invalid issue format: $issue (use N or owner/repo#N)"
    fi
    
    # Load config
    if [[ ! -f "$schema_file" ]]; then
        error "Schema file not found: $schema_file"
    fi
    
    # Get defaults
    [[ -z "$owner" ]] && owner=$(jq -r '.github.org // empty' "$schema_file")
    [[ -z "$owner" ]] && owner=$(gh repo view --json owner -q '.owner.login' 2>/dev/null)
    [[ -z "$owner" ]] && error "Could not determine organization"
    
    [[ -z "$repo" ]] && repo=$(gh repo view --json name -q '.name' 2>/dev/null)
    [[ -z "$repo" ]] && error "Could not determine repository"
    
    [[ -z "$project" ]] && project=$(jq -r '.github.defaultProject // empty' "$schema_file")
    [[ -z "$project" ]] && error "No project specified and no default configured"
    
    # Check cache, sync if needed
    local cached_at
    cached_at=$(jq -r ".github.projects[\"$project\"].cachedAt // empty" "$schema_file")
    if [[ -z "$cached_at" ]]; then
        echo "No cache for project #$project, syncing..."
        cmd_github_project_sync --project "$project" --owner "$owner" --schema "$schema_file" || {
            error "Failed to sync project metadata"
        }
    fi
    
    # Normalize status alias
    local normalized_status
    local status_lower
    status_lower=$(echo "$status" | tr '[:upper:]' '[:lower:]')
    case "$status_lower" in
        todo|backlog|open)
            normalized_status="Todo"
            ;;
        in-progress|wip|doing|inprogress)
            normalized_status="In Progress"
            ;;
        done|closed|complete|finished)
            normalized_status="Done"
            ;;
        *)
            # Try exact match
            normalized_status="$status"
            ;;
    esac
    
    # Get field and option IDs from cache
    local status_field_id option_id
    status_field_id=$(jq -r ".github.projects[\"$project\"].statusField.id // empty" "$schema_file")
    [[ -z "$status_field_id" ]] && error "No Status field cached for project #$project"
    
    option_id=$(jq -r ".github.projects[\"$project\"].statusField.options[\"$normalized_status\"] // empty" "$schema_file")
    if [[ -z "$option_id" ]]; then
        # List available options
        local available
        available=$(jq -r ".github.projects[\"$project\"].statusField.options | keys | join(\", \")" "$schema_file")
        error "Unknown status '$normalized_status'. Available: $available"
    fi
    
    # Get project ID
    local project_id
    project_id=$(jq -r ".github.projects[\"$project\"].projectId // empty" "$schema_file")
    [[ -z "$project_id" ]] && error "No project ID cached"
    
    # Find the project item for this issue
    local issue_url="https://github.com/$owner/$repo/issues/$issue_num"
    echo "Finding item for $owner/$repo#$issue_num in project #$project..."
    
    local items item_id
    items=$(gh project item-list "$project" --owner "$owner" --format json 2>&1) || {
        error "Failed to list project items: $items"
    }
    
    item_id=$(echo "$items" | jq -r ".items[] | select(.content.url == \"$issue_url\") | .id" | head -1)
    
    if [[ -z "$item_id" ]]; then
        error "Issue #$issue_num not found in project #$project. Add it first: bobnet github project add $issue_url"
    fi
    
    echo "Setting status to '$normalized_status'..."
    
    # Update the item
    gh project item-edit --project-id "$project_id" --id "$item_id" \
        --field-id "$status_field_id" --single-select-option-id "$option_id" 2>&1 || {
        error "Failed to update status"
    }
    
    success "Set $owner/$repo#$issue_num → $normalized_status"
}

cmd_incident() {
    local subcmd="${1:-help}"
    shift 2>/dev/null || true
    
    case "$subcmd" in
        create)
            cmd_incident_create "$@"
            ;;
        close)
            cmd_incident_close "$@"
            ;;
        list)
            cmd_incident_list "$@"
            ;;
        help|-h|--help)
            cat <<'EOF'
Usage: bobnet incident <command> [options]

Incident tracking and post-mortem management.

COMMANDS:
  create <title>         Create new incident report
  close <id>             Close incident and finalize post-mortem
  list                   List all incidents

EXAMPLES:
  bobnet incident create "Production database down"
  bobnet incident close 2026-02-06-db-outage
  bobnet incident list

See 'bobnet incident <command> help' for more information.
EOF
            ;;
        *)
            error "Unknown incident command: $subcmd (try 'bobnet incident help')"
            ;;
    esac
}

cmd_incident_create() {
    local title=""
    local severity="P2"
    local impact=""
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --severity|-s)
                severity="$2"
                shift 2
                ;;
            --impact|-i)
                impact="$2"
                shift 2
                ;;
            -h|--help)
                cat <<'EOF'
Usage: bobnet incident create <title> [options]

Create a new incident report with structured template.

OPTIONS:
  --severity, -s <P0-P3>   Incident severity (default: P2)
                           P0: Critical (production down)
                           P1: High (major feature broken)
                           P2: Medium (minor issue)
                           P3: Low (cosmetic)
  --impact, -i <text>      Brief impact description

EXAMPLES:
  bobnet incident create "Database connection pool exhausted" --severity P0
  bobnet incident create "Login page slow" --severity P2 --impact "Users experiencing 5s delays"
EOF
                return 0
                ;;
            *)
                if [[ -z "$title" ]]; then
                    title="$1"
                    shift
                else
                    error "Unexpected argument: $1"
                fi
                ;;
        esac
    done
    
    [[ -z "$title" ]] && error "Incident title is required"
    
    # Generate incident ID (date-slug)
    local date=$(date +%Y-%m-%d)
    local slug=$(echo "$title" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | sed 's/[^a-z0-9-]//g' | cut -c1-40)
    local incident_id="$date-$slug"
    
    # Create incidents directory in collective
    local incidents_dir="$BOBNET_ROOT/collective/incidents"
    mkdir -p "$incidents_dir"
    
    local incident_file="$incidents_dir/$incident_id.md"
    
    if [[ -f "$incident_file" ]]; then
        error "Incident already exists: $incident_id"
    fi
    
    # Create template
    cat > "$incident_file" <<EOF
# Incident: $title

**ID:** $incident_id  
**Severity:** $severity  
**Status:** Active  
**Detected:** $(date '+%Y-%m-%d %H:%M %Z')  
**Resolved:** *(pending)*

---

## Impact

${impact:-*(to be filled)*}

---

## Timeline

- **$(date '+%H:%M')** — Incident detected

---

## Root Cause

*(to be determined)*

---

## Resolution

*(in progress)*

---

## Follow-up Actions

- [ ] *(action items to be added)*

---

## Lessons Learned

*(to be added in post-mortem)*

---

*Incident report created by \`bobnet incident create\`*
EOF
    
    success "Incident created: $incident_id"
    echo "  File: $incident_file"
    echo "  Edit with: vim $incident_file"
    echo "  Close with: bobnet incident close $incident_id"
}

cmd_incident_close() {
    local incident_id="$1"
    
    if [[ "$incident_id" == "-h" || "$incident_id" == "--help" || -z "$incident_id" ]]; then
        cat <<'EOF'
Usage: bobnet incident close <incident-id>

Close an incident and mark it as resolved.

Updates:
- Status: Active → Resolved
- Resolved timestamp
- Prompts for final notes

EXAMPLES:
  bobnet incident close 2026-02-06-db-outage
EOF
        return 0
    fi
    
    local incidents_dir="$BOBNET_ROOT/collective/incidents"
    local incident_file="$incidents_dir/$incident_id.md"
    
    if [[ ! -f "$incident_file" ]]; then
        error "Incident not found: $incident_id"
    fi
    
    # Check if already closed
    if grep -q "\*\*Status:\*\* Resolved" "$incident_file"; then
        warn "Incident already resolved: $incident_id"
        return 0
    fi
    
    # Update status and resolved time
    local resolved_time=$(date '+%Y-%m-%d %H:%M %Z')
    
    # Use sed to update in place
    sed -i '' \
        -e "s/\*\*Status:\*\* Active/**Status:** Resolved/" \
        -e "s/\*\*Resolved:\*\* \*(pending)\*/**Resolved:** $resolved_time/" \
        "$incident_file"
    
    success "Incident closed: $incident_id"
    echo "  Resolved: $resolved_time"
    echo "  File: $incident_file"
    echo
    echo "Remember to complete:"
    echo "  - Root cause analysis"
    echo "  - Follow-up actions"
    echo "  - Lessons learned"
}

cmd_incident_list() {
    if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
        cat <<'EOF'
Usage: bobnet incident list

List all incidents (active and resolved).

OUTPUT:
  Incidents sorted by date, with status and severity

EXAMPLE:
  bobnet incident list
EOF
        return 0
    fi
    
    local incidents_dir="$BOBNET_ROOT/collective/incidents"
    
    if [[ ! -d "$incidents_dir" ]]; then
        echo "No incidents directory found."
        return 0
    fi
    
    local incidents=$(ls -1 "$incidents_dir"/*.md 2>/dev/null || echo "")
    
    if [[ -z "$incidents" ]]; then
        echo "No incidents found."
        return 0
    fi
    
    echo "=== Incidents ==="
    echo
    
    for incident_file in $incidents; do
        local incident_id=$(basename "$incident_file" .md)
        local title=$(grep "^# Incident:" "$incident_file" | sed 's/^# Incident: //')
        local status=$(grep "\*\*Status:\*\*" "$incident_file" | sed 's/.*\*\*Status:\*\* //')
        local severity=$(grep "\*\*Severity:\*\*" "$incident_file" | sed 's/.*\*\*Severity:\*\* //')
        
        echo "[$status] $incident_id ($severity)"
        echo "  $title"
        echo
    done
}

cmd_docs() {
    local subcmd="${1:-help}"
    shift 2>/dev/null || true
    
    case "$subcmd" in
        roadmap)
            cmd_docs_roadmap "$@"
            ;;
        changelog)
            cmd_docs_changelog "$@"
            ;;
        release)
            cmd_docs_release "$@"
            ;;
        help|-h|--help)
            cat <<'EOF'
Usage: bobnet docs <command> [options]

Documentation generation from git and GitHub data.

COMMANDS:
  roadmap                 Generate ROADMAP.md from GitHub milestones
  changelog [version]     Generate CHANGELOG.md from commits
  release <version>       Generate release notes

EXAMPLES:
  bobnet docs roadmap
  bobnet docs changelog
  bobnet docs release v1.5.0

See 'bobnet docs <command> help' for more information.
EOF
            ;;
        *)
            error "Unknown docs command: $subcmd (try 'bobnet docs help')"
            ;;
    esac
}

cmd_docs_roadmap() {
    if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
        cat <<'EOF'
Usage: bobnet docs roadmap [options]

Generate ROADMAP.md from GitHub milestones and projects.

OUTPUT:
  ROADMAP.md with milestones grouped by quarter/release

EXAMPLES:
  bobnet docs roadmap
  bobnet docs roadmap > ROADMAP.md
EOF
        return 0
    fi
    
    echo "# Product Roadmap"
    echo
    echo "*Last updated: $(date +%Y-%m-%d) (auto-generated via \`bobnet docs roadmap\`)*"
    echo
    
    # Fetch all milestones
    local milestones
    milestones=$(gh api repos/:owner/:repo/milestones --jq '.[] | {title:.title, due:.due_on, state:.state, open:.open_issues, closed:.closed_issues, description:.description}' 2>/dev/null)
    
    if [[ -z "$milestones" ]]; then
        echo "No milestones found."
        return 0
    fi
    
    # Group by year/quarter or just list
    echo "$milestones" | jq -r '. | "## \(.title)\n\n**Due:** \(.due // "No due date")  \n**Status:** \(.state)  \n**Progress:** \(.closed)/\((.open + .closed)) issues\n\n\(.description // "No description")\n"'
}

cmd_docs_changelog() {
    local version="${1:-}"
    
    if [[ "$version" == "-h" || "$version" == "--help" ]]; then
        cat <<'EOF'
Usage: bobnet docs changelog [version]

Generate CHANGELOG.md from conventional commits.

Follows Keep a Changelog format.

OPTIONS:
  version    Version to generate changelog for (default: unreleased)

EXAMPLES:
  bobnet docs changelog              # Unreleased changes
  bobnet docs changelog v1.5.0       # Changes for specific version
EOF
        return 0
    fi
    
    echo "# Changelog"
    echo
    echo "All notable changes to this project are documented here."
    echo
    
    if [[ -z "$version" ]]; then
        echo "## [Unreleased]"
        echo
        
        # Get commits since last tag
        local last_tag
        last_tag=$(git describe --tags --abbrev=0 2>/dev/null || echo "")
        
        local commit_range
        if [[ -n "$last_tag" ]]; then
            commit_range="$last_tag..HEAD"
        else
            commit_range="HEAD"
        fi
        
        # Group by type
        echo "### Added"
        git log --format="%s" "$commit_range" | grep "feat:" | sed 's/^\[.*\] //; s/^feat[^:]*: */- /'
        echo
        
        echo "### Changed"
        git log --format="%s" "$commit_range" | grep "refactor:\|perf:" | sed 's/^\[.*\] //; s/^[^:]*: */- /'
        echo
        
        echo "### Fixed"
        git log --format="%s" "$commit_range" | grep "fix:" | sed 's/^\[.*\] //; s/^fix[^:]*: */- /'
        echo
    else
        # Generate for specific version
        local prev_tag
        prev_tag=$(git describe --tags --abbrev=0 "$version^" 2>/dev/null || echo "")
        
        echo "## [$version] - $(git log -1 --format=%ai $version | cut -d' ' -f1)"
        echo
        
        local commit_range
        if [[ -n "$prev_tag" ]]; then
            commit_range="$prev_tag..$version"
        else
            commit_range="$version"
        fi
        
        echo "### Added"
        git log --format="%s" "$commit_range" | grep "feat:" | sed 's/^\[.*\] //; s/^feat[^:]*: */- /'
        echo
        
        echo "### Changed"
        git log --format="%s" "$commit_range" | grep "refactor:\|perf:" | sed 's/^\[.*\] //; s/^[^:]*: */- /'
        echo
        
        echo "### Fixed"
        git log --format="%s" "$commit_range" | grep "fix:" | sed 's/^\[.*\] //; s/^fix[^:]*: */- /'
        echo
        
        if [[ -n "$prev_tag" ]]; then
            echo "**Full Changelog:** https://github.com/:owner/:repo/compare/$prev_tag...$version"
        fi
    fi
}

cmd_docs_release() {
    local version="$1"
    
    if [[ "$version" == "-h" || "$version" == "--help" || -z "$version" ]]; then
        cat <<'EOF'
Usage: bobnet docs release <version>

Generate release notes for a version.

Combines:
- Conventional commit messages
- Linked GitHub issues
- Contributors

OPTIONS:
  version    Version tag (e.g., v1.5.0)

EXAMPLES:
  bobnet docs release v1.5.0
  bobnet docs release v1.5.0 > releases/v1.5.0.md
EOF
        return 0
    fi
    
    echo "# Release Notes: $version"
    echo
    echo "**Released:** $(git log -1 --format=%ai $version 2>/dev/null | cut -d' ' -f1 || date +%Y-%m-%d)"
    echo
    
    # Get previous tag
    local prev_tag
    prev_tag=$(git describe --tags --abbrev=0 "$version^" 2>/dev/null || echo "")
    
    local commit_range
    if [[ -n "$prev_tag" ]]; then
        commit_range="$prev_tag..$version"
        echo "**Changes since $prev_tag**"
    else
        commit_range="$version"
        echo "**Initial release**"
    fi
    echo
    
    # Features
    local features
    features=$(git log --format="%s" "$commit_range" | grep "feat:")
    if [[ -n "$features" ]]; then
        echo "## ✨ Features"
        echo
        echo "$features" | sed 's/^\[.*\] //; s/^feat[^:]*: */- /'
        echo
    fi
    
    # Fixes
    local fixes
    fixes=$(git log --format="%s" "$commit_range" | grep "fix:")
    if [[ -n "$fixes" ]]; then
        echo "## 🐛 Bug Fixes"
        echo
        echo "$fixes" | sed 's/^\[.*\] //; s/^fix[^:]*: */- /'
        echo
    fi
    
    # Other changes
    local other
    other=$(git log --format="%s" "$commit_range" | grep -v "feat:\|fix:")
    if [[ -n "$other" ]]; then
        echo "## 🔧 Other Changes"
        echo
        echo "$other" | sed 's/^\[.*\] //; s/^[^:]*: */- /'
        echo
    fi
    
    # Contributors
    echo "## 👥 Contributors"
    echo
    git log --format="%aN <%aE>" "$commit_range" | sort -u | sed 's/^/- /'
    echo
    
    # Link
    if [[ -n "$prev_tag" ]]; then
        echo "**Full Changelog:** https://github.com/:owner/:repo/compare/$prev_tag...$version"
    fi
}

cmd_todo() {
    local subcmd="${1:-help}"
    shift 2>/dev/null || true
    
    case "$subcmd" in
        sync)
            cmd_todo_sync "$@"
            ;;
        status)
            cmd_todo_status "$@"
            ;;
        list)
            cmd_todo_list "$@"
            ;;
        help|-h|--help)
            cat <<'EOF'
Usage: bobnet todo <command> [options]

Todo management and GitHub synchronization.

COMMANDS:
  list [agent]           List todos for agent(s)
  status                 Show todo status across all agents
  sync [--dry-run]       Sync todos with GitHub issues

EXAMPLES:
  bobnet todo list bob
  bobnet todo status
  bobnet todo sync --dry-run

See 'bobnet todo <command> help' for more information.
EOF
            ;;
        *)
            error "Unknown todo command: $subcmd (try 'bobnet todo help')"
            ;;
    esac
}

cmd_todo_list() {
    local agent="${1:-}"
    
    if [[ "$agent" == "-h" || "$agent" == "--help" ]]; then
        cat <<'EOF'
Usage: bobnet todo list [agent]

List todos for a specific agent or all agents.

OPTIONS:
  agent    Agent name (omit to list all)

FORMAT:
  - [ ] **Title** — Description #issue-number
  - [x] **Title** — Description #issue-number (completed date)

EXAMPLES:
  bobnet todo list bob
  bobnet todo list
EOF
        return 0
    fi
    
    local agents=()
    if [[ -n "$agent" ]]; then
        agents=("$agent")
    else
        # Get all agents
        while IFS= read -r a; do
            agents+=("$a")
        done < <(get_all_agents)
    fi
    
    for a in "${agents[@]}"; do
        local workspace=$(get_workspace "$a")
        local memory_file="$workspace/MEMORY.md"
        
        if [[ ! -f "$memory_file" ]]; then
            continue
        fi
        
        # Extract todos section
        local in_todos=false
        local todos=""
        
        while IFS= read -r line; do
            if [[ "$line" =~ ^##[[:space:]]+Todos ]]; then
                in_todos=true
                continue
            elif [[ "$line" =~ ^## && "$in_todos" == true ]]; then
                break
            elif [[ "$in_todos" == true && "$line" =~ ^-[[:space:]]\[([ x])\] ]]; then
                todos+="$line"$'\n'
            fi
        done < "$memory_file"
        
        if [[ -n "$todos" ]]; then
            echo "=== $a ==="
            echo "$todos"
        fi
    done
}

cmd_todo_status() {
    if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
        cat <<'EOF'
Usage: bobnet todo status

Show summary of todos across all agents.

OUTPUT:
  Total todos, completed, pending, by agent

EXAMPLE:
  bobnet todo status
EOF
        return 0
    fi
    
    local total=0 completed=0 pending=0
    local agent_summary=""
    
    # Get all agents
    local agents=()
    while IFS= read -r a; do
        agents+=("$a")
    done < <(get_all_agents)
    
    for agent in "${agents[@]}"; do
        local workspace=$(get_workspace "$agent")
        local memory_file="$workspace/MEMORY.md"
        
        if [[ ! -f "$memory_file" ]]; then
            continue
        fi
        
        # Count todos
        local agent_total=$(grep -c '^- \[[ x]\]' "$memory_file" 2>/dev/null || echo 0)
        local agent_completed=$(grep -c '^- \[x\]' "$memory_file" 2>/dev/null || echo 0)
        local agent_pending=$((agent_total - agent_completed))
        
        total=$((total + agent_total))
        completed=$((completed + agent_completed))
        pending=$((pending + agent_pending))
        
        if [[ $agent_total -gt 0 ]]; then
            agent_summary+="  $agent: $agent_pending pending, $agent_completed completed"$'\n'
        fi
    done
    
    echo "=== Todo Status ==="
    echo "Total: $total todos"
    echo "Pending: $pending"
    echo "Completed: $completed"
    echo
    
    if [[ -n "$agent_summary" ]]; then
        echo "By agent:"
        echo -n "$agent_summary"
    fi
}

cmd_todo_sync() {
    local dry_run=false
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)
                dry_run=true
                shift
                ;;
            -h|--help)
                cat <<'EOF'
Usage: bobnet todo sync [options]

Synchronize todos with GitHub issues (bidirectional).

SYNC BEHAVIOR:
  1. Agent todos with #issue → Update GitHub issue status
  2. GitHub issues with todo label → Create/update agent todos
  3. Completed todos → Close linked GitHub issues
  4. Closed issues → Mark linked todos as completed

ISSUE REFERENCE FORMATS:
  #123                    Local repo issue
  owner/repo#123          Cross-repo issue (full reference)

OPTIONS:
  --dry-run    Show what would be synced without making changes

EXAMPLES:
  bobnet todo sync --dry-run
  bobnet todo sync
EOF
                return 0
                ;;
            *)
                error "Unknown option: $1"
                ;;
        esac
    done
    
    echo "=== Todo Sync ==="
    [[ "$dry_run" == true ]] && echo "(Dry run - no changes will be made)"
    echo
    
    # Get all agents
    local agents=()
    while IFS= read -r a; do
        agents+=("$a")
    done < <(get_all_agents)
    
    local synced=0
    local skipped=0
    
    for agent in "${agents[@]}"; do
        local workspace=$(get_workspace "$agent")
        local memory_file="$workspace/MEMORY.md"
        
        if [[ ! -f "$memory_file" ]]; then
            continue
        fi
        
        # Extract todos with issue references
        local in_todos=false
        
        while IFS= read -r line; do
            if [[ "$line" =~ ^##[[:space:]]+Todos ]]; then
                in_todos=true
                continue
            elif [[ "$line" =~ ^## && "$in_todos" == true ]]; then
                break
            fi
            
            # Match both formats:
            # - Local: #123
            # - Full ref: owner/repo#123
            local status="" description="" issue_ref="" repo_ref="" issue_num=""
            
            if [[ "$in_todos" == true && "$line" =~ ^-[[:space:]]\[([ x])\][[:space:]]+(.+)[[:space:]]([a-zA-Z0-9_-]+/[a-zA-Z0-9_-]+)#([0-9]+) ]]; then
                # Full reference: owner/repo#123
                status="${BASH_REMATCH[1]}"
                description="${BASH_REMATCH[2]}"
                repo_ref="${BASH_REMATCH[3]}"
                issue_num="${BASH_REMATCH[4]}"
                issue_ref="$repo_ref#$issue_num"
            elif [[ "$in_todos" == true && "$line" =~ ^-[[:space:]]\[([ x])\][[:space:]]+(.+)#([0-9]+) ]]; then
                # Local reference: #123
                status="${BASH_REMATCH[1]}"
                description="${BASH_REMATCH[2]}"
                issue_num="${BASH_REMATCH[3]}"
                repo_ref=""
                issue_ref="#$issue_num"
            else
                continue
            fi
            
            # Build gh command with optional --repo
            local gh_repo_flag=""
            if [[ -n "$repo_ref" ]]; then
                gh_repo_flag="--repo $repo_ref"
            fi
            
            # Sync completed todos → close issues
            if [[ "$status" == "x" ]]; then
                echo "  $agent: Todo $issue_ref completed → would close issue"
                
                if [[ "$dry_run" == false ]]; then
                    # shellcheck disable=SC2086
                    gh issue close "$issue_num" $gh_repo_flag -c "Completed via agent todo sync" 2>/dev/null || {
                        warn "Failed to close issue $issue_ref"
                    }
                fi
                
                ((synced++))
            else
                echo "  $agent: Todo $issue_ref pending → would update issue"
                ((skipped++))
            fi
        done < "$memory_file"
    done
    
    echo
    echo "Sync complete:"
    echo "  Synced: $synced"
    echo "  Skipped: $skipped"
}

cmd_groupname() {
    local agent="${1:-}" status="${2:-}"
    
    case "${1:-help}" in
        -h|--help|help)
            cat <<'EOF'
Usage: bobnet groupname <agent> [status]

Update Signal group name to show agent activity status.

ARGUMENTS:
  agent               Agent name (bill, homer, bridget, etc.)
  status              Status suffix to show (optional)

EXAMPLES:
  bobnet groupname homer "working..."     # Sets "Homer [working...]"
  bobnet groupname homer "→ Bill"         # Sets "Homer [→ Bill]" 
  bobnet groupname homer "exec..."        # Sets "Homer [exec...]"
  bobnet groupname homer                  # Resets to "Homer"

STATUS PATTERNS:
  working...          Agent is executing tasks
  exec...             Running shell commands
  thinking...         Processing complex request
  → AgentName         Spawning sub-agent
  idle                Waiting for input

Zero message quota cost - only triggers system announcements.
EOF
            return 0
            ;;
        *)
            [[ -z "$agent" ]] && error "Usage: bobnet groupname <agent> [status]"
            ;;
    esac
    
    # Get agent's Signal group info from schema
    local group_id=$(jq -r --arg a "$agent" '.bindings[] | select(.agentId == $a and .channel == "signal" and .groupId) | .groupId' "$AGENTS_SCHEMA" 2>/dev/null)
    local base_name=$(jq -r --arg a "$agent" '.bindings[] | select(.agentId == $a and .channel == "signal" and .groupId) | .groupName' "$AGENTS_SCHEMA" 2>/dev/null)
    
    [[ -z "$group_id" || "$group_id" == "null" ]] && error "No Signal group found for agent '$agent'"
    [[ -z "$base_name" || "$base_name" == "null" ]] && base_name="$agent"
    
    # Get Signal account from schema
    local account=$(jq -r '.channels.signal.account // "+14439063521"' "$AGENTS_SCHEMA" 2>/dev/null)
    
    # Build new group name
    local new_name="$base_name"
    if [[ -n "$status" ]]; then
        new_name="$base_name [$status]"
    fi
    
    echo "Updating group name: $new_name"
    
    # Update via signal-cli JSON-RPC API (use jq -c for compact JSON with proper escaping)
    local rpc_payload=$(jq -nc \
        --arg account "$account" \
        --arg groupId "$group_id" \
        --arg name "$new_name" \
        '{jsonrpc:"2.0",id:1,method:"updateGroup",params:{$account,$groupId,name:$name}}')
    
    local rpc_response=$(curl -s -X POST -H "Content-Type: application/json" \
        -d "$rpc_payload" \
        http://127.0.0.1:8080/api/v1/rpc 2>/dev/null)
    
    local rpc_error=$(echo "$rpc_response" | jq -r '.error.message // empty' 2>/dev/null)
    
    if [[ -n "$rpc_error" ]]; then
        error "Signal API error: $rpc_error"
    else
        success "Group name updated to: $new_name"
    fi
}

cmd_help() {
    cat <<EOF
BobNet CLI v$BOBNET_CLI_VERSION

USAGE:
  bobnet <command> [options]

COMMANDS:
  status              Show agents and repo status
  report              Systems health check (disk, memory, services)
  install             Configure OpenClaw with BobNet agents
  uninstall           Remove BobNet config from OpenClaw
  validate            Validate BobNet configuration
  sync                Sync schema to OpenClaw config
  backup              Backup OpenClaw config to repo
  eject               Migrate agents to standard OpenClaw structure
  agent [cmd]         Manage agents (list, add)
  link [cmd]          Manage agent directory symlinks
  scope [cmd]         List scopes and agents
  binding [cmd]       Manage agent bindings
  groupname <agent>   Update Signal group name for status
  memory [cmd]        Manage memory search indexes (status, rebuild)
  groups [cmd]        Manage group registry (list, get, add, remove)
  int [cmd]           Run integrations (cursor)
  search [pattern]    Search session transcripts (grep)
  git [cmd]           Git attribution commands (commit, check)
  github [cmd]        GitHub integration (issues, milestones)
  todo [cmd]          Todo management and GitHub sync (list, status, sync)
  docs [cmd]          Documentation generation (roadmap, changelog, release)
  incident [cmd]      Incident tracking and post-mortems (create, close, list)
  signal [cmd]        Signal backup/restore
  unlock [key]        Unlock git-crypt
  lock                Lock git-crypt
  update              Update CLI to latest version
  restart             Restart gateway with broadcast warning
  upgrade             Upgrade OpenClaw with rollback support

Run 'bobnet <command> --help' for details.
EOF
}

bobnet_main() {
    case "${1:-help}" in
        status) cmd_status ;;
        report) shift; cmd_report "$@" ;;
        install|setup) shift; cmd_install "$@" ;;
        uninstall) shift; cmd_uninstall "$@" ;;
        eject) shift; cmd_eject "$@" ;;
        validate) shift; cmd_validate "$@" ;;
        sync) shift; cmd_sync "$@" ;;
        backup) shift; cmd_backup "$@" ;;
        agent) shift; cmd_agent "$@" ;;
        scope) shift; cmd_scope "$@" ;;
        binding) shift; cmd_binding "$@" ;;
        link) shift; cmd_link "$@" ;;
        groupname) shift; cmd_groupname "$@" ;;
        memory) shift; cmd_memory "$@" ;;
        groups) shift; cmd_groups "$@" ;;
        int) shift; cmd_int "$@" ;;
        proxy) shift; cmd_proxy "$@" ;;
        search) shift; cmd_search "$@" ;;
        git) shift; cmd_git "$@" ;;
        github) shift; cmd_github "$@" ;;
        todo) shift; cmd_todo "$@" ;;
        docs) shift; cmd_docs "$@" ;;
        incident) shift; cmd_incident "$@" ;;
        signal) shift; cmd_signal "$@" ;;
        unlock) shift; cmd_unlock "$@" ;;
        lock) cmd_lock ;;
        update) cmd_update ;;
        restart) shift; cmd_restart "$@" ;;
        upgrade) shift; cmd_upgrade "$@" ;;
        help|--help|-h) cmd_help ;;
        --version) echo "bobnet v$BOBNET_CLI_VERSION" ;;
        *) error "Unknown command: $1" ;;
    esac
}

# Note: bobnet_main is called by the wrapper script (~/.local/bin/bobnet)
# Do not call it here to avoid double execution
