# Changelog

All notable changes to BobNet CLI will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- GitHub Projects API integration for Epic field management (#79)
  - `get_project_id()` - Get project ID from org and number
  - `get_epic_field_metadata()` - Query Epic field options from project
  - `get_issue_node_id()` - Get issue GraphQL node ID for project operations
  - `add_issue_to_project_with_epic()` - Add issue to project and set Epic field value
- Epic field validation in `bobnet work start` (#80)
  - Checks if Epic field is set when starting work on BobNet issues
  - Warns if Epic field is missing (non-blocking validation)
  - Displays Epic value when set
- Project integration in `bobnet spec create-issues` (#79)
  - New `--project` flag: format `org/number` or just `number` (defaults to buildzero-tech)
  - Auto-detects BobNet Infrastructure context and defaults to project #4
  - Automatically adds created issues to GitHub Project
  - Sets Epic field on work items based on parent Epic

### Changed
- **BREAKING: Epic label deprecated** (#81)
  - Epic issues no longer receive `epic` label
  - Epic field in GitHub Projects is now canonical for grouping
  - Historical issues with `epic` label remain unchanged (no migration)
  - **Migration strategy:**
    - **Phase 1 (Complete):** Stop applying epic label to new Epic issues
    - **Phase 2 (In Progress):** Update tooling to use Epic field
    - **Phase 3 (Future):** Archive historical Epic issues with labels
    - **Phase 4 (Future):** Remove epic label entirely after 100% Epic field adoption

### Documentation
- Updated GITHUB-TRACKING-ENFORCEMENT.md spec examples (#82)
  - Audit checks now query Epic field in GitHub Projects
  - Noted Epic label deprecation (2026-02-09)
  - Work items reference "Part of Epic" (generic, compatible with both approaches)

## Migration Guide: Epic Label → Epic Field

### Why the Change?

The `epic` label was a workaround for grouping related issues. GitHub Projects now supports custom fields, allowing proper hierarchical tracking:

**Old approach (epic label):**
- ❌ No hierarchy in issue lists
- ❌ Manual Epic linking via text parsing
- ❌ No automatic progress aggregation
- ❌ Label clutter in issue lists

**New approach (Epic field):**
- ✅ Proper hierarchy in GitHub Project views
- ✅ Automatic Epic detection via project field
- ✅ Progress tracking per Epic
- ✅ Cleaner issue lists (no label noise)

### For Developers

**Creating new Epics:**
```bash
# Old (deprecated)
gh issue create --title "Epic: Feature Name" --label epic

# New (current)
bobnet spec create-issues feature-spec.md
# Epic field automatically set in BobNet Work project
```

**Starting work:**
```bash
# Work on any issue
bobnet work start 123

# Epic field validation runs automatically
# ✓ Epic: CLI Implementation  (if set)
# ⚠ Epic field not set        (if missing)
```

**Querying by Epic:**
```bash
# Old (deprecated)
gh issue list --label epic

# New (current - via GitHub UI)
# 1. Open BobNet Work project (buildzero-tech #4)
# 2. Filter by Epic field value
# 3. Or use GraphQL API (see GITHUB-TRACKING-ENFORCEMENT.md)
```

### For Historical Issues

**No action required.** Historical Epic issues (#35, #51, #6, etc.) keep their `epic` label for backward compatibility. They will be archived after completion, not migrated.

### Timeline

- **2026-02-09:** Epic label deprecated
- **2026-02-09:** Epic field becomes canonical
- **2026-Q1:** Monitor adoption, fix any tooling gaps
- **2026-Q2:** Archive completed historical Epic issues
- **2026-Q3:** Remove epic label entirely (if 100% Epic field adoption achieved)

### Related Issues

- #77: Epic Field Migration (parent Epic)
- #78: Add Epic custom field to BobNet Work project
- #79: Update bobnet spec create-issues to set Epic field
- #80: Add Epic field validation in bobnet work start
- #81: Deprecate Epic label creation for new issues
- #82: Update GITHUB-TRACKING-ENFORCEMENT.md spec examples
- #83: Document migration strategy in CHANGELOG (this entry)
- #84: Close/archive Epic #35, #51 after field adoption
- #85: Update historical Epic issue bodies with deprecation notice

---

## [4.12.0] - 2026-02-08

### Added
- GitHub issue templates (feature.yml, bug.yml) (#67-#69)
- Type label taxonomy with `type:` prefix (#70-#72)
  - `type: feature`, `type: bug`, `type: docs`, `type: test`, `type: chore`
- CONTRIBUTING.md with GitHub workflow guidance (#73)
- Label discovery and mapping in `bobnet spec create-issues` (#74)
  - Auto-detects existing labels
  - Maps conventional types to repo-specific labels
  - Creates missing labels on demand
- Release automation commands (#52-#58)
  - `bobnet docs release-notes` - Generate release notes from commits
  - `bobnet docs changelog` - Update CHANGELOG.md
  - `bobnet docs project-template` - Generate project updates

### Documentation
- Comprehensive GitHub workflow patterns (ultima-thule #7-#15)
- Feature branch workflow in TOOLS.md and SLASH.md (#21)
- Git & PR workflow documentation (TOOLS.md)

---

For older changes, see commit history: https://github.com/buildzero-tech/bobnet-cli/commits/main
