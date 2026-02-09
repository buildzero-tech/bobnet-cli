#!/bin/bash
# Trust Lifecycle Commands (Phase 2: Contact Lifecycle Management)
# To be integrated into bobnet.sh

trust_archive() {
    local email=""
    local user="$USER"
    local reason=""
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --user) user="$2"; shift 2 ;;
            --reason) reason="$2"; shift 2 ;;
            -h|--help)
                cat <<'EOF'
USAGE: bobnet trust archive <email> [OPTIONS]

Archive a contact (remove from active list, preserve data).

OPTIONS:
  --user <name>      User name (default: current user)
  --reason <text>    Reason for archiving

EXAMPLES:
  bobnet trust archive old-contact@example.com
  bobnet trust archive taylor@example.com --reason "No longer working with"
EOF
                return 0 ;;
            *)
                if [[ -z "$email" ]]; then
                    email="$1"
                fi
                shift ;;
        esac
    done
    
    [[ -z "$email" ]] && error "Email required. Usage: bobnet trust archive <email>"
    
    local registry_db="$BOBNET_ROOT/config/trust-registry-$user.db"
    [[ ! -f "$registry_db" ]] && error "Trust registry not found. Run: bobnet trust init"
    
    # Check if contact exists and is active
    local state=$(sqlite3 "$registry_db" "SELECT state FROM contacts WHERE email = '$email';")
    [[ -z "$state" ]] && error "Contact not found: $email"
    [[ "$state" != "active" ]] && error "Contact is already $state"
    
    # Archive the contact
    sqlite3 "$registry_db" <<EOF
UPDATE contacts 
SET state = 'archived',
    archived_at = strftime('%s', 'now'),
    archived_reason = '$reason',
    updated_at = strftime('%s', 'now')
WHERE email = '$email';
EOF
    
    success "Archived $email"
}

trust_restore() {
    local email=""
    local user="$USER"
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --user) user="$2"; shift 2 ;;
            -h|--help)
                cat <<'EOF'
USAGE: bobnet trust restore <email> [OPTIONS]

Restore an archived or deleted contact to active state.

OPTIONS:
  --user <name>      User name (default: current user)

EXAMPLES:
  bobnet trust restore taylor@example.com
EOF
                return 0 ;;
            *)
                if [[ -z "$email" ]]; then
                    email="$1"
                fi
                shift ;;
        esac
    done
    
    [[ -z "$email" ]] && error "Email required. Usage: bobnet trust restore <email>"
    
    local registry_db="$BOBNET_ROOT/config/trust-registry-$user.db"
    [[ ! -f "$registry_db" ]] && error "Trust registry not found. Run: bobnet trust init"
    
    # Check contact state
    local state deleted_at
    read -r state deleted_at <<< $(sqlite3 "$registry_db" \
        "SELECT state, deleted_at FROM contacts WHERE email = '$email';")
    
    [[ -z "$state" ]] && error "Contact not found: $email"
    [[ "$state" == "active" ]] && error "Contact is already active"
    
    # Check if past retention period (90 days)
    if [[ "$state" == "deleted" && -n "$deleted_at" ]]; then
        local now=$(date +%s)
        local days_deleted=$(( (now - deleted_at) / 86400 ))
        
        if [[ $days_deleted -gt 90 ]]; then
            error "Cannot restore $email (past 90-day retention period)"
        fi
    fi
    
    # Restore contact
    sqlite3 "$registry_db" <<EOF
UPDATE contacts
SET state = 'active',
    archived_at = NULL,
    archived_reason = NULL,
    deleted_at = NULL,
    updated_at = strftime('%s', 'now')
WHERE email = '$email';
EOF
    
    success "Restored $email to active"
}

trust_delete() {
    local email=""
    local user="$USER"
    local permanent=false
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --user) user="$2"; shift 2 ;;
            --permanent) permanent=true; shift ;;
            -h|--help)
                cat <<'EOF'
USAGE: bobnet trust delete <email> [OPTIONS]

