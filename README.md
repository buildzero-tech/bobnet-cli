# BobNet

[![CI](https://github.com/buildzero-tech/bobnet-cli/actions/workflows/ci.yml/badge.svg)](https://github.com/buildzero-tech/bobnet-cli/actions/workflows/ci.yml)

Multi-agent orchestration framework for OpenClaw.

## Install

```bash
# New repo
curl -fsSL https://raw.githubusercontent.com/buildzero-tech/bobnet-cli/main/install.sh | bash

# Clone existing
curl -fsSL https://raw.githubusercontent.com/buildzero-tech/bobnet-cli/main/install.sh | bash -s -- --clone git@github.com:you/your-ultima-thule.git
```

## What it does

1. Installs prerequisites (git-crypt, jq)
2. Creates/clones a BobNet repository at `~/.bobnet/ultima-thule`
3. Sets up git-crypt encryption for `agents/` directory
4. Installs `bobnet` CLI to `~/.local/bin`
5. Configures OpenClaw with agent paths

## CLI

```bash
bobnet status            # Show agents and repo status
bobnet install           # Configure OpenClaw with BobNet agents
bobnet report            # Systems health check
bobnet memory status     # Show memory index status
bobnet memory rebuild    # Rebuild memory search indexes
bobnet search <pattern>  # Search session transcripts
bobnet search --errors   # Find common error patterns
bobnet unlock            # Unlock git-crypt
bobnet lock              # Lock git-crypt
bobnet update            # Update CLI to latest version
```

Run `bobnet help` or `bobnet <command> --help` for details.

See [docs/COMMANDS.md](docs/COMMANDS.md) for comprehensive command reference.

## Quick Start Examples

### Create Issues from Spec

```bash
# Write a spec with Epic structure
vim docs/FEATURE-SPEC.md

# Generate GitHub issues automatically
bobnet spec create-issues docs/FEATURE-SPEC.md

# Preview without creating
bobnet spec create-issues docs/FEATURE-SPEC.md --dry-run
```

### Work Tracking

```bash
# Start work on an issue
bobnet work start 42

# Make changes and commit with attribution
bobnet git commit "feat(feature): implement X #42"

# Complete work (finds commits, closes issue)
bobnet work done 42

# See all your assigned issues
bobnet github my-issues
```

### Typical Workflow

```bash
# 1. Create specification
cat > docs/MY-FEATURE-SPEC.md <<'EOF'
**Context:** BobNet Infrastructure
**GitHub Milestone:** Q1 Features
**Primary Repository:** buildzero-tech/bobnet-cli

### Epic: My Feature 📋
**Epic Issue:** TBD

#### Features (feat → enhancement)
- Implement feature A
- Implement feature B

#### Documentation (docs → documentation)
- Document feature usage
EOF

# 2. Generate issues from spec
bobnet spec create-issues docs/MY-FEATURE-SPEC.md
# Creates Epic + work items, updates spec with issue numbers

# 3. Work through issues
bobnet work start 36                        # Start first issue
# ... implement feature ...
bobnet git commit "feat: add feature A #36" # Commit with reference
bobnet work done 36                         # Close issue

# 4. Repeat for remaining issues
bobnet github my-issues                     # Check remaining work
```

### Todo Management

```bash
# Add todo to workspace/bob/MEMORY.md
- [ ] **Feature Name** — Description #42

# Work on it
bobnet work start 42

# Complete and mark done
# Edit MEMORY.md: [x] **Feature Name** — Description #42 (completed 2026-02-08)

# Sync with GitHub
bobnet todo sync
```

### Health Monitoring

```bash
# Check system health
bobnet report

# Rebuild stale memory indexes
bobnet memory rebuild --agent bob

# Search session transcripts
bobnet search "error pattern"
bobnet search --errors
```

## Structure

```
~/.bobnet/ultima-thule/
├── agents/           # Encrypted: credentials, auth profiles
├── workspace/        # Agent workspaces (SOUL.md, MEMORY.md, etc.)
├── collective/       # Shared resources (patterns, projects, rules)
├── core/             # Base AGENTS.md, templates
├── config/           # agents-schema.json
├── docs/             # Documentation
└── scripts/          # Installation-specific scripts
```

## Development

```bash
# Check syntax
bash -n bobnet.sh

# Bump version
./scripts/bump-version.sh patch  # or minor, major

# Release
git add version
git commit -m "chore: bump version to X.Y.Z"
git tag vX.Y.Z
git push origin main vX.Y.Z
```
