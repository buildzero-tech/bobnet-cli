# Release Workflow

Step-by-step guide for creating releases with BobNet tooling.

## Quick Start

```bash
# 1. Generate release notes
bobnet docs release-notes v1.4.0 > releases/v1.5.0.md

# 2. Update CHANGELOG
bobnet docs changelog >> CHANGELOG.md

# 3. Tag release
git tag -a v1.5.0 -m "Release v1.5.0"
git push origin v1.5.0

# 4. Publish GitHub release
gh release create v1.5.0 --notes-file releases/v1.5.0.md
```

---

## Detailed Workflow

### Step 1: Prepare Release

**Check milestone completion:**
```bash
# View milestone status
gh api repos/:owner/:repo/milestones --jq '.[] | select(.title == "Q1 2026") | {title, open_issues, closed_issues}'

# List remaining open issues
gh issue list --milestone "Q1 2026" --state open
```

**Ensure all PRs merged:**
```bash
# Check for open PRs
gh pr list --state open

# Check your assigned work
bobnet github my-issues
```

---

### Step 2: Generate Release Notes

**From GitHub issues (recommended):**
```bash
# Generate notes since last tag
bobnet docs release-notes v1.4.0 > releases/v1.5.0.md

# Review generated notes
cat releases/v1.5.0.md
```

**Example output:**
```markdown
# Release Notes

**Since:** v1.4.0

## ✨ Features

- Implement bobnet spec create-issues command (#36)
- Implement bobnet work start/done commands (#37, #38)
- Add release automation tools (#52-#54)

## 📚 Documentation

- Add comprehensive CLI reference (#42)
- Document release workflow (#56)

---

**Total:** 15 issue(s) closed
```

**Edit and enhance:**
```bash
# Add overview, breaking changes, upgrade notes
vim releases/v1.5.0.md
```

---

### Step 3: Update CHANGELOG

**Generate changelog entry:**
```bash
# For unreleased changes
bobnet docs changelog >> CHANGELOG.md

# Or for specific version
bobnet docs changelog v1.5.0 >> CHANGELOG.md
```

**Example CHANGELOG.md:**
```markdown
# Changelog

All notable changes to this project will be documented here.

## [1.5.0] - 2026-02-08

### Added
- bobnet spec create-issues command ([#36](../../issues/36))
- bobnet work start/done commands ([#37](../../issues/37), [#38](../../issues/38))
- Release automation tools ([#52](../../issues/52))

### Changed
- Enhanced changelog with issue links ([#53](../../issues/53))

### Fixed
- (none)

## [1.4.0] - 2026-02-01

...
```

---

### Step 4: Commit Documentation

**Commit release artifacts:**
```bash
# Add release notes and changelog
git add releases/v1.5.0.md CHANGELOG.md

# Commit
bobnet git commit "docs: add v1.5.0 release notes and changelog"

# Push
git push origin main
```

---

### Step 5: Tag Release

**Create annotated tag:**
```bash
# Tag with version
git tag -a v1.5.0 -m "Release v1.5.0

Features:
- Spec-based issue creation
- Work tracking commands
- Release automation

See releases/v1.5.0.md for full notes."

# Push tag
git push origin v1.5.0
```

**Verify tag:**
```bash
# Check tag exists
git tag | grep v1.5.0

# View tag details
git show v1.5.0
```

---

### Step 6: Create GitHub Release

**Publish release:**
```bash
# Create release from tag
gh release create v1.5.0 \
  --title "v1.5.0" \
  --notes-file releases/v1.5.0.md

# Or with inline notes
gh release create v1.5.0 \
  --title "v1.5.0" \
  --notes "$(cat releases/v1.5.0.md)"
```

**Verify release:**
```bash
# List releases
gh release list

# View release
gh release view v1.5.0
```

---

### Step 7: Announce Release

**Update project boards:**
```bash
# Close milestone
gh api -X PATCH repos/:owner/:repo/milestones/<num> \
  -f state=closed

# Update project
# (Manual via GitHub UI for now)
```

**Notify stakeholders:**
```bash
# Send to Signal group (if applicable)
message action=send channel=signal target=<group> \
  message="Released v1.5.0: [features summary]. See releases/v1.5.0.md"

# Or manual announcement
```

---

## Release Checklist

**Pre-release:**
- [ ] All milestone issues closed
- [ ] All PRs merged
- [ ] Tests passing (CI green)
- [ ] Documentation updated
- [ ] Breaking changes documented

**Release:**
- [ ] Release notes generated (`bobnet docs release-notes`)
- [ ] CHANGELOG updated (`bobnet docs changelog`)
- [ ] Release artifacts committed
- [ ] Tag created and pushed (`git tag -a vX.Y.Z`)
- [ ] GitHub release published (`gh release create`)

**Post-release:**
- [ ] Milestone closed
- [ ] Project board updated
- [ ] Stakeholders notified
- [ ] Next milestone planned

---

## Versioning

Follow [Semantic Versioning](https://semver.org):

- **Major (X.0.0):** Breaking changes
- **Minor (x.Y.0):** New features (backward-compatible)
- **Patch (x.y.Z):** Bug fixes (backward-compatible)

**Examples:**
- `v1.4.0 → v1.5.0` — Added work tracking commands (minor)
- `v1.5.0 → v1.5.1` — Fixed bug in work done (patch)
- `v1.5.1 → v2.0.0` — Changed spec format (major)

---

## Hotfix Workflow

**For urgent fixes:**

```bash
# 1. Create hotfix branch from tag
git checkout -b hotfix/v1.5.1 v1.5.0

# 2. Apply fix
# ... make changes ...

# 3. Commit
bobnet git commit "fix: critical bug #123"

# 4. Tag hotfix
git tag -a v1.5.1 -m "Hotfix v1.5.1: Fix critical bug"

# 5. Publish
gh release create v1.5.1 --notes "Hotfix for critical bug #123"

# 6. Merge back to main
git checkout main
git merge hotfix/v1.5.1
git push origin main
```

---

## Automated Release Workflow (Future)

**Potential automation via GitHub Actions:**

```yaml
name: Release

on:
  push:
    tags:
      - 'v*'

jobs:
  release:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      
      - name: Generate release notes
        run: bobnet docs release-notes ${{ github.ref_name }} > notes.md
        
      - name: Create GitHub release
        uses: softprops/action-gh-release@v1
        with:
          body_path: notes.md
```

---

## Related Documentation

- **Commands Reference:** [docs/COMMANDS.md](COMMANDS.md)
- **GitHub Releases:** https://docs.github.com/en/repositories/releasing-projects-on-github
- **Keep a Changelog:** https://keepachangelog.com
- **Semantic Versioning:** https://semver.org

---

*Last updated: 2026-02-08*
