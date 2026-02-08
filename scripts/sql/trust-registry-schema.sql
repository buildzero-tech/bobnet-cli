-- Trust Registry Schema
-- Version: 1.0
-- Description: Contact trust management with multi-user support

-- Contacts table
CREATE TABLE IF NOT EXISTS contacts (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    email TEXT UNIQUE NOT NULL,
    name TEXT,
    trust_level TEXT NOT NULL DEFAULT 'new',
    trust_score REAL NOT NULL DEFAULT 0.0,
    auto_send BOOLEAN NOT NULL DEFAULT 0,
    
    -- Source metadata
    primary_source TEXT,
    last_sync_at INTEGER,
    
    -- Lifecycle
    state TEXT DEFAULT 'active',
    archived_at INTEGER,
    archived_reason TEXT,
    deleted_at INTEGER,
    
    -- Timestamps
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    last_interaction_at INTEGER,
    
    -- Stats
    emails_sent INTEGER DEFAULT 0,
    emails_received INTEGER DEFAULT 0,
    
    CHECK (trust_score >= -1.0 AND trust_score <= 1.0),
    CHECK (trust_level IN ('owner', 'trusted', 'known', 'new', 'blocked')),
    CHECK (primary_source IN ('google', 'icloud', 'signal', 'bluebubbles', 'manual', NULL)),
    CHECK (state IN ('active', 'archived', 'deleted'))
);

CREATE INDEX IF NOT EXISTS idx_contacts_email ON contacts(email);
CREATE INDEX IF NOT EXISTS idx_contacts_trust_level ON contacts(trust_level);
CREATE INDEX IF NOT EXISTS idx_contacts_trust_score ON contacts(trust_score);
CREATE INDEX IF NOT EXISTS idx_contacts_last_interaction ON contacts(last_interaction_at);
CREATE INDEX IF NOT EXISTS idx_contacts_state ON contacts(state);

-- Users table (users are contacts)
CREATE TABLE IF NOT EXISTS users (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    contact_id INTEGER UNIQUE NOT NULL,
    username TEXT UNIQUE NOT NULL,
    role TEXT NOT NULL DEFAULT 'read-only',
    created_at INTEGER NOT NULL,
    active BOOLEAN DEFAULT 1,
    
    FOREIGN KEY (contact_id) REFERENCES contacts(id) ON DELETE CASCADE,
    CHECK (role IN ('owner', 'family', 'delegate', 'read-only'))
);

CREATE INDEX IF NOT EXISTS idx_users_contact ON users(contact_id);
CREATE INDEX IF NOT EXISTS idx_users_username ON users(username);

-- Contact permissions (allowed info classes)
CREATE TABLE IF NOT EXISTS contact_permissions (
    contact_id INTEGER NOT NULL,
    info_class TEXT NOT NULL,
    
    PRIMARY KEY (contact_id, info_class),
    FOREIGN KEY (contact_id) REFERENCES contacts(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_permissions_contact ON contact_permissions(contact_id);

-- Info class definitions
CREATE TABLE IF NOT EXISTS info_classes (
    name TEXT PRIMARY KEY,
    description TEXT NOT NULL,
    sensitivity_level INTEGER NOT NULL,
    
    CHECK (sensitivity_level >= 0 AND sensitivity_level <= 4)
);

-- Seed info classes
INSERT OR IGNORE INTO info_classes (name, description, sensitivity_level) VALUES
    ('public', 'Publicly shareable information', 0),
    ('technical-general', 'General technical details (no secrets)', 1),
    ('internal', 'Business internals (non-sensitive)', 2),
    ('sensitive', 'Confidential business data', 3),
    ('secret', 'Highly sensitive (keys, passwords, PII)', 4);

-- Trust history events
CREATE TABLE IF NOT EXISTS trust_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    contact_id INTEGER NOT NULL,
    timestamp INTEGER NOT NULL,
    event_type TEXT NOT NULL,
    trust_delta REAL NOT NULL,
    old_score REAL NOT NULL,
    new_score REAL NOT NULL,
    metadata TEXT,
    
    FOREIGN KEY (contact_id) REFERENCES contacts(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_trust_events_contact ON trust_events(contact_id, timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_trust_events_timestamp ON trust_events(timestamp);

-- Multi-source tracking
CREATE TABLE IF NOT EXISTS contact_sources (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    contact_id INTEGER NOT NULL,
    source_type TEXT NOT NULL,
    source_id TEXT NOT NULL,
    raw_data TEXT,
    last_seen_at INTEGER NOT NULL,
    
    UNIQUE (source_type, source_id),
    FOREIGN KEY (contact_id) REFERENCES contacts(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_contact_sources_contact ON contact_sources(contact_id);
CREATE INDEX IF NOT EXISTS idx_contact_sources_type ON contact_sources(source_type, source_id);

-- Contact merge history
CREATE TABLE IF NOT EXISTS contact_merges (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp INTEGER NOT NULL,
    canonical_id INTEGER NOT NULL,
    merged_id INTEGER NOT NULL,
    merge_reason TEXT,
    
    FOREIGN KEY (canonical_id) REFERENCES contacts(id)
);

CREATE INDEX IF NOT EXISTS idx_merges_canonical ON contact_merges(canonical_id);

-- Classification patterns
CREATE TABLE IF NOT EXISTS classification_patterns (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    info_class TEXT NOT NULL,
    pattern_type TEXT NOT NULL,
    pattern TEXT NOT NULL,
    confidence REAL DEFAULT 1.0,
    
    FOREIGN KEY (info_class) REFERENCES info_classes(name)
);

CREATE INDEX IF NOT EXISTS idx_patterns_class ON classification_patterns(info_class);

-- Seed classification patterns
INSERT OR IGNORE INTO classification_patterns (info_class, pattern_type, pattern) VALUES
    ('secret', 'regex', 'password|api[_-]?key|token|secret|credentials'),
    ('secret', 'regex', '[A-Z0-9]{32,}'),
    ('secret', 'regex', '\b\d{3}-\d{2}-\d{4}\b'),
    ('sensitive', 'keyword', 'revenue'),
    ('sensitive', 'keyword', 'contract'),
    ('internal', 'keyword', 'Ice 9'),
    ('internal', 'domain', 'buildzero.tech'),
    ('technical-general', 'keyword', 'OpenClaw'),
    ('technical-general', 'keyword', 'BobNet');

-- Schema version tracking
CREATE TABLE IF NOT EXISTS schema_version (
    version INTEGER PRIMARY KEY,
    applied_at INTEGER NOT NULL
);

INSERT OR IGNORE INTO schema_version (version, applied_at) VALUES (1, strftime('%s', 'now'));
