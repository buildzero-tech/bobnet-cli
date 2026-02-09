#!/usr/bin/env bash
# User Management Functions for BobNet Email Security
# Part of Phase 4: Multi-User RBAC

set -euo pipefail

# Get current user from environment or config
get_current_user() {
  local user="${BOBNET_USER:-}"
  
  if [ -z "$user" ]; then
    # Fallback: read from config
    local config_file="${BOBNET_CONFIG:-$HOME/.bobnet/config.json}"
    if [ -f "$config_file" ]; then
      user=$(jq -r '.default_user // "james"' "$config_file" 2>/dev/null || echo "james")
    else
      user="james"
    fi
  fi
  
  echo "$user"
}

# Get user database path
get_user_db() {
  local username="${1:-$(get_current_user)}"
  local config_dir="${BOBNET_CONFIG_DIR:-$HOME/.bobnet/config}"
  echo "$config_dir/trust-registry-${username}.db"
}

# Check if user exists
user_exists() {
  local username="$1"
  local db=$(get_user_db)
  
  local count=$(sqlite3 "$db" \
    "SELECT COUNT(*) FROM users WHERE username = '$username'" 2>/dev/null || echo "0")
  
  [ "$count" -gt 0 ]
}

# Add new user
cmd_user_add() {
  local username=""
  local email=""
  local role="read-only"
  local contact_email=""
  
  # Parse arguments
  while [ $# -gt 0 ]; do
    case "$1" in
      --email)
        email="$2"
        shift 2
        ;;
      --role)
        role="$2"
        shift 2
        ;;
      --contact)
        contact_email="$2"
        shift 2
        ;;
      *)
        if [ -z "$username" ]; then
          username="$1"
        else
          echo "Error: Unknown argument: $1" >&2
          return 1
        fi
        shift
        ;;
    esac
  done
  
  # Validate inputs
  if [ -z "$username" ] || [ -z "$email" ]; then
    echo "Error: Username and email are required" >&2
    echo "Usage: bobnet user add <username> --email <email> [--role <role>] [--contact <email>]" >&2
    return 1
  fi
  
  # Validate role
  case "$role" in
    owner|family|delegate|read-only) ;;
    *)
      echo "Error: Invalid role '$role'" >&2
      echo "Valid roles: owner, family, delegate, read-only" >&2
      return 1
      ;;
  esac
  
  # Get admin database (system-wide user registry)
  local admin_db=$(get_user_db "admin")
  local config_dir="${BOBNET_CONFIG_DIR:-$HOME/.bobnet/config}"
  mkdir -p "$config_dir"
  
  # Initialize admin database if needed
  if [ ! -f "$admin_db" ]; then
    echo "Initializing system user registry..."
    sqlite3 "$admin_db" < ~/.bobnet/ultima-thule/scripts/sql/trust-registry-schema.sql
  fi
  
  # Check if user already exists
  if user_exists "$username"; then
    echo "Error: User '$username' already exists" >&2
    return 1
  fi
  
  # Find or create contact
  local contact_id=""
  if [ -n "$contact_email" ]; then
    contact_id=$(sqlite3 "$admin_db" \
      "SELECT id FROM contacts WHERE email = '$contact_email' LIMIT 1" 2>/dev/null || echo "")
    
    if [ -z "$contact_id" ]; then
      # Create contact first
      sqlite3 "$admin_db" <<EOF
INSERT INTO contacts (email, name, trust_level, trust_score, created_at, updated_at)
VALUES ('$contact_email', '$username', 'owner', 1.0, strftime('%s', 'now'), strftime('%s', 'now'));
EOF
      contact_id=$(sqlite3 "$admin_db" "SELECT last_insert_rowid()")
    fi
  fi
  
  # Add user
  if [ -n "$contact_id" ]; then
    sqlite3 "$admin_db" <<EOF
