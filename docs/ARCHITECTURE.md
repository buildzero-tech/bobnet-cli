# BobNet Architecture

Technical architecture and design decisions.

## Table of Contents

- [Deduplication Logic](#deduplication-logic)
- [Label Discovery](#label-discovery)
- [Spec Parsing](#spec-parsing)
- [Git Attribution](#git-attribution)

---

## Deduplication Logic

The `bobnet spec create-issues` command implements comprehensive deduplication to prevent creating duplicate GitHub resources.

### Milestone Deduplication

**Strategy:** Search before create

**Implementation:**
```bash
find_milestone() {
    local repo="$1"
    local milestone_name="$2"
    gh api "repos/$repo/milestones" --jq ".[] | select(.title == \"$milestone_name\") | .number"
}

ensure_milestone() {
    local existing=$(find_milestone "$repo" "$milestone_name")
    [[ -n "$existing" ]] && echo "$existing" && return 0
    # Create only if not found
    gh api -X POST "repos/$repo/milestones" ...
}
```

**Matching Logic:**
- Exact title match (case-sensitive)
- Searches all milestones (open + closed)
- Returns milestone number if found

**User Interaction:**
- No prompt needed (safe to reuse existing milestone)
- Milestone reused across multiple spec runs

---

### Epic Deduplication

**Strategy:** Parse spec for existing issue numbers

**Detection:**
1. Check Epic Issue field: `**Epic Issue:** #35` or `**Epic Issue:** TBD`
2. If issue number present → skip Epic creation
3. If `TBD` or missing → create new Epic

**Implementation:**
```bash
# Extract Epic Issue line
local epic_issue=$(awk -v start="$line_num" '
    NR >= start && /^### Epic:/ && NR > start { exit }
    NR >= start && /\*\*Epic Issue:\*\*/ { 
        if ($0 ~ /#[0-9]+/) print "exists"
        else print "missing"
        exit
    }
' "$spec_file")

# Skip if already exists
[[ "$epic_issue" == "exists" ]] && continue
```

**Matching Logic:**
- Parse `**Epic Issue:**` field in spec
- Regex: `#[0-9]+` indicates existing issue
- `TBD` or empty indicates new Epic needed

**User Interaction:**
- No prompt (spec file is source of truth)
- Running command multiple times is safe (idempotent)

---

### Work Item Deduplication

**Strategy:** Parse spec for existing issue references

**Detection:**
1. Extract work items from spec under Epic
2. Check for issue references: `#123` or `repo#123`
3. If reference present → skip work item creation
4. If no reference → create new issue

**Implementation:**
```bash
extract_work_items() {
    awk '
        /^- / {
            item=$0
            sub(/^- /, "", item)
            # Check for existing issue reference
            if (item ~ / #[0-9]+$/) next        # Skip same-repo ref
            if (item ~ / [a-z-]+\/[a-z-]+#[0-9]+$/) next  # Skip cross-repo ref
            print category "|" item
        }
    '
}
```

**Matching Patterns:**
- Same-repo: `item title #123`
- Cross-repo: `item title buildzero-tech/repo#123`
- No reference: `item title` → needs creation

**Edge Cases:**
- Handles both `#123` and `repo#123` formats
- Preserves existing issue numbers across spec updates
- Safe to re-run after partial creation

---

### Search Strategies

**Milestone Search:**
- **API:** `GET /repos/{owner}/{repo}/milestones`
- **Filter:** `jq ".[] | select(.title == \"$milestone_name\")"`
- **Scope:** All states (open/closed)
- **Match:** Exact title (case-sensitive)

**Epic Search:**
- **Method:** Parse spec file
- **Source:** Epic Issue field in spec YAML front matter
- **Format:** `**Epic Issue:** #35`
- **Validation:** Regex `#[0-9]+`

**Work Item Search:**
- **Method:** Parse spec file
- **Source:** Work item bullet points
- **Formats:** `#123` or `repo#123` at end of line
- **Regex:** `/ #[0-9]+$/` or `/ [a-z-]+\/[a-z-]+#[0-9]+$/`

---

### User Prompts

**Approval Gate:**
```bash
echo "This will create:"
echo "  - $epic_count Epic parent issue(s)"
echo "  - Work item issues under each Epic"
echo ""
read -p "Proceed with issue creation? [y/N] " -r
```

**When Prompted:**
- Before creating any issues
- After showing full structure preview
- Allows user to review and cancel

**No Prompts For:**
- Milestone reuse (always safe)
- Epic/work item skipping (spec is source of truth)

---

### Conflict Resolution

**Scenario:** Spec file updated, some issues already exist

**Behavior:**
1. Parse spec to find existing issue numbers
2. Skip creation for items with references
3. Create only missing issues
4. Update spec file with new issue numbers

**Example:**
```markdown
### Epic: Feature Name 📋
**Epic Issue:** #35

#### Features
- Feature A #36
- Feature B         ← Will create #37
- Feature C #38
```

Result: Only creates issue for "Feature B"

---

### Idempotency

**Goal:** Safe to run `bobnet spec create-issues` multiple times

**Implementation:**
1. **First run:** Creates all issues, updates spec
2. **Second run:** Finds existing issue numbers in spec, creates nothing
3. **Partial run:** Creates only missing issues

**Guarantees:**
- No duplicate milestones (search before create)
- No duplicate Epics (parse spec for existing numbers)
- No duplicate work items (parse spec for existing references)
- Spec file is single source of truth

**Test:**
```bash
# Run once
bobnet spec create-issues docs/SPEC.md
# Creates Epic #35, issues #36-#40

# Run again
bobnet spec create-issues docs/SPEC.md
# Output: All issues already exist, nothing created
```

---

## Label Discovery

### Repo Label Query

**API:**
```bash
get_repo_labels() {
    gh api "repos/$repo/labels" --jq '.[].name'
}
```

**Returns:** List of all label names in repository

**Usage:**
- Query once per repository
- Cache result for multiple label mappings
- Used for conventional commit type mapping

---

### Conventional Commit Type Mapping

**Strategy:** Map conventional commit types to actual repo labels

**Implementation:**
```bash
map_type_to_label() {
    local type="$1"
    local labels="$2"  # Pre-fetched repo labels
    
    case "$type" in
        Features*|feat*)
            echo "$labels" | grep -i "^enhancement$\|^feature$" | head -1
            ;;
        Documentation*|docs*)
            echo "$labels" | grep -i "^documentation$" | head -1
            ;;
        # ... more mappings ...
    esac
}
```

**Mappings:**
| Spec Category | Conventional Type | Label Candidates |
|---------------|-------------------|------------------|
| Features | feat | enhancement, feature |
| Documentation | docs | documentation |
| Testing | test | testing |
| Maintenance | chore | maintenance, chore |
| Bugs | fix | bug |

**Fallback:**
- If no matching label found → defaults to `enhancement`
- Ensures issue always gets a label

---

### Label Creation

**Strategy:** Ensure required labels exist before use

**Implementation:**
```bash
ensure_label() {
    gh api "repos/$repo/labels/$label_name" >/dev/null 2>&1 && return 0
    gh api -X POST "repos/$repo/labels" -f name="$label_name" -f color="$color"
}
```

**Required Labels:**
- `epic` (5319e7) - Parent tracking issues
- `enhancement` (a2eeef) - New features
- `documentation` (0075ca) - Documentation updates
- `testing` (1d76db) - Test infrastructure
- `maintenance` (fbca04) - Maintenance and tooling

**Behavior:**
- Check if label exists (GET request)
- Create if missing (POST request)
- Silently succeed if already exists

---

## Spec Parsing

### Context Detection

**Field:** `**Context:**`

**Values:**
- BobNet Infrastructure
- Monorepo Package
- Monorepo Scaffold
- External Project

**Usage:**
- Determines where pattern documentation should live
- Affects cross-cutting work placement
- Referenced in Epic issue bodies

---

### Repository Extraction

**Primary Repository:**
```bash
# Look in "This Spec's Context" section first
awk '/^## This Spec/{flag=1; next} /^##/{flag=0} flag' "$spec_file" |
    grep -m1 "\*\*Primary Repository:\*\*"
```

**Additional Repositories:**
```bash
# Same section, different field
grep -m1 "\*\*Additional Repos:\*\*" | sed 's/ (.*)//'
```

**Handling:**
- Primary repo hosts most issues
- Additional repos for cross-repo work items
- Milestones/labels ensured in all target repos

---

### Epic Section Parsing

**Pattern:**
```markdown
### Epic: Name 📋
**Primary Repository:** org/repo
**Epic Issue:** TBD
**Status:** Not started
**Dependencies:** None

#### Features (feat → enhancement)
- Feature A
- Feature B #123
```

**Extraction:**
```bash
extract_epics() {
    grep -n "^### Epic:" "$spec_file" | sed 's/:### Epic: /|/'
}
```

**Returns:** Line number + Epic title

---

### Work Item Parsing

**Strategy:** Extract from Epic section by category

**Implementation:**
```bash
extract_work_items() {
    awk '
        /^####/ { category=$0; sub(/^#### /, "", category); next }
        /^- / {
            item=$0
            sub(/^- /, "", item)
            # Remove existing issue refs
            sub(/ #[0-9]+$/, "", item)
            print category "|" item
        }
    '
}
```

**Output Format:** `Category|Work item title`

**Categories:**
- Features (feat → enhancement)
- Documentation (docs → documentation)
- Testing (test → testing)
- Maintenance (chore → maintenance)

---

## Git Attribution

### Agent Detection

**Strategy:** Read from workspace context

**Implementation:**
```bash
# Current agent name from workspace path
AGENT_NAME=$(basename "$(dirname "$BOBNET_ROOT/workspace/$USER")")
```

**Usage:**
- Prefix commits: `[Bob] feat: implement X`
- Tag work-started comments: `@buildzerobob`
- Attribute to correct agent in multi-agent setup

---

### Commit Reference Search

**Strategy:** Search all branches for issue references

**Implementation:**
```bash
git log --all --oneline --grep="#$issue_num"
```

**Matching:**
- Searches commit messages only (not diffs)
- Pattern: `#123` anywhere in message
- Returns all matching commits across branches

**Usage:**
- Used by `bobnet work done` to find related commits
- Generates commit list for issue close comment

---

## Cross-Repo Handling

### Issue References

**Formats:**
- Same-repo: `#123`
- Cross-repo: `buildzero-tech/repo#123`

**Detection:**
```bash
# Check for cross-repo reference
if [[ "$item_title" =~ (buildzero-tech/[a-z-]+)$ ]]; then
    item_repo="${BASH_REMATCH[1]}"
fi
```

**Epic Linking:**
```bash
# Link work item to Epic (cross-repo safe)
local body="Part of Epic "
if [[ "$repo" == "$epic_repo" ]]; then
    body+="#${epic_number}"
else
    body+="${epic_repo}#${epic_number}"
fi
```

---

### Multi-Repo Milestones

**Strategy:** Ensure milestone exists in each target repo

**Implementation:**
```bash
# Ensure milestone in primary repo
milestone_num=$(ensure_milestone "$primary_repo" "$milestone_name")

# Ensure milestone in additional repos
for repo in $additional_repos; do
    ensure_milestone "$repo" "$milestone_name"
done
```

**Behavior:**
- Same milestone name across all repos
- Separate milestone numbers per repo
- Creates in each repo if needed

---

## Error Handling

### Missing Required Fields

**Validation:**
```bash
[[ -z "$context" ]] && error "Spec missing **Context:** field"
[[ -z "$spec_milestone" ]] && error "Spec missing **GitHub Milestone:** field"
[[ -z "$primary_repo" ]] && error "Spec missing **Primary Repository:** field"
```

**Behavior:**
- Hard fail before any API calls
- Clear error message pointing to missing field
- Exit code 1

---

### API Failures

**GitHub API:**
```bash
gh api "repos/$repo/milestones" 2>/dev/null || error "Failed to query milestones"
```

**Handling:**
- Redirect stderr to /dev/null (hide verbose errors)
- Check return code
- Show user-friendly error message

---

### Partial Creation

**Scenario:** Some issues created, then command fails

**Recovery:**
- Spec file updated with created issue numbers
- Re-running command skips existing issues
- Continues from failure point

**Example:**
```bash
# First run: Creates Epic #35, fails on issue #37
bobnet spec create-issues docs/SPEC.md
# Spec now has: Epic Issue: #35, Feature A #36

# Second run: Skips #35-#36, retries from #37
bobnet spec create-issues docs/SPEC.md
```

---

## Performance

### API Call Optimization

**Minimize Calls:**
- Query labels once per repo (cache result)
- Batch issue creation (no rate limiting needed for <100 issues)
- Reuse milestone numbers across work items

**Rate Limits:**
- GitHub API: 5,000 requests/hour (authenticated)
- Typical spec: ~50 API calls (milestone + labels + issues)
- Safe for specs with <100 work items

---

### Spec File Updates

**Strategy:** Atomic replacement

**Implementation:**
```bash
temp_spec=$(mktemp)
cp "$spec_file" "$temp_spec"
# ... make updates to temp file ...
mv "$temp_spec" "$spec_file"
```

**Safety:**
- Never modify original spec in-place
- All updates to temp file first
- Single atomic move at end

---

## Testing Strategy

See [vm-testing-guide.md](vm-testing-guide.md) for VM-based integration testing.

**Unit Tests:**
- Parse functions (extract_epics, extract_work_items)
- Label mapping (map_type_to_label)
- Deduplication logic (find_milestone)

**Integration Tests:**
- End-to-end spec → issues workflow
- Cross-repo issue creation
- Idempotency (run twice, same result)

**Edge Cases:**
- Empty spec (no Epics)
- Spec with only Epic, no work items
- All issues already exist
- Partial creation (some exist, some new)
- Cross-repo references

---

*Last updated: 2026-02-08*
