#!/usr/bin/env bash
# Draft Management Functions for BobNet Email Security
# Part of Phase 5: Email Approval Workflow

set -euo pipefail

# Draft directory structure
get_draft_dir() {
    local user="${1:-$(get_current_user)}"
    echo "$HOME/.bobnet/email-drafts/$user"
}

# Generate draft ID
generate_draft_id() {
    echo "draft-$(date +%Y%m%d-%H%M%S)-$$"
}

# Save email draft
draft_save() {
    local to=""
    local subject=""
    local body=""
    local user="$(get_current_user)"
    local expires_min=60  # 1 hour default
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --to)
                to="$2"
                shift 2
                ;;
            --subject)
                subject="$2"
                shift 2
                ;;
            --body)
                body="$2"
                shift 2
                ;;
            --user)
                user="$2"
                shift 2
                ;;
            --expires)
                expires_min="$2"
                shift 2
                ;;
            -h|--help)
                cat <<'EOF'
USAGE: bobnet draft save --to <email> --subject <subject> --body <body> [OPTIONS]

Save an email draft for approval.

OPTIONS:
  --to <email>        Recipient email address (required)
  --subject <text>    Email subject line (required)
  --body <text>       Email body (required)
  --user <name>       User name (default: current user)
  --expires <min>     Expiration time in minutes (default: 60)

EXAMPLES:
  bobnet draft save --to taylor@example.com --subject "Meeting" --body "..."
  bobnet draft save --to client@example.com --subject "Proposal" --body "..." --expires 120

OUTPUT:
  Prints draft ID on success (use with bobnet draft show)
EOF
                return 0
                ;;
            *)
                error "Unknown argument: $1"
                ;;
        esac
    done
    
    # Validate required fields
    if [[ -z "$to" ]] || [[ -z "$subject" ]] || [[ -z "$body" ]]; then
        error "Missing required fields. Run 'bobnet draft save --help' for usage."
    fi
    
    # Classify content
    local info_class=$(classify_content "$body")
    
    # Get recipient trust score
    local trust_score=0.0
    local user_db=$(get_user_db "$user")
    if [[ -f "$user_db" ]]; then
        trust_score=$(sqlite3 "$user_db" \
            "SELECT COALESCE(trust_score, 0.0) FROM contacts WHERE email = '$to'" 2>/dev/null || echo "0.0")
    fi
    
    # Generate draft
    local draft_id=$(generate_draft_id)
    local draft_dir=$(get_draft_dir "$user")
    local draft_file="$draft_dir/$draft_id.json"
    
    mkdir -p "$draft_dir"
    
    local now=$(date +%s)
    local expires_at=$((now + expires_min * 60))
    
    # Create draft JSON
    jq -n \
        --arg id "$draft_id" \
        --arg user "$user" \
        --arg to "$to" \
        --arg subject "$subject" \
        --arg body "$body" \
        --arg info_class "$info_class" \
        --arg trust_score "$trust_score" \
        --arg created_at "$now" \
        --arg expires_at "$expires_at" \
        '{
            id: $id,
            user: $user,
            to: $to,
            subject: $subject,
            body: $body,
            info_class: $info_class,
            trust_score: ($trust_score | tonumber),
            created_at: ($created_at | tonumber),
            expires_at: ($expires_at | tonumber)
        }' > "$draft_file"
    
    echo "$draft_id"
}

# List drafts
draft_list() {
    local user="$(get_current_user)"
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --user)
                user="$2"
                shift 2
                ;;
            -h|--help)
                cat <<'EOF'
USAGE: bobnet draft list [OPTIONS]

List email drafts for approval.

OPTIONS:
  --user <name>       User name (default: current user)

EXAMPLES:
  bobnet draft list
  bobnet draft list --user penny