INSERT INTO users (username, email, role, contact_id, created_at, active)
VALUES ('$username', '$email', '$role', $contact_id, strftime('%s', 'now'), 1);
EOF
  else
    sqlite3 "$admin_db" <<EOF
INSERT INTO users (username, email, role, created_at, active)
VALUES ('$username', '$email', '$role', strftime('%s', 'now'), 1);
EOF
  fi
  
  echo "✓ User added: $username ($email)"
  echo "  Role: $role"
  [ -n "$contact_id" ] && echo "  Contact ID: $contact_id"
  
  # Initialize user's personal trust registry
  local user_db=$(get_user_db "$username")
  if [ ! -f "$user_db" ]; then
    echo "Initializing trust registry for $username..."
    sqlite3 "$user_db" < ~/.bobnet/ultima-thule/scripts/sql/trust-registry-schema.sql
    echo "✓ Trust registry created: $user_db"
  fi
}

# List users
cmd_user_list() {
  local show_inactive=false
  
  # Parse arguments
  while [ $# -gt 0 ]; do
    case "$1" in
      --all|-a)
        show_inactive=true
        shift
        ;;
      *)
        echo "Error: Unknown argument: $1" >&2
        return 1
        ;;
    esac
  done
  
  local admin_db=$(get_user_db "admin")
  
  if [ ! -f "$admin_db" ]; then
    echo "No users registered" >&2
    return 0
  fi
  
  local where_clause="WHERE active = 1"
  if [ "$show_inactive" = true ]; then
    where_clause=""
  fi
  
  echo "Users:"
  echo "------"
  
  sqlite3 "$admin_db" <<EOF | column -t -s '|'
.mode list
.separator '|'
SELECT 
  username,
  email,
  role,
  CASE WHEN active = 1 THEN 'active' ELSE 'inactive' END as status
FROM users
$where_clause
ORDER BY created_at;
EOF
}

# Show user details
cmd_user_show() {
  local username="${1:-}"
  
  if [ -z "$username" ]; then
    echo "Error: Username required" >&2
    echo "Usage: bobnet user show <username>" >&2
    return 1
  fi
  
  local admin_db=$(get_user_db "admin")
  
  if [ ! -f "$admin_db" ]; then
    echo "Error: No users registered" >&2
    return 1
  fi
  
  local user_data=$(sqlite3 "$admin_db" <<EOF
SELECT 
  u.username,
  u.email,
  u.role,
  u.active,
  u.created_at,
  u.deactivated_at,
  COALESCE(c.email, '') as contact_email,
  COALESCE(c.trust_score, 0) as trust_score
FROM users u
LEFT JOIN contacts c ON u.contact_id = c.id
WHERE u.username = '$username';
EOF
)
  
  if [ -z "$user_data" ]; then
    echo "Error: User '$username' not found" >&2
    return 1
  fi
  
  local IFS='|'
  read -r user email role active created_at deactivated_at contact_email trust_score <<< "$user_data"
  
  echo "User: $user"
  echo "Email: $email"
  echo "Role: $role"
  echo "Status: $([ "$active" = "1" ] && echo "active" || echo "inactive")"
  echo "Created: $(date -r "$created_at" '+%Y-%m-%d %H:%M:%S')"
  [ -n "$deactivated_at" ] && echo "Deactivated: $(date -r "$deactivated_at" '+%Y-%m-%d %H:%M:%S')"
  [ -n "$contact_email" ] && echo "Contact: $contact_email (trust: $trust_score)"
  
  # Show bound agents
  echo ""
  echo "Bound Agents:"
  sqlite3 "$admin_db" <<EOF | sed 's/^/  - /'
SELECT agent_id FROM agent_bindings 
WHERE user_id = (SELECT id FROM users WHERE username = '$username')
ORDER BY created_at;
EOF
}

