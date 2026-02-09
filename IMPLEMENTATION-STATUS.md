# Email Security Implementation Status

**Spec:** EMAIL-SECURITY-SPEC-v2.md  
**Started:** 2026-02-09  
**Status:** Phase 2 Foundation Complete (25% of total work)

---

## What's Complete

### ✅ Planning & Architecture
- **Milestone created:** "Secure AI-sent Email" (buildzero-tech/bobnet-cli #3)
- **Epic issues created:**
  - Epic #107: Phase 2 - Contact Lifecycle Management
  - Epic #108: Phase 3 - Audit Logging
  - Epic #109: Phase 4 - Multi-User RBAC
  - Epic #110: Phase 5 - Email Approval Workflow
  - Epic #111: Phase 6 - DevOps Automation

### ✅ Phase 2 Foundation (Partial)
- **Branch:** `feature/107-contact-lifecycle`
- **File:** `trust-lifecycle-commands.sh`
- **Commands implemented:**
  - `trust_archive()` - Archive contacts
  - `trust_restore()` - Restore archived/deleted contacts
  - `trust_delete()` - Soft/permanent delete
  - `trust_cleanup()` - Automated cleanup with decision tree
- **Commit:** `5e62c6e`

---

## Next Steps to Complete Phase 2

### 1. Integrate lifecycle commands into bobnet.sh
**File:** `bobnet.sh`  
**Location:** Line ~2520 (cmd_trust function)

**Changes needed:**
```bash
# In cmd_trust() dispatch (line ~2530):
case "$subcmd" in
    init) trust_init "$@" ;;
    add) trust_add "$@" ;;
    list) trust_list "$@" ;;
    show) trust_show "$@" ;;
    set) trust_set "$@" ;;
    export) trust_export "$@" ;;
    import) trust_import "$@" ;;
    archive) trust_archive "$@" ;;      # ADD
    restore) trust_restore "$@" ;;      # ADD
    delete) trust_delete "$@" ;;        # ADD
    cleanup) trust_cleanup "$@" ;;      # ADD
    ...

# Update help text (line ~2535):
COMMANDS:
  init                Initialize trust registry
  add <email>         Add contact
  list                List contacts
  show <email>        Show contact details
  set <email>         Update trust level/score
  archive <email>     Archive contact                    # ADD
  restore <email>     Restore archived/deleted contact   # ADD
  delete <email>      Delete contact                     # ADD
  cleanup             Cleanup stale contacts             # ADD
  export              Export to vCard
  import              Import from source
```

**Action:** Source `trust-lifecycle-commands.sh` at top of bobnet.sh or copy functions directly after `trust_import()`.

### 2. Create trust decay script
**File:** `~/.bobnet/ultima-thule/scripts/apply-trust-decay`

**Implementation:**
```bash
#!/bin/bash
# Apply trust decay to inactive contacts
# Run daily via cron (Phase 6)

set -euo pipefail

ULTIMA_THULE="${ULTIMA_THULE:-$HOME/.bobnet/ultima-thule}"
CONFIG_DIR="$ULTIMA_THULE/config"
DECAY_FACTOR=0.95
DECAY_PERIOD_DAYS=90

for db in "$CONFIG_DIR"/trust-registry-*.db; do
  [ -f "$db" ] || continue
  
  echo "Applying trust decay: $db"
  
  sqlite3 "$db" <<EOF
-- Apply decay formula: score * 0.95^(days_inactive / 90)
UPDATE contacts
SET trust_score = CASE
    WHEN last_interaction_at IS NULL THEN trust_score
    WHEN ((strftime('%s', 'now') - last_interaction_at) / 86400) < $DECAY_PERIOD_DAYS THEN trust_score
    ELSE MAX(
        0.0,
        trust_score * pow($DECAY_FACTOR, ((strftime('%s', 'now') - last_interaction_at) / 86400.0 / $DECAY_PERIOD_DAYS))
    )
END,
updated_at = strftime('%s', 'now')
WHERE state = 'active' AND last_interaction_at IS NOT NULL;

-- Log decay events
INSERT INTO trust_events (contact_id, timestamp, event_type, trust_delta, old_score, new_score, metadata)
SELECT 
    id,
    strftime('%s', 'now'),
    'decay',
    trust_score - (SELECT c2.trust_score FROM contacts c2 WHERE c2.id = contacts.id),
    (SELECT c2.trust_score FROM contacts c2 WHERE c2.id = contacts.id),
    trust_score,
    json_object('days_inactive', (strftime('%s', 'now') - last_interaction_at) / 86400)
FROM contacts
WHERE state = 'active' 
  AND last_interaction_at IS NOT NULL
  AND ((strftime('%s', 'now') - last_interaction_at) / 86400) >= $DECAY_PERIOD_DAYS;
EOF
  
  echo "✓ Trust decay applied"
done
```

**Action:** Create file, chmod +x, test with synthetic data

### 3. Add Google Contacts sync
**Location:** Either in bobnet.sh or separate script

**Command:** `bobnet trust sync-to-google [--user <name>] [--dry-run]`

**Depends on:** `gog` CLI (already installed)

**Implementation:** See EMAIL-SECURITY-SPEC-v2.md Phase 2, work item #7

### 4. Add test suite
**File:** `tests/test-trust-lifecycle.bats`

**Test cases:**
- Archive active contact → state = 'archived'
- Restore archived contact → state = 'active'
- Restore deleted contact (within 90 days) → success
- Restore deleted contact (>90 days) → error
- Soft delete → state = 'deleted', restorable
- Permanent delete → row removed
- Cleanup decision tree (archive, delete, blocked)

**Action:** Write Bats tests, run via `bats tests/test-trust-lifecycle.bats`

### 5. Create PR and merge
- Push feature branch
- Create PR: feature/107-contact-lifecycle → main
- Link to Epic #107
- Merge after tests pass

---

## Remaining Work (Phases 3-6)

### Phase 3: Audit Logging (Epic #108) - 6 work items
**Estimated:** 3-4 hours

**Work items:**
1. JSONL active log writer (atomic writes with flock)
2. SQLite archive schema + rotation script
3. Audit query CLI (`bobnet audit`)
4. Backup automation script
5. Test suite
6. Documentation

**Key files:**
- `bobnet.sh` - Add `cmd_audit()` function
- `~/.bobnet/ultima-thule/scripts/rotate-audit-logs` - Rotation script
- `~/.bobnet/ultima-thule/logs/audit/` - Log directory
- `tests/test-audit-logging.bats` - Test suite

### Phase 4: Multi-User RBAC (Epic #109) - 6 work items
**Estimated:** 4-5 hours (most complex)

**Work items:**
1. User management CLI (`bobnet user add/list/bind-agent`)
2. Permission enforcement layer (`check_permission()` function)
3. Two-level attribution (env var: BOBNET_USER/AGENT/CHANNEL)
4. Shared agent isolation (per-user DB selection)
5. Test suite (permission matrix tests)
6. Documentation (RBAC guide, permission matrix)

**Key files:**
- `bobnet.sh` - Add `cmd_user()`, `check_permission()`, `get_user_db()`
- `~/.bobnet/ultima-thule/patterns/rbac-agent-integration.md` - Agent pattern
- SQL schema already includes users/agent_bindings tables
- `tests/test-rbac.bats` - Permission enforcement tests

### Phase 5: Email Approval Workflow (Epic #110) - 9 work items
**Estimated:** 5-6 hours

**Work items:**
1. Draft management CLI (`bobnet draft save/list/show/delete`)
2. Content classification (`bobnet classify <text>`)
3. Auto-send eligibility check
4. Signal approval UI (OpenClaw agent pattern)
5. Approval response handler (OpenClaw agent pattern)
6. Draft expiration cleanup script
7. Prompt injection defense (documentation)
8. Test suite (classification, workflow, security)
9. Documentation

**Key files:**
- `bobnet.sh` - Add `cmd_draft()`, `cmd_classify()`, `cmd_email()`
- `~/.bobnet/ultima-thule/config/content-classification.yaml` - Patterns
- `~/.bobnet/ultima-thule/patterns/email-approval-workflow.md` - Agent pattern
- `~/.bobnet/email-drafts/` - Draft storage directory
- `~/.bobnet/ultima-thule/scripts/cleanup-expired-drafts` - Cleanup script

### Phase 6: DevOps Automation (Epic #111) - 6 work items
**Estimated:** 2-3 hours

**Work items:**
1. Cron job configuration (`config/bobnet-cron.conf`)
2. Monitoring integration (Signal alerts)
3. Backup automation (already partially done via git)
4. Disaster recovery testing (manual validation)
5. User onboarding script (`bobnet setup-email-security`)
6. Documentation (DevOps guide, runbooks)

**Key files:**
- `~/.bobnet/ultima-thule/config/bobnet-cron.conf` - Cron configuration
- `~/.bobnet/ultima-thule/scripts/email-security-monitor` - Monitoring script
- `~/.bobnet/ultima-thule/scripts/backup-trust-registry` - Backup script
- `~/.bobnet/ultima-thule/docs/disaster-recovery-runbook.md` - DR docs
- `bobnet.sh` - Add `bobnet setup-email-security` command

---

## Total Effort Estimate

| Phase | Work Items | Estimated Hours | Status |
|-------|-----------|----------------|--------|
| Phase 2 | 8 | 3-4 | 50% complete (foundation done) |
| Phase 3 | 6 | 3-4 | Not started |
| Phase 4 | 6 | 4-5 | Not started |
| Phase 5 | 9 | 5-6 | Not started |
| Phase 6 | 6 | 2-3 | Not started |
| **Total** | **35** | **17-22** | **~10% complete** |

**Current progress:** ~2 hours invested, foundation established

---

## Recommended Approach

### Option A: Complete Phase 2, then pause
**Effort:** 1-2 more hours  
**Outcome:** Full Phase 2 (lifecycle management) functional

**Next steps:**
1. Integrate lifecycle commands into bobnet.sh (30 min)
2. Create trust decay script (30 min)
3. Write tests (45 min)
4. Create PR, merge (15 min)

### Option B: Complete all phases
**Effort:** 15-20 more hours  
**Outcome:** Full email security system operational

**Recommendation:** Break into 5 PRs (one per phase), implement incrementally over several sessions.

### Option C: Prioritize critical paths
**Effort:** 8-10 hours  
**Outcome:** Core security features (Phase 2, 3, 5)

**Skip:** Phase 4 (RBAC) until multiple users exist, Phase 6 (DevOps) until features complete

---

## Quick Start (Resume Implementation)

```bash
# 1. Switch to feature branch
cd ~/.bobnet/repos/bobnet-cli
git checkout feature/107-contact-lifecycle

# 2. Integrate lifecycle commands
# Edit bobnet.sh:
#   - Add archive/restore/delete/cleanup to cmd_trust dispatch
#   - Source trust-lifecycle-commands.sh or copy functions
#   - Update help text

# 3. Create trust decay script
cd ~/.bobnet/ultima-thule/scripts
# Create apply-trust-decay (see implementation above)

# 4. Test locally
bobnet trust init --user testuser
bobnet trust add test@example.com --name "Test"
bobnet trust archive test@example.com
bobnet trust list --state archived
bobnet trust restore test@example.com
bobnet trust delete test@example.com

# 5. Write tests
cd ~/.bobnet/repos/bobnet-cli/tests
# Create test-trust-lifecycle.bats

# 6. Commit and PR
git add . && git commit -m "feat(trust): complete Phase 2 lifecycle management"
git push -u origin feature/107-contact-lifecycle
gh pr create --title "feat: Phase 2 - Contact Lifecycle Management" --body "Closes #107"
```

---

**Last updated:** 2026-02-09  
**Branch:** feature/107-contact-lifecycle  
**Commit:** 5e62c6e
