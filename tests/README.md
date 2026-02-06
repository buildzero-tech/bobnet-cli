# BobNet Test Suite

Automated tests for validating BobNet upgrade mechanisms in clean VM environments.

## Quick Start

### Ubuntu VM (multipass)

```bash
# Launch VM
multipass launch --name bobnet-test --cpus 2 --memory 4G --disk 20G
multipass shell bobnet-test

# Run full test suite (one command)
sudo apt update && \
sudo apt install -y nodejs npm git jq curl && \
npm install -g openclaw@2026.1.30 && \
export PATH="$HOME/.local/bin:$PATH" && \
curl -fsSL https://raw.githubusercontent.com/buildzero-tech/bobnet-cli/main/install.sh | bash -s -- --update && \
curl -fsSL https://raw.githubusercontent.com/buildzero-tech/bobnet-cli/main/test-suite-vm.sh | bash
```

Expected: All 3 tests pass (upgrade, rollback, re-upgrade)

---

## Test Scripts

### 1. `test-upgrade-vm.sh`

**Purpose:** Test OpenClaw upgrade from 2026.1.30 → latest

**What it does:**
1. Installs OpenClaw 2026.1.30
2. Installs BobNet CLI binary
3. Creates minimal test repo
4. Runs `bobnet install` (syncs config)
5. Runs `bobnet upgrade --openclaw`
6. Validates upgrade succeeded

**Usage:**
```bash
./test-upgrade-vm.sh [--verbose] [--clean]
```

**Flags:**
- `--verbose, -v` - Show command output
- `--clean` - Force clean install (deletes existing)

**Expected output:**
```
✓ Pre-upgrade:  2026.1.30
✓ Post-upgrade: 2026.2.3-1
✓ Config:       valid
✅ All tests passed
```

---

### 2. `test-rollback-vm.sh`

**Purpose:** Test rollback to pinned version

**Prerequisites:** Must run `test-upgrade-vm.sh` first

**What it does:**
1. Checks current version != pinned version
2. Runs `bobnet upgrade --openclaw --rollback`
3. Validates version rolled back
4. Validates config still valid

**Usage:**
```bash
./test-rollback-vm.sh [--verbose]
```

**Expected output:**
```
✓ Pre-rollback:  2026.2.3-1
✓ Post-rollback: 2026.1.30
✓ Pinned:        2026.1.30
✅ Rollback test passed
```

---

### 3. `test-suite-vm.sh`

**Purpose:** Run complete test suite

**What it does:**
1. Test 1: Upgrade (2026.1.30 → latest)
2. Test 2: Rollback (latest → 2026.1.30)
3. Test 3: Re-upgrade (2026.1.30 → latest)
4. Summary report

**Usage:**
```bash
./test-suite-vm.sh [--verbose]
```

**Expected output:**
```
=== Test 1/3: Upgrade (2026.1.30 → latest)
✓ Test 1 PASSED: Upgrade

=== Test 2/3: Rollback (latest → pinned)
✓ Test 2 PASSED: Rollback

=== Test 3/3: Re-upgrade (pinned → latest)
✓ Test 3 PASSED: Re-upgrade

=== Test Suite Summary
  Tests run:  3
  Passed:     3
  Failed:     0
  Duration:   45s

✅ All tests passed! ✨
```

---

## CI/CD Integration

### GitHub Actions

Tests run automatically on push/PR via `.github/workflows/test-upgrade.yml`

**Workflow steps:**
1. Setup Ubuntu environment
2. Install Node.js, npm, jq, curl
3. Install OpenClaw 2026.1.30
4. Install BobNet CLI
5. Run upgrade test
6. Verify version changed
7. Verify version tracking
8. Validate config

**View results:** Check "Actions" tab on GitHub

---

## Manual Testing

### Prerequisites
- Ubuntu 20.04+ or Debian-based Linux
- Node.js 20+
- npm, git, jq, curl

### Step-by-step

**1. Install OpenClaw 2026.1.30**
```bash
npm install -g openclaw@2026.1.30
export PATH="$HOME/.local/bin:$PATH"
openclaw --version  # Should show 2026.1.30
```

**2. Install BobNet CLI**
```bash
curl -fsSL https://raw.githubusercontent.com/buildzero-tech/bobnet-cli/main/install.sh | bash -s -- --update
export PATH="$HOME/.local/bin:$PATH"
bobnet --version
```

**3. Clone bobnet-cli repo**
```bash
git clone https://github.com/buildzero-tech/bobnet-cli.git
cd bobnet-cli
```

**4. Run tests**
```bash
# Single test
./test-upgrade-vm.sh --verbose

# Full suite
./test-suite-vm.sh --verbose
```

---

## Cleanup

### Delete VM
```bash
multipass delete bobnet-test
multipass purge
```

### Or stop for later
```bash
multipass stop bobnet-test

# Resume later
multipass start bobnet-test
multipass shell bobnet-test
```

---

## Troubleshooting

### Test fails: "OpenClaw not found"
```bash
# Add to PATH
export PATH="$HOME/.local/bin:$PATH"

# Verify
which openclaw
```

### Test fails: "Version tracking not found"
Run upgrade test first:
```bash
./test-upgrade-vm.sh --clean
```

### Test fails: "npm install failed"
Check Node.js version:
```bash
node --version  # Should be 20+
```

### CI failing on GitHub Actions
Check logs in Actions tab. Common issues:
- npm registry timeout (retry)
- Version not available (check npm)

---

## Adding New Tests

1. Create `test-<name>-vm.sh` in repo root
2. Follow existing script structure
3. Add to `test-suite-vm.sh` if appropriate
4. Update this README
5. Consider adding to `.github/workflows/test-upgrade.yml`

---

## Documentation

Full guide: `docs/vm-testing-guide.md`
