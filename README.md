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
