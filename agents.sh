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
get_spawn_permissions() {
    local agent="$1"
    local spawning_model=$(jq -r '.spawning.model // "default"' "$AGENTS_SCHEMA")
    local perms=""
    
    if [[ "$spawning_model" == "hub-and-spoke" ]]; then
        local hub=$(jq -r '.spawning.hub // "bob"' "$AGENTS_SCHEMA")
        if [[ "$agent" == "$hub" ]]; then
            perms=$(jq -c ".spawning.permissions.bob // []" "$AGENTS_SCHEMA")
        elif [[ "$agent" == "guppi" ]]; then
            perms=$(jq -c ".spawning.permissions.guppi // [\"bob\"]" "$AGENTS_SCHEMA")
        else
            perms=$(jq -c ".spawning.permissions.default // [\"bob\", \"guppi\"]" "$AGENTS_SCHEMA")
        fi
    else
        perms=$(jq -c ".spawning.permissions[\"$agent\"] // .spawning.permissions.default // []" "$AGENTS_SCHEMA")
    fi
    
    [[ "$perms" != "[]" && "$perms" != "null" ]] && echo "$perms"
}

expand_model_alias() {
    local model="$1"
    case "$model" in
        opus)   echo "anthropic/claude-opus-4-5" ;;
        sonnet) echo "anthropic/claude-sonnet-4-20250514" ;;
        haiku)  echo "anthropic/claude-haiku-4-5" ;;
        "")     ;; # No model
        *)      echo "$model" ;; # Already full name
    esac
}

get_default_model() {
    local model=$(jq -r '.defaults.model // empty' "$AGENTS_SCHEMA")
    expand_model_alias "$model"
}

get_agent_model() {
    local agent="$1"
    local model=$(jq -r ".agents[\"$agent\"].model // empty" "$AGENTS_SCHEMA")
    expand_model_alias "$model"
}

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
