# BobNet

Multi-agent orchestration framework for OpenClaw/Clawdbot.

## Install

```bash
# New repo
curl -fsSL https://raw.githubusercontent.com/buildzero-tech/bobnet/main/install.sh | bash

# Clone existing
curl -fsSL https://raw.githubusercontent.com/buildzero-tech/bobnet/main/install.sh | bash -s -- --clone git@github.com:you/your-bobnet.git
```

## What it does

1. Installs prerequisites (git-crypt, jq)
2. Creates/clones a BobNet repository at `~/.bobnet/ultima-thule`
3. Sets up git-crypt encryption for `agents/` directory
4. Installs `bobnet` CLI to `~/.local/bin`
5. Configures OpenClaw with agent paths

## CLI

```bash
bobnet status   # Show agents and repo status
bobnet setup    # Configure OpenClaw with agent paths
bobnet unlock   # Unlock git-crypt
bobnet lock     # Lock git-crypt
```

## Structure

```
~/.bobnet/ultima-thule/
├── agents/           # Encrypted: credentials, sessions
├── workspace/        # Agent workspaces (SOUL.md, MEMORY.md, etc.)
├── collective/       # Shared resources (patterns, projects, rules)
├── core/             # Base AGENTS.md
├── config/           # agents-schema.v3.json
└── scripts/          # bobnet CLI
```
