# BobNet VM Testing Guide

## Purpose
Test bobnet install and upgrade flows in clean environments to validate:
- Fresh install process
- OpenClaw version pinning
- Upgrade mechanism (success path)
- Upgrade rollback (failure path)
- Pre-flight checks

## VM Environment Options

### Option 1: Ubuntu VM (Recommended for Speed)
**Pros:** Fast to spin up, lightweight, easy automation
**Cons:** Linux ≠ macOS (some platform differences)

```bash
# multipass (on macOS host)
multipass launch --name bobnet-test --cpus 2 --memory 4G --disk 20G
multipass shell bobnet-test

# Or VirtualBox/VMware with Ubuntu 24.04 LTS
```

### Option 2: macOS VM (Most Realistic)
**Pros:** Mirrors Matrix1 exactly, tests macOS-specific features
**Cons:** Requires macOS host, slower, license restrictions

```bash
# UTM (recommended for Apple Silicon)
# Download macOS Sonoma/Sequoia ISO, create VM
# 4GB RAM, 40GB disk minimum
```

### Option 3: Docker Container (Experimental)
**Pros:** Fastest iteration, easy cleanup
**Cons:** systemd/launchd limitations, less realistic

```bash
# Not recommended for OpenClaw (needs background services)
```

## Primary Test Flow

### Goal
Test the upgrade path from OpenClaw 2026.1.30 (current Matrix1 version) to latest.

### Steps

**1. Install OpenClaw 2026.1.30**
```bash
npm install -g openclaw@2026.1.30
openclaw --version  # Should show 2026.1.30
```

**2. Install BobNet CLI Binary**

**What this does:** Installs the `bobnet` command to `~/.local/bin/bobnet`

```bash
# Install CLI binary only (no repo setup)
curl -fsSL https://raw.githubusercontent.com/buildzero-tech/bobnet-cli/main/install.sh | bash -s -- --update

# Add to PATH for current session
export PATH="$HOME/.local/bin:$PATH"

# Verify installation
bobnet --version
which bobnet  # Should show ~/.local/bin/bobnet
```

**Note:** `install.sh --update` installs **only the CLI binary**, not the repo. We'll create the repo manually in the next step.

**3. Set up minimal BobNet repo**
```bash
# Option A: Clone existing (requires auth)
git clone git@github.com:buildzero-tech/ultima-thule.git ~/.bobnet/ultima-thule

# Option B: Create minimal test repo
mkdir -p ~/.bobnet/ultima-thule/{config,workspace/bob,agents/bob}
cat > ~/.bobnet/ultima-thule/config/bobnet.json << 'EOF'
{
  "version": "3.5",
  "defaults": {
    "model": "anthropic/claude-sonnet-4-5"
  },
  "agents": {
    "bob": {
      "scope": "meta",
      "default": true,
      "model": "anthropic/claude-sonnet-4-5"
    }
  },
  "scopes": {
    "meta": {
      "label": "Meta",
      "collective": "collective/"
    }
  }
}
EOF
```

**4. Install BobNet Config into OpenClaw**

**What this does:** Reads `config/bobnet.json` and syncs agents/bindings/channels into OpenClaw's config (`~/.openclaw/openclaw.json`)

```bash
cd ~/.bobnet/ultima-thule

# Sync BobNet config → OpenClaw
bobnet install

# What gets synced:
#   - Agents (bob) → OpenClaw agents.list
#   - Bindings → OpenClaw bindings
#   - Channels → OpenClaw channels
```

**This is separate from installing the CLI binary.** You need both:
1. `install.sh` → installs the `bobnet` command
2. `bobnet install` → syncs your config into OpenClaw

**5. Verify initial state**
```bash
openclaw --version        # Should be 2026.1.30
bobnet validate          # Should pass
openclaw gateway status  # Check if running
```

**6. Run upgrade**
```bash
bobnet upgrade --openclaw
```

**7. Verify upgrade succeeded**
```bash
openclaw --version        # Should be latest (2026.2.3-1 or newer)
bobnet validate          # Should still pass
openclaw gateway status  # Should be running
cat ~/.bobnet/ultima-thule/config/openclaw-versions.json  # Check history
```

### Expected Results

**Pre-upgrade:**
- OpenClaw 2026.1.30 installed
- BobNet configured
- Gateway running
- `openclaw-versions.json` created with initial version

**Post-upgrade:**
- OpenClaw upgraded to latest
- Gateway restarted successfully
- Config preserved
- Version history tracked
- Health checks pass

**Upgrade output should show:**
```
Pre-flight checks...
✓ Disk space: adequate
✓ npm registry: reachable
✓ Target version: 2026.2.3-1

Backing up config...
✓ Config backed up

Stopping gateway...
✓ Gateway stopped

Installing openclaw@2026.2.3-1...
✓ Installed

Starting gateway...
✓ Gateway started

Health checks...
✓ Version: 2026.2.3-1
✓ API responding

✓ Upgrade complete
```

