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
  • Apply spawn permissions (subagents.allowAgents)
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
    
    # Rebuild agents list with spawn permissions + model
    local list='[' first=true
    for agent in $(get_all_agents); do
        local id="$agent"
        local is_default=$(jq -r --arg a "$agent" '.agents[$a].default // false' "$AGENTS_SCHEMA")
        local spawn_perms=$(get_spawn_permissions "$agent")
        local model=$(get_agent_model "$agent")
        $first || list+=','; first=false
        list+="{\"id\":\"$id\",\"workspace\":\"$(get_workspace "$agent")\",\"agentDir\":\"$(get_agent_dir "$agent")\""
        [[ "$is_default" == "true" ]] && list+=",\"default\":true"
        [[ -n "$model" ]] && list+=",\"model\":\"$model\""
        [[ -n "$spawn_perms" ]] && list+=",\"subagents\":{\"allowAgents\":$spawn_perms}"
        list+="}"
    done
    list+=']'
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
  scope [cmd]         List scopes and agents
  binding [cmd]       Manage agent bindings
  memory [cmd]        Manage memory search indexes (status, rebuild)
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
        memory) shift; cmd_memory "$@" ;;
        signal) shift; cmd_signal "$@" ;;
        unlock) shift; cmd_unlock "$@" ;;
        lock) cmd_lock ;;
        update) cmd_update ;;
        help|--help|-h) cmd_help ;;
        --version) echo "bobnet v$BOBNET_CLI_VERSION" ;;
        *) error "Unknown command: $1" ;;
    esac
}
