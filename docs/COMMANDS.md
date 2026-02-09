# BobNet CLI Command Reference

Comprehensive reference for all BobNet CLI commands.

## Table of Contents

- [Specification Management](#specification-management)
- [Work Tracking](#work-tracking)
- [GitHub Integration](#github-integration)
- [Git Attribution](#git-attribution)
- [Todo Management](#todo-management)
- [Release Documentation](#release-documentation)

---

## Specification Management

### `bobnet spec create-issues`

Create GitHub issues from specification files.

**Usage:**
```bash
bobnet spec create-issues <file> [options]
```

**Options:**
- `--project, -p <name>` — GitHub Project name (optional)
- `--milestone, -m <name>` — Milestone name (overrides spec)
- `--dry-run` — Show what would be created without creating

**Workflow:**
1. Parse spec file for context, Epics, and work items
2. Search for existing milestones/Epics (deduplication)
3. Show proposed issue structure
4. Wait for user approval
5. Discover repo labels and map conventional types
6. Create Epic issues + work items
7. Update spec file with issue numbers

**Examples:**
```bash
# Create issues from spec
bobnet spec create-issues docs/FEATURE-SPEC.md

# Override milestone
bobnet spec create-issues docs/FEATURE-SPEC.md --milestone "Q1 2026"

# Dry run (preview without creating)
bobnet spec create-issues docs/FEATURE-SPEC.md --dry-run
```

**Spec File Requirements:**
- Must have `**Context:**` field (BobNet Infrastructure, Monorepo Package, etc.)
- Must have `**GitHub Milestone:**` field (or use `- **Milestone:**`)
- Must have `**Primary Repository:**` field
- Must have `### Epic:` sections with work items

**Output:**
- Creates Epic parent issues with `epic` label
- Creates work item issues under Epics
- Links work items to parent Epic with "Part of Epic #N"
- Updates spec file with issue numbers
- Shows next steps for implementation

**Related:**
- Spec format: `docs/GITHUB-TRACKING-ENFORCEMENT.md`
- Pattern: `~/.bobnet/ultima-thule/collective/patterns/coordination/work-tracking.md`

---

## Work Tracking

### `bobnet work start`

Mark a GitHub issue as "In Progress" and assign to current user.

**Usage:**
```bash
bobnet work start <issue> [options]
```

**Options:**
- `--repo, -R <owner/repo>` — Target repository (default: current repo)

**Workflow:**
1. Validates issue exists
2. Reopens closed issues (with confirmation)
3. Assigns issue to current user (if not already assigned)
4. Adds work-started comment with timestamp
5. Shows next steps

**Examples:**
```bash
# Start work on issue in current repo
bobnet work start 37

# Start work on issue in specific repo
bobnet work start 37 --repo buildzero-tech/bobnet-cli
```

**Output:**
```
→ Starting work on buildzero-tech/bobnet-cli#37...
→ Assigning to buildzerobob...
✓ Assigned to buildzerobob
✓ Work started on buildzero-tech/bobnet-cli#37

→ Next steps:
  1. Work on the issue
  2. Commit with: bobnet git commit 'feat: description #37'
  3. When done: bobnet work done 37
```

**Notes:**
- Auto-detects current repository from git remote
- Adds timestamped comment: "🚧 Work started by @user (timestamp)"
- Automatically sets GitHub Project Status to "In Progress"
- If issue was blocked, removes "blocked" label and restores priority

---

### `bobnet work done`

Mark a GitHub issue as "Done" and close it with commit references.

**Usage:**
```bash
bobnet work done <issue> [options]
```

**Options:**
- `--repo, -R <owner/repo>` — Target repository (default: current repo)

**Workflow:**
1. Finds all commits referencing the issue (#num pattern)
2. Shows commit list to user
3. Closes issue with comment listing commits
4. Reminds user to update MEMORY.md

**Examples:**
```bash
# Complete work on issue in current repo
bobnet work done 37

# Complete work on issue in specific repo
bobnet work done 37 --repo buildzero-tech/bobnet-cli
```

**Output:**
```
→ Completing work on buildzero-tech/bobnet-cli#37...
→ Finding commits referencing #37...
✓ Found 3 commit(s)

  e842430 feat(github): implement bobnet github my-issues command #39
  276f0c5 feat(work): implement work start logic #37
  aa0745e feat(work): add bobnet work start/done command skeletons #37 #38

→ Closing issue...
✓ Issue #37 closed!

→ Don't forget to:
  - Update MEMORY.md: Mark todo [x] completed
  - Run: bobnet todo sync (to sync with GitHub)
```

**Notes:**
- Searches all branches for commits with `#<issue-num>` in message
- Prompts for confirmation if no commits found
- Closes with summary: "✅ Work completed" + commit list
- Automatically sets GitHub Project Status to "Done"

---

### `bobnet work blocked`

Mark a GitHub issue as blocked with a reason.

**Usage:**
```bash
bobnet work blocked <issue> <reason> [options]
```

**Options:**
- `--repo, -R <owner/repo>` — Target repository (default: current repo)

**Actions:**
1. Sets Priority field to "Waiting" in GitHub Project
2. Adds "blocked" label to the issue
3. Posts a comment with the blocking reason

**Examples:**
```bash
# Mark issue as blocked with reason
bobnet work blocked 37 "Waiting for API access from vendor"

# Block with dependency reference
bobnet work blocked 37 "Depends on #38 being completed first"
```

**Output:**
```
→ Marking buildzero-tech/bobnet-cli#37 as blocked...
→ Priority set to 'Waiting'
✓ Issue #37 marked as blocked
  Reason: Waiting for API access from vendor
```

**To Unblock:**
```bash
bobnet work start <issue>  # Removes blocked label, restores priority to Medium
```

**Notes:**
- Creates "blocked" label automatically if not exists
- Label is bright red (#B60205) for visibility
- `work start` removes blocked status and label

---

## GitHub Integration

### `bobnet github my-issues`

Show GitHub issues assigned to current user, grouped by type.

**Usage:**
```bash
bobnet github my-issues [options]
```

**Options:**
- `--repo, -R <owner/repo>` — Filter to specific repository
- `--all, -a` — Show all issues (default: open only)

**Output:**
Issues grouped by label:
- 📋 **Epics** (epic label)
- ✨ **Features** (enhancement/feature label)
- 📚 **Documentation** (documentation label)
- 🔧 **Maintenance** (maintenance/chore label)
- 🐛 **Bugs** (bug label)
- 📝 **Other** (no matching label)

**Examples:**
```bash
# Show all open issues assigned to you
bobnet github my-issues

# Filter to specific repository
bobnet github my-issues --repo buildzero-tech/bobnet-cli

# Show all issues (including closed)
bobnet github my-issues --all
```

**Sample Output:**
```
→ Fetching issues assigned to buildzerobob...

📋 Epics:
  buildzero-tech/bobnet-cli#35: Epic: CLI Implementation

✨ Features:
  buildzero-tech/bobnet-cli#42: Document CLI commands in docs/COMMANDS.md
  buildzero-tech/bobnet-cli#43: Add usage examples to README.md

✓ Total: 3 issue(s)
```

**Notes:**
- Only shows issues assigned to current GitHub user
- Requires `gh` CLI authentication
- Uses GitHub Search API (100 issue limit)

---

### `bobnet github project set-status`

Set the Status field for an issue in the GitHub Project.

**Usage:**
```bash
bobnet github project set-status <issue> <status>
```

**Status Values:**
- `not-started` — Work not yet begun (default for new issues)
- `in-progress` — Active development
- `review` — Ready for review
- `done` — Completed

**Examples:**
```bash
# Set status in current repo
bobnet github project set-status 87 in-progress

# Set status with full issue reference
bobnet github project set-status buildzero-tech/ultima-thule#45 done
```

**Notes:**
- Project is inferred from repository (bobnet-cli, ultima-thule → BobNet Work)
- Metadata is cached for 24 hours to reduce API calls
- Use `bobnet github project refresh` to force cache update

---

### `bobnet github project set-priority`

Set the Priority field for an issue in the GitHub Project.

**Usage:**
```bash
bobnet github project set-priority <issue> <priority>
```

**Priority Values:**
- `low` — Low priority, backlog
- `medium` — Normal priority
- `high` — High priority, do soon
- `critical` — Must do immediately
- `waiting` — Blocked, awaiting external input
- `deferred` — Intentionally postponed

**Examples:**
```bash
# Set priority
bobnet github project set-priority 123 high

# Mark as blocked (use work blocked instead for full workflow)
bobnet github project set-priority 123 waiting
```

**Notes:**
- Use `waiting` for blocked work (or use `bobnet work blocked` for full workflow)
- Use `deferred` for work intentionally postponed
- Priority changes don't affect issue labels

---

### `bobnet github project refresh`

Refresh cached project metadata.

**Usage:**
```bash
bobnet github project refresh [org/number]
```

**Examples:**
```bash
# Refresh BobNet Work project (default)
bobnet github project refresh

# Refresh specific project
bobnet github project refresh buildzero-tech/4
```

**Notes:**
- Cache expires after 24 hours automatically
- Use when project fields/options have changed
- Cache stored in `~/.bobnet/cache/github-projects/`

---

### `bobnet github issue create`

Create a new GitHub issue in the current repository.

**Usage:**
```bash
bobnet github issue create <title> [options]
```

**Options:**
- `--body, -b <text>` — Issue body/description
- `--label, -l <label>` — Add label (can be repeated)
- `--assignee, -a <user>` — Assign to user (can be repeated)
- `--milestone, -m <name>` — Add to milestone
- `--repo, -R <owner/repo>` — Target repository (default: current repo)

**Examples:**
```bash
# Create simple issue
bobnet github issue create "Add OAuth support"

# Create with body and labels
bobnet github issue create "Add OAuth support" \
  --body "Need to implement OAuth2 flow" \
  --label enhancement \
  --label auth

# Create and assign
bobnet github issue create "Fix login bug" \
  --body "Users can't log in after password reset" \
  --label bug \
  --milestone "v1.5.0" \
  --assignee bob
```

**Output:**
Returns GitHub issue URL

---

## Git Attribution

### `bobnet git commit`

Commit with agent attribution prefix.

**Usage:**
```bash
bobnet git commit <message> [options]
```

**Options:**
- `--full` — Add co-authored-by trailer for major commits

**Examples:**
```bash
# Standard commit
bobnet git commit "feat(ops): add health checks"

# Major commit with full attribution
bobnet git commit "feat(ops): add deployment pipeline" --full
```

**Output:**
Automatically adds `[Bob]` prefix to commit message:
```
[Bob] feat(ops): add health checks
```

**Notes:**
- Auto-detects agent from current workspace
- Follows conventional commit format (feat, fix, docs, chore, etc.)
- Use `--full` for commits that deserve co-authorship attribution

---

### `bobnet git check`

Check recent commits for proper attribution.

**Usage:**
```bash
bobnet git check [timeframe]
```

**Examples:**
```bash
# Check commits from last 24 hours
bobnet git check "24 hours ago"

# Check commits from specific date
bobnet git check "2026-02-01"
```

**Output:**
Shows commits without proper `[Agent]` attribution

---

## Todo Management

### `bobnet todo list`

List todos for agent(s).

**Usage:**
```bash
bobnet todo list [agent]
```

**Examples:**
```bash
# List todos for current agent
bobnet todo list

# List todos for specific agent
bobnet todo list bob

# List todos for all agents
bobnet todo list
```

---

### `bobnet todo status`

Show todo status across all agents.

**Usage:**
```bash
bobnet todo status
```

**Output:**
Summary of open/completed todos per agent

---

### `bobnet todo sync`

Sync todos with GitHub issues.

**Usage:**
```bash
bobnet todo sync [options]
```

**Options:**
- `--dry-run` — Show what would change without changing

**Behavior:**
- Completed todos with `#issue` → Close GitHub issue
- Open todos with `#issue` → Update issue status
- GitHub issue changes synced back to agent memory

**Examples:**
```bash
# Sync todos with GitHub
bobnet todo sync

# Preview changes
bobnet todo sync --dry-run
```

---

## Command Patterns

### Conventional Commit Types

All `bobnet git commit` messages should follow conventional commit format:

| Type | Description | GitHub Label |
|------|-------------|--------------|
| `feat` | New feature | enhancement |
| `fix` | Bug fix | bug |
| `docs` | Documentation | documentation |
| `test` | Testing | testing |
| `chore` | Maintenance | maintenance |
| `refactor` | Code refactoring | enhancement |
| `perf` | Performance improvement | enhancement |
| `style` | Code style/formatting | maintenance |

**Format:**
```
type(scope): description #issue

Longer description (optional)
```

**Examples:**
```
feat(spec): add bobnet spec create-issues command #36
fix(work): handle closed issues in work start #37
docs(commands): add CLI reference documentation #42
test(spec): add end-to-end workflow test #46
chore(deps): update gh CLI to v2.50.0 #50
```

---

## Workflow Examples

### Complete Feature Workflow

```bash
# 1. Create spec with work breakdown
vim docs/FEATURE-SPEC.md

# 2. Create GitHub issues from spec
bobnet spec create-issues docs/FEATURE-SPEC.md

# 3. Start work on first issue
bobnet work start 42

# 4. Implement feature
# ... code changes ...

# 5. Commit with attribution
bobnet git commit "feat(feature): implement X #42"

# 6. Complete work
bobnet work done 42

# 7. Update memory and sync
# Edit MEMORY.md: mark todo [x]
bobnet todo sync
```

### Multi-Issue Epic Workflow

```bash
# 1. Create Epic spec
vim docs/EPIC-SPEC.md

# 2. Generate all issues
bobnet spec create-issues docs/EPIC-SPEC.md
# Creates Epic #35 + work items #36-#50

# 3. Work through issues incrementally
bobnet work start 36
# ... implement ...
bobnet git commit "feat: implement #36"
bobnet work done 36

# 4. Check remaining work
bobnet github my-issues --repo buildzero-tech/bobnet-cli

# 5. Continue with next issue
bobnet work start 37
```

---

## Release Documentation

### `bobnet docs release-notes`

Generate release notes from GitHub issues closed since a tag.

**Usage:**
```bash
bobnet docs release-notes [tag] [options]
```

**Options:**
- `tag` — Tag to generate notes since (default: latest tag)
- `--repo, -R <owner/repo>` — Target repository (default: current repo)

**Output:**
Groups issues by label:
- **Features** (enhancement/feature label)
- **Documentation** (documentation label)
- **Maintenance** (maintenance/chore label)
- **Bug Fixes** (bug label)

**Examples:**
```bash
# Generate notes since latest tag
bobnet docs release-notes

# Generate notes since specific tag
bobnet docs release-notes v1.4.0

# Generate for different repo
bobnet docs release-notes v1.4.0 --repo buildzero-tech/bobnet-cli

# Save to file
bobnet docs release-notes v1.5.0 > releases/v1.5.0.md
```

**Output Format:**
```markdown
# Release Notes

**Since:** v1.4.0

## ✨ Features

- Feature A (#123)
- Feature B (#124)

## 📚 Documentation

- Updated docs (#125)

---

**Total:** 15 issue(s) closed
```

**Notes:**
- Queries all issues closed since the tag date
- Automatically links issue numbers
- Follows Keep a Changelog conventions

---

### `bobnet docs changelog`

Generate CHANGELOG.md from conventional commits with issue references.

**Usage:**
```bash
bobnet docs changelog [version]
```

**Options:**
- `version` — Version to generate changelog for (default: unreleased)

**Examples:**
```bash
# Generate unreleased changes
bobnet docs changelog

# Generate for specific version
bobnet docs changelog v1.5.0

# Update CHANGELOG.md
bobnet docs changelog >> CHANGELOG.md
```

**Output Format:**
```markdown
# Changelog

## [Unreleased]

### Added
- New feature ([#123](../../issues/123))

### Changed
- Refactored module ([#124](../../issues/124))

### Fixed
- Bug fix ([#125](../../issues/125))
```

**Notes:**
- Groups by conventional commit type (feat, fix, refactor, perf)
- Automatically linkifies issue references
- Follows Keep a Changelog format

---

### `bobnet docs project-template`

Output GitHub Project board template with standard columns.

**Usage:**
```bash
bobnet docs project-template
```

**Output:**
Recommended project board structure with:
- **Not Started** — New work
- **In Progress** — Active development
- **Blocked** — Waiting on dependencies
- **Review** — Ready for review
- **Done** — Completed

**Examples:**
```bash
# View template
bobnet docs project-template

# Save to file
bobnet docs project-template > .github/project-template.md
```

**Includes:**
- Status column values and descriptions
- Setup instructions for GitHub Projects V2
- BobNet integration examples
- Manual status update methods

---

## Related Documentation

- **Spec Format:** `docs/GITHUB-TRACKING-ENFORCEMENT.md`
- **Work Tracking Pattern:** `~/.bobnet/ultima-thule/collective/patterns/coordination/work-tracking.md`
- **PR Workflow:** `~/.bobnet/ultima-thule/collective/patterns/coordination/work-tracking.md#pull-request-workflow`
- **VM Testing Guide:** `docs/vm-testing-guide.md`

---

*Last updated: 2026-02-09*