---

## Alternative Test Scenarios

### Scenario A: Fresh Install (No Existing OpenClaw)

**Goal:** Validate end-to-end install from scratch (not primary test)

**Steps:**
1. Start clean VM
2. Install Node.js (v20+)
3. Install OpenClaw latest: `curl -fsSL https://openclaw.ai/install.sh | bash`
4. Verify OpenClaw: `openclaw --version`
5. Install bobnet CLI: `curl -fsSL https://raw.githubusercontent.com/buildzero-tech/bobnet-cli/main/install.sh | bash`
6. Set up minimal repo (see Primary Test Flow step 3)
7. Run `bobnet install`
8. Validate: `bobnet validate`

**Expected Result:** All checks pass, agents configured, gateway running

---

### Scenario B: Upgrade Happy Path (Covered by Primary Flow)

**Goal:** Test normal upgrade flow with health checks passing

**Prerequisites:** Scenario 1 complete, OpenClaw running

**Steps:**
1. Check current version: `openclaw --version`
2. Pin current as stable: `bobnet upgrade --openclaw --pin`
3. Verify version tracking: `cat ~/.bobnet/ultima-thule/config/openclaw-versions.json`
4. Dry run upgrade: `bobnet upgrade --openclaw --dry-run`
5. Run upgrade: `bobnet upgrade --openclaw --yes`
6. Verify new version: `openclaw --version`
7. Check health: `bobnet report`
8. Verify version history updated

**Expected Result:** 
- Upgrade succeeds
- Health checks pass
- Version tracking updated
- Gateway runs on new version

---

### Scenario C: Upgrade with Rollback (Advanced)

**Goal:** Test automatic rollback when health checks fail

**Prerequisites:** Scenario 2 complete, running upgraded version

**Steps:**
1. Manually break config to trigger health check failure:
   ```bash
   openclaw config set agents.list '[]' --json
   ```
2. Attempt "upgrade" (will fail health check): 
   ```bash
   bobnet upgrade --openclaw --version <different-version>
   ```
3. Verify rollback triggered
4. Check version restored: `openclaw --version`
5. Verify config restored

**Expected Result:**
- Health check fails
- Auto-rollback triggers
- Previous version reinstalled
- Config restored from backup

---

### Scenario D: Manual Rollback (Advanced)

**Goal:** Test explicit rollback command

**Prerequisites:** Scenario 2 complete (upgraded version running)

**Steps:**
1. Check current version: `openclaw --version`
2. Check pinned version: `cat ~/.bobnet/ultima-thule/config/openclaw-versions.json | jq .pinned`
3. Run rollback: `bobnet upgrade --openclaw --rollback`
4. Verify version: `openclaw --version` (should match pinned)
5. Check health: `bobnet report`

**Expected Result:**
- Rollback to pinned version succeeds
- Health checks pass
- No data loss

---

### Scenario E: Pre-flight Check Failures (Advanced)

**Goal:** Validate pre-flight checks prevent bad upgrades

**Prerequisites:** Fresh VM or Scenario 1

**Test 5a: Insufficient Disk Space**
```bash
# Fill disk to <500MB free
dd if=/dev/zero of=/tmp/fill bs=1M count=<calculated>
bobnet upgrade --openclaw
# Should fail with disk space error
rm /tmp/fill
```

**Test 5b: Network Unreachable**
```bash
# Disconnect network or block npm registry
bobnet upgrade --openclaw
# Should fail with registry unreachable error
```

**Test 5c: Invalid Version**
```bash
bobnet upgrade --openclaw --version 9999.99.99
# Should fail with version not found error
```

**Expected Result:** All pre-flight failures caught before attempting upgrade

---

## VM Setup Scripts

### Ubuntu VM (Automated Setup)

```bash
#!/bin/bash
# setup-ubuntu-vm.sh - Prepare Ubuntu VM for bobnet testing

set -euo pipefail

echo "=== BobNet VM Setup ==="

# Update system
sudo apt update && sudo apt upgrade -y

# Install dependencies
sudo apt install -y curl git jq git-crypt age

# Install Node.js v20 LTS
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt install -y nodejs

# Verify versions
echo ""
echo "Installed versions:"
node --version
npm --version
git --version

# Install OpenClaw
echo ""
echo "Installing OpenClaw..."
curl -fsSL https://openclaw.ai/install.sh | bash

# Add to PATH for current session
export PATH="$HOME/.local/bin:$PATH"

# Verify
openclaw --version

echo ""
echo "=== Setup Complete ==="
echo "Next steps:"
echo "  1. Install bobnet CLI"
echo "  2. Clone/create ultima-thule repo"
echo "  3. Run 'bobnet install'"
```

