# LifeOS Documentation Index

Quick reference for finding documentation. Each subfolder focuses on one topic.

## For AI Agents (LLMs)

Start here based on what you need:
- **Building/compiling?** → Read [CLAUDE.md](../CLAUDE.md) (root)
- **Architecture?** → [architecture/](architecture/)
- **What's been built?** → [strategy/](strategy/)
- **How to operate?** → [operations/](operations/)

## Directory Structure

| Folder | Purpose | Key Files |
|--------|---------|-----------|
| [strategy/](strategy/) | Strategic roadmap, phases, competition | unified-strategy |
| [architecture/](architecture/) | Technical architecture and specs | ai-runtime, llm-providers, threat-model, update-channels |
| [operations/](operations/) | Runbooks and operational guides | bootc-playbook, incident-response, build-iso, nvidia-secure-boot, system-admin |
| [user/](user/) | End-user documentation | installation, user-guide, troubleshooting |
| [branding/](branding/) | Visual identity and design | brand-guidelines, design-tokens, icon-theme-guide |
| [privacy/](privacy/) | Privacy analysis per LLM provider | claude, gemini, openai, grok, kimi, qwen, zai + routing policy |
| [contributor/](contributor/) | For contributors and developers | contributor-guide, testing-conventions |
| [research/](research/) | Research and reverse engineering | openclaw/ (21 docs) + nemoclaw/ (reverse engineering notes) |
| [archive/](archive/) | Deprecated/historical docs | firefox, cicd, testing-strategy, first-boot, hw-compat |

## Root-Level Files

| File | Purpose |
|------|---------|
| [CLAUDE.md](../CLAUDE.md) | Build commands, architecture, constraints for Claude Code |
| [GEMINI.md](../GEMINI.md) | Equivalent for Gemini |
| [AGENTS.md](../AGENTS.md) | Quick onboarding for AI agents |
| [README.md](../README.md) | Project entry point |