Soft-delete a contact (restorable for 90 days) or permanently delete.

OPTIONS:
  --user <name>      User name (default: current user)
  --permanent        Permanently delete (not restorable)

EXAMPLES:
  bobnet trust delete spam@example.com
  bobnet trust delete old-contact@example.com --permanent
EOF
                return 0 ;;
            *)
                if [[ -z "$email" ]]; then
                    email="$1"
                fi
                shift ;;
        esac
    done
    
    [[ -z "$email" ]] && error "Email required. Usage: bobnet trust delete <email>"
    
    local registry_db="$BOBNET_ROOT/config/trust-registry-$user.db"
    [[ ! -f "$registry_db" ]] && error "Trust registry not found. Run: bobnet trust init"
    
    # Check if contact exists
    local exists=$(sqlite3 "$registry_db" "SELECT 1 FROM contacts WHERE email = '$email';")
    [[ -z "$exists" ]] && error "Contact not found: $email"
    
    if [[ "$permanent" == "true" ]]; then
        # Hard delete
        sqlite3 "$registry_db" "DELETE FROM contacts WHERE email = '$email';"
        success "Permanently deleted $email"
    else
        # Soft delete
        sqlite3 "$registry_db" <<EOF
UPDATE contacts
SET state = 'deleted',
    deleted_at = strftime('%s', 'now'),
    updated_at = strftime('%s', 'now')
WHERE email = '$email';
EOF
        success "Soft-deleted $email (restorable for 90 days)"
    fi
}

trust_cleanup() {
    local user="$USER"
    local dry_run=false
    local auto_yes=false
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --user) user="$2"; shift 2 ;;
            --dry-run) dry_run=true; shift ;;
            --yes|-y) auto_yes=true; shift ;;
            -h|--help)
                cat <<'EOF'
USAGE: bobnet trust cleanup [OPTIONS]

Cleanup stale contacts based on decision tree:
- Archive: 2+ years inactive, external source, trust >= 0.0
- Delete: 2+ years inactive, manual add, trust = 0.0
- Delete: trust < -0.5 (blocked)

OPTIONS:
  --user <name>      User name (default: current user)
  --dry-run          Show what would be done without doing it
  --yes, -y          Skip confirmation prompts

EXAMPLES:
  bobnet trust cleanup --dry-run
  bobnet trust cleanup --yes
EOF
                return 0 ;;
            *) shift ;;
        esac
    done
    
    local registry_db="$BOBNET_ROOT/config/trust-registry-$user.db"
    [[ ! -f "$registry_db" ]] && error "Trust registry not found. Run: bobnet trust init"
    
    echo "=== Contact Cleanup Decision Tree ==="
    echo ""
    
    # Rule 1: Archive stale external contacts
    echo "📦 Archive candidates (stale external contacts):"
    local archive_candidates=$(sqlite3 "$registry_db" -separator $'\t' <<'EOF'
SELECT email, name, trust_score, 
       (strftime('%s', 'now') - COALESCE(last_interaction_at, created_at)) / 86400 AS days_inactive
FROM contacts
WHERE state = 'active'
  AND ((strftime('%s', 'now') - COALESCE(last_interaction_at, created_at)) / 86400) >= 730
  AND trust_score >= 0.0
  AND EXISTS (SELECT 1 FROM contact_sources WHERE contact_id = contacts.id);
EOF
)
    
    if [[ -n "$archive_candidates" ]]; then
        echo "$archive_candidates" | while IFS=$'\t' read -r email name score days; do
            echo "  $email ($name) - trust: $score, inactive: ${days} days"
        done
        
        local archive_count=$(echo "$archive_candidates" | wc -l)
        
        if [[ "$dry_run" == "false" ]]; then
            if [[ "$auto_yes" == "false" ]]; then
                read -p "Archive $archive_count contact(s)? [y/N] " -n 1 -r
                echo
                [[ ! $REPLY =~ ^[Yy]$ ]] && echo "Skipped." && return 0
            fi
            
            sqlite3 "$registry_db" <<'EOF'