### Test Runner Script

```bash
#!/bin/bash
# run-upgrade-tests.sh - Run all upgrade test scenarios

set -euo pipefail

LOGFILE="upgrade-test-$(date +%Y%m%d_%H%M%S).log"

log() {
    echo "[$(date +'%H:%M:%S')] $*" | tee -a "$LOGFILE"
}

run_test() {
    local scenario="$1"
    log "=== Starting: $scenario ==="
    
    if "$scenario"; then
        log "✓ PASS: $scenario"
        return 0
    else
        log "✗ FAIL: $scenario"
        return 1
    fi
}

test_fresh_install() {
    # Implement Scenario 1
    log "Installing bobnet CLI..."
    curl -fsSL https://raw.githubusercontent.com/buildzero-tech/bobnet-cli/main/install.sh | bash
    
    log "Installing OpenClaw config..."
    # TODO: Clone test repo or create minimal config
    bobnet install --yes
    
    bobnet validate
}

test_upgrade_happy() {
    # Implement Scenario 2
    bobnet upgrade --openclaw --pin
    bobnet upgrade --openclaw --dry-run
    bobnet upgrade --openclaw --yes
    bobnet validate
}

test_rollback_auto() {
    # Implement Scenario 3
    # TODO: Break config, trigger rollback
    :
}

test_rollback_manual() {
    # Implement Scenario 4
    bobnet upgrade --openclaw --rollback
    bobnet validate
}

# Run tests
run_test test_fresh_install
run_test test_upgrade_happy
run_test test_rollback_manual

log "=== Test Summary ==="
log "Full log: $LOGFILE"
```

---

## Quick Start (Primary Test)

### Option A: Automated (One Command)

**Run from your Mac** - creates VM, runs tests, cleans up:

```bash
cd ~/.bobnet/repos/bobnet-cli
./test-vm-full.sh
```

**With options:**
```bash
./test-vm-full.sh --keep           # Keep VM after tests
./test-vm-full.sh --verbose        # Show verbose output
./test-vm-full.sh --name my-test   # Custom VM name
```

**What it does:**
1. Creates Ubuntu VM via multipass
2. Installs dependencies inside VM
3. Runs full test suite (upgrade + rollback + re-upgrade)
4. Reports results
5. Deletes VM (unless --keep)

---

### Option B: Manual (Two Steps)

**Step 1: Create VM (on your Mac)**
```bash
multipass launch --name bobnet-test --cpus 2 --memory 4G --disk 20G
multipass shell bobnet-test
```

**Step 2: Run tests (inside VM)**

**Then continue with manual steps:**

### 2. Install dependencies (inside VM)
```bash
# Update system
sudo apt update && sudo apt upgrade -y

# Install Node.js v20 LTS
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt install -y nodejs

# Install tools
sudo apt install -y git jq curl

# Verify
node --version
npm --version
```

### 3. Install OpenClaw 2026.1.30
```bash
npm install -g openclaw@2026.1.30
export PATH="$HOME/.local/bin:$PATH"
openclaw --version  # Should show 2026.1.30
```

### 4. Install BobNet CLI Binary
```bash
# Install CLI binary only (not the repo)
curl -fsSL https://raw.githubusercontent.com/buildzero-tech/bobnet-cli/main/install.sh | bash -s -- --update

# Add to PATH
export PATH="$HOME/.local/bin:$PATH"

# Verify
bobnet --version
which bobnet  # Should show ~/.local/bin/bobnet
```

### 5. Create minimal test repo
```bash
mkdir -p ~/.bobnet/ultima-thule/{config,workspace/bob,agents/bob}
cat > ~/.bobnet/ultima-thule/config/bobnet.json << 'EOF'
{
  "version": "3.5",
  "defaults": {
    "model": "anthropic/claude-sonnet-4-5"
  },
  "agents": {
    "bob": {
      "scope": "meta",
      "default": true,
      "model": "anthropic/claude-sonnet-4-5"
    }
  },
  "scopes": {
    "meta": {
      "label": "Meta",
      "collective": "collective/"
    }
  }
}
EOF

# Initialize as git repo
cd ~/.bobnet/ultima-thule
git init
git add -A
git commit -m "Initial test repo"
```

### 6. Sync BobNet Config into OpenClaw
```bash
cd ~/.bobnet/ultima-thule

# This reads config/bobnet.json and writes to ~/.openclaw/openclaw.json
bobnet install

# Verify sync worked
bobnet validate
```

**What happens:**
- Reads `config/bobnet.json`
- Syncs agents → `~/.openclaw/openclaw.json` (agents.list)
- Syncs bindings → `~/.openclaw/openclaw.json` (bindings)
- Syncs channels → `~/.openclaw/openclaw.json` (channels)

