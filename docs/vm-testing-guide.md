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

## Test Scenarios

### Scenario 1: Fresh Install (No Existing OpenClaw)

**Goal:** Validate end-to-end install from scratch

**Steps:**
1. Start clean VM
2. Install Node.js (v20+)
3. Install OpenClaw: `curl -fsSL https://openclaw.ai/install.sh | bash`
4. Verify OpenClaw: `openclaw --version`
5. Install bobnet CLI: `curl -fsSL https://raw.githubusercontent.com/buildzero-tech/bobnet-cli/main/install.sh | bash`
6. Clone ultima-thule (or create new repo)
7. Run `bobnet install`
8. Validate: `bobnet validate`
9. Start gateway: `openclaw gateway start`
10. Check health: `bobnet report`

**Expected Result:** All checks pass, agents configured, gateway running

---

### Scenario 2: Upgrade Happy Path

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

### Scenario 3: Upgrade with Rollback

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

### Scenario 4: Manual Rollback

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

### Scenario 5: Pre-flight Check Failures

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

## Quick Start

### 1. Spin up Ubuntu VM
```bash
multipass launch --name bobnet-test --cpus 2 --memory 4G --disk 20G
multipass shell bobnet-test
```

### 2. Run setup script
```bash
curl -fsSL <setup-script-url> | bash
```

### 3. Install bobnet + run tests
```bash
curl -fsSL <test-runner-url> | bash
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
