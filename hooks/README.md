# Git Hooks

Git hooks for enforcing code quality and commit standards.

## Available Hooks

### commit-msg

**Purpose:** Validate conventional commit message format

**Installation:**
```bash
# From repo root
cp hooks/commit-msg .git/hooks/commit-msg
chmod +x .git/hooks/commit-msg
```

**What it does:**
- Validates commit messages follow conventional commit format
- Checks for valid type (feat, fix, docs, test, chore, etc.)
- Checks for scope (optional but recommended)
- Warns if no issue reference found (#123)
- Skips validation for merge/revert commits

**Format:**
```
type(scope): description #issue

Required:
  type      - One of: feat, fix, docs, test, chore, refactor, perf, style, build, ci
  
Optional:
  (scope)   - Component or area affected (e.g., spec, work, github)
  #issue    - GitHub issue number (recommended)
```

**Examples:**
```bash
# Valid commits
git commit -m "feat(spec): add create-issues command #36"
git commit -m "fix(work): handle closed issues #37"
git commit -m "docs: update README #43"
git commit -m "test: add workflow tests #46"
git commit -m "chore: setup test infrastructure #49"

# Invalid commits (will be rejected)
git commit -m "Add new feature"          # Missing type
git commit -m "feat add feature"         # Missing colon
git commit -m "added: new feature"       # Invalid type
```

**Bypassing the hook:**
```bash
# Not recommended, but possible in emergencies
git commit --no-verify -m "message"
```

---

## Conventional Commit Types

| Type | Description | Label Mapping |
|------|-------------|---------------|
| `feat` | New feature | enhancement |
| `fix` | Bug fix | bug |
| `docs` | Documentation | documentation |
| `test` | Testing | testing |
| `chore` | Maintenance | maintenance |
| `refactor` | Code refactoring | enhancement |
| `perf` | Performance | enhancement |
| `style` | Code style | maintenance |
| `build` | Build system | maintenance |
| `ci` | CI/CD | maintenance |

---

## Testing the Hook

### Test valid commits

```bash
# These should succeed
echo "feat(test): add test feature #1" > /tmp/test-commit-msg
hooks/commit-msg /tmp/test-commit-msg
echo "Result: $?"  # Should be 0

echo "fix: simple fix" > /tmp/test-commit-msg
hooks/commit-msg /tmp/test-commit-msg
echo "Result: $?"  # Should be 0 (warns about missing issue)
```

### Test invalid commits

```bash
# These should fail
echo "Add new feature" > /tmp/test-commit-msg
hooks/commit-msg /tmp/test-commit-msg
echo "Result: $?"  # Should be 1

echo "added: new feature" > /tmp/test-commit-msg
hooks/commit-msg /tmp/test-commit-msg
echo "Result: $?"  # Should be 1
```

---

## Using with bobnet CLI

The `bobnet git commit` command automatically adds agent attribution:

```bash
# Without hook
bobnet git commit "feat(spec): add feature #36"
# Creates: [Bob] feat(spec): add feature #36

# With hook installed
# Hook validates format before commit
bobnet git commit "feat(spec): add feature #36"
# ✓ Format validated
# ✓ Agent attribution added
# ✓ Commit created
```

---

## Installation for All Contributors

**For your fork/clone:**
```bash
# After cloning repo
cp hooks/commit-msg .git/hooks/commit-msg
chmod +x .git/hooks/commit-msg
```

**Automate installation:**
```bash
# Add to your post-checkout or post-clone script
#!/bin/bash
if [ -f hooks/commit-msg ] && [ ! -f .git/hooks/commit-msg ]; then
    cp hooks/commit-msg .git/hooks/commit-msg
    chmod +x .git/hooks/commit-msg
    echo "✓ Installed commit-msg hook"
fi
```

---

## Troubleshooting

### Hook not running
```bash
# Verify hook is executable
ls -l .git/hooks/commit-msg

# If not executable
chmod +x .git/hooks/commit-msg
```

### Hook always fails
```bash
# Test hook directly
echo "feat: test" > /tmp/msg
.git/hooks/commit-msg /tmp/msg

# Check for errors
```

### Bypassing hook temporarily
```bash
# Use --no-verify (not recommended)
git commit --no-verify -m "emergency fix"
```

---

## Related Documentation

- **Conventional Commits:** https://www.conventionalcommits.org/
- **BobNet CLI Reference:** [docs/COMMANDS.md](../docs/COMMANDS.md)
- **Git Attribution:** `bobnet git commit`
