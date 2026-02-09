# Contributing to BobNet

Thank you for your interest in contributing to BobNet!

## Issue Labels

BobNet uses a `type:` prefixed label taxonomy for issue classification:

### Label Types

| Label | Purpose | When to Use |
|-------|---------|-------------|
| `type: feature` | New features, enhancements | Proposing new functionality or improvements |
| `type: bug` | Bug fixes | Reporting defects or unexpected behavior |
| `type: docs` | Documentation | Documentation updates, clarifications, examples |
| `type: test` | Testing | Test additions, test improvements, coverage |
| `type: chore` | Maintenance, tooling | Refactoring, dependency updates, tooling |

### For Humans: Use Issue Templates

When creating issues manually via GitHub's web UI:

1. Click "New Issue"
2. Select a template (Feature Request or Bug Report)
3. Fill out the form
4. Labels and project assignment happen automatically

**No manual labeling needed** — templates auto-assign the correct `type:` label.

### For Agents: Use `bobnet spec create-issues`

For multi-issue work (Epics, large features):

```bash
bobnet spec create-issues docs/MY-FEATURE-SPEC.md
```

This command:
- Reads the spec file
- Creates Epic + work item issues
- Auto-assigns `type:` labels based on work type (feat → type: feature, docs → type: docs, etc.)
- Links issues to the appropriate Epic
- Assigns to BobNet Work project

**No manual issue creation needed** — the spec workflow handles everything.

## Development Workflow

See [docs/COMMANDS.md](docs/COMMANDS.md) for BobNet CLI command reference.

For pattern documentation and best practices, see the `collective/patterns/` directory in [ultima-thule](https://github.com/buildzero-tech/ultima-thule).

## Questions?

- **GitHub Discussions:** https://github.com/buildzero-tech/bobnet-cli/discussions
- **Issues:** Use the issue templates for bugs or feature requests