**This is step 2 of BobNet installation.** Step 1 was installing the CLI binary.

### 7. Run the upgrade test

**Option A: Single Test (Upgrade Only)**
```bash
curl -fsSL https://raw.githubusercontent.com/buildzero-tech/bobnet-cli/main/test-upgrade-vm.sh | bash
```

**Option B: Full Test Suite (Upgrade + Rollback + Re-upgrade)**
```bash
curl -fsSL https://raw.githubusercontent.com/buildzero-tech/bobnet-cli/main/test-suite-vm.sh | bash
```

**Option C: Manual**
```bash
echo "=== Pre-upgrade state ==="
openclaw --version

echo ""
echo "=== Running upgrade ==="
bobnet upgrade --openclaw

echo ""
echo "=== Post-upgrade state ==="
openclaw --version
bobnet validate

echo ""
echo "=== Version history ==="
cat ~/.bobnet/ultima-thule/config/openclaw-versions.json
```

---

## Automated Test Scripts

Three test scripts available:

**1. `test-upgrade-vm.sh`** - Upgrade test only
- Installs OpenClaw 2026.1.30
- Installs BobNet CLI
- Creates test repo
- Runs `bobnet upgrade --openclaw`
- Validates upgrade succeeded

**2. `test-rollback-vm.sh`** - Rollback test
- Requires upgrade test to run first
- Runs `bobnet upgrade --openclaw --rollback`
- Validates rollback to pinned version

**3. `test-suite-vm.sh`** - Full suite
- Runs upgrade test
- Runs rollback test  
- Runs re-upgrade test
- Reports pass/fail summary

**Usage:**
```bash
# Single test
./test-upgrade-vm.sh [--verbose] [--clean]

# Rollback test
./test-rollback-vm.sh [--verbose]

# Full suite
./test-suite-vm.sh [--verbose]
```

**Flags:**
- `--verbose, -v` - Show command output
- `--clean` - Force clean install (deletes existing repos)

---

## One-Liner Test (Ubuntu VM)

**Quick upgrade test:**
```bash
sudo apt update && \
sudo apt install -y nodejs npm git jq curl && \
npm install -g openclaw@2026.1.30 && \
export PATH="$HOME/.local/bin:$PATH" && \
curl -fsSL https://raw.githubusercontent.com/buildzero-tech/bobnet-cli/main/install.sh | bash -s -- --update && \
curl -fsSL https://raw.githubusercontent.com/buildzero-tech/bobnet-cli/main/test-upgrade-vm.sh | bash
```

**Full test suite:**
```bash
sudo apt update && \
sudo apt install -y nodejs npm git jq curl && \
npm install -g openclaw@2026.1.30 && \
export PATH="$HOME/.local/bin:$PATH" && \
curl -fsSL https://raw.githubusercontent.com/buildzero-tech/bobnet-cli/main/install.sh | bash -s -- --update && \
curl -fsSL https://raw.githubusercontent.com/buildzero-tech/bobnet-cli/main/test-suite-vm.sh | bash
```

---

## One-Liner Test (Old Version)

**What it does:**
1. Installs Node.js, npm, git, jq, curl
2. Installs OpenClaw 2026.1.30
3. Installs BobNet CLI binary (`--update` flag = CLI only, no repo)
4. Runs automated upgrade test script (creates test repo + runs upgrade)
5. Reports results

**Two-step BobNet installation:**
- `install.sh --update` → Installs `bobnet` command
- Test script runs `bobnet install` → Syncs config into OpenClaw

**Expected output (upgrade test):**
```
✓ Pre-upgrade:  2026.1.30
✓ Post-upgrade: 2026.2.3-1
✓ Config:       valid
✓ Gateway:      running

✅ All tests passed
```

**Expected output (full suite):**
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

## GitHub Actions CI

Tests run automatically on every push/PR via `.github/workflows/test-upgrade.yml`

**What gets tested:**
- Fresh Ubuntu environment
- Install OpenClaw 2026.1.30
- Install BobNet CLI
- Run upgrade test
- Verify version changed
- Verify version tracking works
- Validate config

**To run locally:**
```bash
cd ~/.bobnet/repos/bobnet-cli
act  # Uses nektos/act to run GitHub Actions locally
```

---

## Cleanup

```bash
# Delete VM
multipass delete bobnet-test
multipass purge

# Or stop for later reuse
multipass stop bobnet-test
```

---

## Next Steps

1. **Create minimal test repo** - Stripped-down ultima-thule for testing (no secrets)
2. **Automate test scenarios** - CI/CD pipeline for upgrade testing
3. **Document edge cases** - What happens when gateway is down during upgrade?
4. **Performance benchmarks** - How long does upgrade take? Acceptable downtime?