EOF
                return 0
                ;;
            *)
                error "Unknown argument: $1"
                ;;
        esac
    done
    
    local draft_dir=$(get_draft_dir "$user")
    
    if [[ ! -d "$draft_dir" ]]; then
        echo "No drafts found for user: $user"
        return 0
    fi
    
    local count=0
    echo "Email Drafts ($user):"
    echo "-------------------"
    
    for draft_file in "$draft_dir"/*.json; do
        [[ ! -f "$draft_file" ]] && continue
        
        local id=$(jq -r '.id' "$draft_file")
        local to=$(jq -r '.to' "$draft_file")
        local subject=$(jq -r '.subject' "$draft_file")
        local info_class=$(jq -r '.info_class' "$draft_file")
        local created_at=$(jq -r '.created_at' "$draft_file")
        local created_date=$(date -r "$created_at" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "$created_at")
        
        echo "[$id]"
        echo "  To: $to"
        echo "  Subject: $subject"
        echo "  Class: $info_class"
        echo "  Created: $created_date"
        echo ""
        
        ((count++))
    done
    
    if [[ $count -eq 0 ]]; then
        echo "No drafts found"
    else
        echo "Total: $count draft(s)"
    fi
}

# Show draft details
draft_show() {
    local draft_id="${1:-}"
    local user="$(get_current_user)"
    
    if [[ "$draft_id" == "--help" ]] || [[ "$draft_id" == "-h" ]]; then
        cat <<'EOF'
USAGE: bobnet draft show <draft-id> [OPTIONS]

Show email draft details.

ARGUMENTS:
  draft-id            Draft ID (from bobnet draft list)

OPTIONS:
  --user <name>       User name (default: current user)

EXAMPLES:
  bobnet draft show draft-20260209-123456
  bobnet draft show draft-20260209-123456 --user penny
EOF
        return 0
    fi
    
    # Check for --user flag
    if [[ "${2:-}" == "--user" ]]; then
        user="${3:-}"
    fi
    
    if [[ -z "$draft_id" ]]; then
        error "Draft ID required. Run 'bobnet draft show --help' for usage."
    fi
    
    local draft_dir=$(get_draft_dir "$user")
    local draft_file="$draft_dir/$draft_id.json"
    
    if [[ ! -f "$draft_file" ]]; then
        error "Draft not found: $draft_id"
    fi
    
    # Display draft with formatting
    local to=$(jq -r '.to' "$draft_file")
    local subject=$(jq -r '.subject' "$draft_file")
    local body=$(jq -r '.body' "$draft_file")
    local info_class=$(jq -r '.info_class' "$draft_file")
    local trust_score=$(jq -r '.trust_score' "$draft_file")
    local created_at=$(jq -r '.created_at' "$draft_file")
    local expires_at=$(jq -r '.expires_at' "$draft_file")
    local created_date=$(date -r "$created_at" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "$created_at")
    local expires_date=$(date -r "$expires_at" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "$expires_at")
    
    echo "Draft: $draft_id"
    echo "User: $user"
    echo "To: $to"
    echo "Subject: $subject"
    echo ""
    echo "Body:"
    echo "-----"
    echo "$body"
    echo "-----"
    echo ""
    echo "Classification: $info_class"
    echo "Trust Score: $trust_score"
    echo "Created: $created_date"
    echo "Expires: $expires_date"
}

# Delete draft
draft_delete() {
    local draft_id="${1:-}"
    local user="$(get_current_user)"
    
    if [[ "$draft_id" == "--help" ]] || [[ "$draft_id" == "-h" ]]; then
        cat <<'EOF'
USAGE: bobnet draft delete <draft-id> [OPTIONS]

Delete an email draft.

ARGUMENTS:
  draft-id            Draft ID (from bobnet draft list)

OPTIONS:
  --user <name>       User name (default: current user)

EXAMPLES:
  bobnet draft delete draft-20260209-123456
  bobnet draft delete draft-20260209-123456 --user penny
EOF
        return 0
    fi
    
    # Check for --user flag
    if [[ "${2:-}" == "--user" ]]; then
        user="${3:-}"
    fi
    
    if [[ -z "$draft_id" ]]; then
        error "Draft ID required. Run 'bobnet draft delete --help' for usage."
    fi
    
    local draft_dir=$(get_draft_dir "$user")
    local draft_file="$draft_dir/$draft_id.json"
    
    if [[ ! -f "$draft_file" ]]; then
        error "Draft not found: $draft_id"
    fi
    
    rm "$draft_file"
    success "Draft deleted: $draft_id"
}

# Classify content (detect sensitive information)
classify_content() {
    local text="$1"
    local highest_class="public"
    
    # Check for secret patterns (highest sensitivity)
    if echo "$text" | grep -Eiq 'password|api[_-]?key|token|secret|credentials'; then
        highest_class="secret"
    elif echo "$text" | grep -Eq '[A-Z0-9]{32,}'; then
        highest_class="secret"
    elif echo "$text" | grep -Eq '\b[0-9]{3}-[0-9]{2}-[0-9]{4}\b'; then
        highest_class="secret"  # SSN pattern
    # Check for sensitive patterns
    elif echo "$text" | grep -Eiq 'revenue|contract|salary|confidential'; then
        highest_class="sensitive"
    # Check for internal patterns
    elif echo "$text" | grep -Eq 'buildzero\.tech|Ice 9'; then
        highest_class="internal"
    # Check for technical-general
    elif echo "$text" | grep -Eiq 'OpenClaw|BobNet|GitHub|database|API'; then
        highest_class="technical-general"
    fi
    
    echo "$highest_class"
}

# Check if email should auto-send
draft_check_auto_send() {
    local to=""
    local body=""
    local user="$(get_current_user)"
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --to)
                to="$2"
                shift 2
                ;;
            --body)
                body="$2"
                shift 2
                ;;
            --user)
                user="$2"
                shift 2
                ;;
            -h|--help)
                cat <<'EOF'
USAGE: bobnet draft check-auto-send --to <email> --body <text> [OPTIONS]

Check if email should auto-send based on trust and content.

OPTIONS:
  --to <email>        Recipient email address (required)
  --body <text>       Email body (required)
  --user <name>       User name (default: current user)

EXIT CODES:
  0                   Auto-send eligible
  1                   Draft-first required

EXAMPLES:
  if bobnet draft check-auto-send --to taylor@example.com --body "Meeting at 3pm"; then
    echo "Auto-send"
  else
    echo "Requires approval"
  fi
EOF
                return 0
                ;;
            *)
                error "Unknown argument: $1"
                ;;
        esac
    done
    
    # Validate required fields
    if [[ -z "$to" ]] || [[ -z "$body" ]]; then
        error "Missing required fields. Run 'bobnet draft check-auto-send --help' for usage."
    fi
    
    # Get contact trust score and auto-send flag
    local user_db=$(get_user_db "$user")
    if [[ ! -f "$user_db" ]]; then
        echo "draft-first"
        return 1
    fi
    
    local contact_data=$(sqlite3 "$user_db" \
        "SELECT trust_score, auto_send FROM contacts WHERE email = '$to'" 2>/dev/null || echo "")
    
    if [[ -z "$contact_data" ]]; then
        echo "draft-first"
        return 1
    fi
    
    local trust_score=$(echo "$contact_data" | cut -d'|' -f1)
    local auto_send=$(echo "$contact_data" | cut -d'|' -f2)
    
    # Classify content
    local info_class=$(classify_content "$body")
    
    # Auto-send eligibility check
    if [[ "$auto_send" -eq 1 ]] && \
       awk "BEGIN {exit !($trust_score >= 0.7)}" && \
       [[ "$info_class" != "sensitive" ]] && [[ "$info_class" != "secret" ]]; then
        echo "auto-send"
        return 0
    else
        echo "draft-first"
        return 1
    fi
}