UPDATE contacts
SET state = 'archived',
    archived_at = strftime('%s', 'now'),
    archived_reason = 'Automatic cleanup (2+ years inactive)',
    updated_at = strftime('%s', 'now')
WHERE state = 'active'
  AND ((strftime('%s', 'now') - COALESCE(last_interaction_at, created_at)) / 86400) >= 730
  AND trust_score >= 0.0
  AND EXISTS (SELECT 1 FROM contact_sources WHERE contact_id = contacts.id);
EOF
            success "Archived $archive_count contact(s)"
        fi
    else
        echo "  No candidates found"
    fi
    
    echo ""
    
    # Rule 2: Delete stale manual contacts with zero trust
    echo "🗑️  Delete candidates (stale manual, zero trust):"
    local delete_manual=$(sqlite3 "$registry_db" -separator $'\t' <<'EOF'
SELECT email, name, trust_score,
       (strftime('%s', 'now') - COALESCE(last_interaction_at, created_at)) / 86400 AS days_inactive
FROM contacts
WHERE state = 'active'
  AND ((strftime('%s', 'now') - COALESCE(last_interaction_at, created_at)) / 86400) >= 730
  AND trust_score = 0.0
  AND NOT EXISTS (SELECT 1 FROM contact_sources WHERE contact_id = contacts.id);
EOF
)
    
    if [[ -n "$delete_manual" ]]; then
        echo "$delete_manual" | while IFS=$'\t' read -r email name score days; do
            echo "  $email ($name) - trust: $score, inactive: ${days} days"
        done
        
        local delete_count=$(echo "$delete_manual" | wc -l)
        
        if [[ "$dry_run" == "false" ]]; then
            if [[ "$auto_yes" == "false" ]]; then
                read -p "Delete $delete_count contact(s)? [y/N] " -n 1 -r
                echo
                [[ ! $REPLY =~ ^[Yy]$ ]] && echo "Skipped." && return 0
            fi
            
            sqlite3 "$registry_db" <<'EOF'
UPDATE contacts
SET state = 'deleted',
    deleted_at = strftime('%s', 'now'),
    updated_at = strftime('%s', 'now')
WHERE state = 'active'
  AND ((strftime('%s', 'now') - COALESCE(last_interaction_at, created_at)) / 86400) >= 730
  AND trust_score = 0.0
  AND NOT EXISTS (SELECT 1 FROM contact_sources WHERE contact_id = contacts.id);
EOF
            success "Deleted $delete_count contact(s)"
        fi
    else
        echo "  No candidates found"
    fi
    
    echo ""
    
    # Rule 3: Delete blocked contacts
    echo "🚫 Delete candidates (blocked, trust < -0.5):"
    local delete_blocked=$(sqlite3 "$registry_db" -separator $'\t' \
        "SELECT email, name, trust_score FROM contacts WHERE state = 'active' AND trust_score < -0.5;")
    
    if [[ -n "$delete_blocked" ]]; then
        echo "$delete_blocked" | while IFS=$'\t' read -r email name score; do
            echo "  $email ($name) - trust: $score"
        done
        
        local blocked_count=$(echo "$delete_blocked" | wc -l)
        
        if [[ "$dry_run" == "false" ]]; then
            if [[ "$auto_yes" == "false" ]]; then
                read -p "Delete $blocked_count blocked contact(s)? [y/N] " -n 1 -r
                echo
                [[ ! $REPLY =~ ^[Yy]$ ]] && echo "Skipped." && return 0
            fi
            
            sqlite3 "$registry_db" <<'EOF'
UPDATE contacts
SET state = 'deleted',
    deleted_at = strftime('%s', 'now'),
    updated_at = strftime('%s', 'now')
WHERE state = 'active' AND trust_score < -0.5;
EOF
            success "Deleted $blocked_count contact(s)"
        fi
    else
        echo "  No candidates found"
    fi
    
    echo ""
    echo "=== Cleanup complete ==="
}
