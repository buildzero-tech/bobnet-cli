#!/usr/bin/env bash
# migrate-area-registry.sh - Create area registry tables
#
# Usage: migrate-area-registry.sh [--seed]
#
# Creates the area registry tables in the BobNet todo database.
# Use --seed to also populate with initial areas.

set -e

BOBNET_ROOT="${BOBNET_ROOT:-$HOME/.bobnet/ultima-thule}"
DB_PATH="$BOBNET_ROOT/vault/data/todos.db"

RED='\033[0;31m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; NC='\033[0m'
error() { echo -e "${RED}error:${NC} $*" >&2; exit 1; }
success() { echo -e "${GREEN}✓${NC} $*"; }
info() { echo -e "${BLUE}→${NC} $*"; }

# Check database exists
[[ -f "$DB_PATH" ]] || error "Database not found at $DB_PATH. Run todo-app first to create it."

# Check if migration already applied
check_migration() {
    local table_exists=$(sqlite3 "$DB_PATH" "SELECT name FROM sqlite_master WHERE type='table' AND name='areas';" 2>/dev/null)
    [[ -n "$table_exists" ]]
}

# Apply migration
apply_migration() {
    info "Creating area registry tables..."
    
    sqlite3 "$DB_PATH" <<'SQL'
-- Area Registry (semantic layer over bobnet.json)
CREATE TABLE IF NOT EXISTS areas (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    scope TEXT NOT NULL,
    owner_agent TEXT,
    description TEXT,
    signal_group_id TEXT,
    sync_config TEXT,
    created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now') * 1000),
    updated_at INTEGER
);

-- Indexes for queries
CREATE INDEX IF NOT EXISTS idx_areas_scope ON areas(scope);
CREATE INDEX IF NOT EXISTS idx_areas_owner_agent ON areas(owner_agent);
CREATE INDEX IF NOT EXISTS idx_areas_signal_group ON areas(signal_group_id);

-- Area Collaborators
CREATE TABLE IF NOT EXISTS area_collaborators (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    area_id TEXT NOT NULL,
    collaborator_type TEXT NOT NULL CHECK (collaborator_type IN ('agent', 'user')),
    collaborator_id TEXT NOT NULL,
    role TEXT NOT NULL CHECK (role IN ('owner', 'collaborator', 'viewer')),
    created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now') * 1000),
    FOREIGN KEY (area_id) REFERENCES areas(id) ON DELETE CASCADE,
    UNIQUE(area_id, collaborator_type, collaborator_id)
);

CREATE INDEX IF NOT EXISTS idx_collaborators_area ON area_collaborators(area_id);
CREATE INDEX IF NOT EXISTS idx_collaborators_user ON area_collaborators(collaborator_type, collaborator_id);

-- User Area Defaults
CREATE TABLE IF NOT EXISTS user_area_defaults (
    user_id TEXT PRIMARY KEY,
    default_work_area TEXT,
    default_personal_area TEXT,
    created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now') * 1000),
    updated_at INTEGER,
    FOREIGN KEY (default_work_area) REFERENCES areas(id),
    FOREIGN KEY (default_personal_area) REFERENCES areas(id)
);

-- Migration version tracking
CREATE TABLE IF NOT EXISTS migrations (
    id TEXT PRIMARY KEY,
    applied_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now') * 1000)
);

INSERT OR IGNORE INTO migrations (id) VALUES ('area-registry-v1');
SQL
    
    success "Area registry tables created"
}

# Seed initial areas
seed_areas() {
    info "Seeding initial areas..."
    
    sqlite3 "$DB_PATH" <<'SQL'
-- Work areas
INSERT OR IGNORE INTO areas (id, name, scope, owner_agent, description)
VALUES 
    ('ice9', 'Ice9 Productions', 'work', 'bob', 'Primary consulting client'),
    ('buildzero', 'BuildZero', 'work', 'bob', 'BuildZero LLC projects and admin');

-- Personal areas
INSERT OR IGNORE INTO areas (id, name, scope, owner_agent, description)
VALUES 
    ('household', 'Household', 'personal', 'olivia', 'Family household tasks and chores'),
    ('family', 'Family', 'personal', 'olivia', 'Family activities and planning');

-- Add James as owner collaborator on all areas
INSERT OR IGNORE INTO area_collaborators (area_id, collaborator_type, collaborator_id, role)
VALUES 
    ('ice9', 'user', 'james', 'owner'),
    ('buildzero', 'user', 'james', 'owner'),
    ('household', 'user', 'james', 'owner'),
    ('family', 'user', 'james', 'owner');

-- Add Penny as collaborator on personal areas
INSERT OR IGNORE INTO area_collaborators (area_id, collaborator_type, collaborator_id, role)
VALUES 
    ('household', 'user', 'penny', 'collaborator'),
    ('family', 'user', 'penny', 'collaborator');

-- Add Bob as collaborator on work areas (as agent)
INSERT OR IGNORE INTO area_collaborators (area_id, collaborator_type, collaborator_id, role)
VALUES 
    ('ice9', 'agent', 'bob', 'owner'),
    ('buildzero', 'agent', 'bob', 'owner');

-- Add Olivia as collaborator on personal areas (as agent)
INSERT OR IGNORE INTO area_collaborators (area_id, collaborator_type, collaborator_id, role)
VALUES 
    ('household', 'agent', 'olivia', 'owner'),
    ('family', 'agent', 'olivia', 'owner');

-- Set James's defaults
INSERT OR IGNORE INTO user_area_defaults (user_id, default_work_area, default_personal_area)
VALUES ('james', 'ice9', 'household');

-- Set Penny's defaults
INSERT OR IGNORE INTO user_area_defaults (user_id, default_work_area, default_personal_area)
VALUES ('penny', NULL, 'household');
SQL
    
    success "Initial areas seeded"
}

# Main
main() {
    echo "BobNet Area Registry Migration"
    echo "==============================="
    echo ""
    echo "Database: $DB_PATH"
    echo ""
    
    if check_migration; then
        info "Migration already applied"
    else
        apply_migration
    fi
    
    if [[ "$1" == "--seed" ]]; then
        seed_areas
    fi
    
    echo ""
    info "Current areas:"
    sqlite3 -header -column "$DB_PATH" "SELECT id, name, scope, owner_agent FROM areas;"
}

main "$@"