# Bind agent to user
cmd_user_bind_agent() {
  local agent_id=""
  local username=""
  
  # Parse arguments
  while [ $# -gt 0 ]; do
    case "$1" in
      *)
        if [ -z "$agent_id" ]; then
          agent_id="$1"
        elif [ -z "$username" ]; then
          username="$1"
        else
          echo "Error: Too many arguments" >&2
          return 1
        fi
        shift
        ;;
    esac
  done
  
  if [ -z "$agent_id" ] || [ -z "$username" ]; then
    echo "Error: Agent ID and username are required" >&2
    echo "Usage: bobnet user bind-agent <agent-id> <username>" >&2
    return 1
  fi
  
  local admin_db=$(get_user_db "admin")
  
  if [ ! -f "$admin_db" ]; then
    echo "Error: No users registered" >&2
    return 1
  fi
  
  # Check if user exists
  local user_id=$(sqlite3 "$admin_db" \
    "SELECT id FROM users WHERE username = '$username'" 2>/dev/null || echo "")
  
  if [ -z "$user_id" ]; then
    echo "Error: User '$username' not found" >&2
    return 1
  fi
  
  # Check if binding already exists
  local existing=$(sqlite3 "$admin_db" \
    "SELECT COUNT(*) FROM agent_bindings WHERE user_id = $user_id AND agent_id = '$agent_id'")
  
  if [ "$existing" -gt 0 ]; then
    echo "✓ Agent '$agent_id' already bound to user '$username'"
    return 0
  fi
  
  # Add binding
  sqlite3 "$admin_db" <<EOF
INSERT INTO agent_bindings (user_id, agent_id, created_at)
VALUES ($user_id, '$agent_id', strftime('%s', 'now'));
EOF
  
  echo "✓ Bound agent '$agent_id' to user '$username'"
}

# Deactivate user
cmd_user_deactivate() {
  local username="${1:-}"
  
  if [ -z "$username" ]; then
    echo "Error: Username required" >&2
    echo "Usage: bobnet user deactivate <username>" >&2
    return 1
  fi
  
  local admin_db=$(get_user_db "admin")
  
  if [ ! -f "$admin_db" ]; then
    echo "Error: No users registered" >&2
    return 1
  fi
  
  # Check if user exists
  if ! user_exists "$username"; then
    echo "Error: User '$username' not found" >&2
    return 1
  fi
  
  # Deactivate user
  sqlite3 "$admin_db" <<EOF
UPDATE users
SET active = 0,
    deactivated_at = strftime('%s', 'now')
WHERE username = '$username';
EOF
  
  echo "✓ User '$username' deactivated"
  echo "  Trust registry preserved at: $(get_user_db "$username")"
}

# Permission check function
check_permission() {
  local operation="$1"
  local user="${2:-$(get_current_user)}"
  
  local admin_db=$(get_user_db "admin")
  
  if [ ! -f "$admin_db" ]; then
    # No RBAC system initialized, allow all (backward compatibility)
    return 0
  fi
  
  # Get user role
  local role=$(sqlite3 "$admin_db" \
    "SELECT role FROM users WHERE username = '$user' AND active = 1" 2>/dev/null || echo "")
  
  if [ -z "$role" ]; then
    # User not in system - default to read-only
    role="read-only"
  fi
  
  # Check permission matrix
  case "$role:$operation" in
    # Owner has all permissions
    owner:*)
      return 0
      ;;
    
    # Family permissions
    family:contact_add|\
    family:contact_view|\
    family:contact_archive|\
    family:contact_restore|\
    family:email_send|\
    family:email_draft|\
    family:email_approve|\
    family:audit_view_own|\
    family:sync_google)
      return 0
      ;;
    
    # Delegate permissions
    delegate:email_send|\
    delegate:email_draft|\
    delegate:contact_view|\
    delegate:audit_view_own)
      return 0
      ;;
    
    # Read-only permissions
    read-only:contact_view|\
    read-only:audit_view_own|\
    read-only:user_list)
      return 0
      ;;
    
    # Denied
    *)
      echo "Error: Permission denied - $operation requires different role (current: $role)" >&2
      return 1
      ;;
  esac
}
