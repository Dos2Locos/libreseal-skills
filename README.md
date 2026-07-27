# Phase AI Skills

AI skills for deploying and managing [Phase](https://phase.dev) — the open-source secrets manager.

Install deployment skills into your AI coding agent (Claude Code, Cursor, Windsurf, GitHub Copilot) with a single command via the [skills](https://skills.sh/) ecosystem.

## Usage

```bash
# Install all skills
npx skills add phasehq/ai

# Install a specific skill
npx skills add phasehq/ai -s docker-compose
```

Then ask your AI agent: **"deploy Phase with Docker Compose"**

## Available Skills

| Skill | Description | Trigger Phrase |
|-------|-------------|----------------|
| `docker-compose` | Deploy Phase Console with Docker Compose and Let's Encrypt TLS | "deploy Phase with Docker Compose" |
| `k8s` | Deploy Phase Console on any Kubernetes cluster via Helm | "deploy Phase on Kubernetes" |
| `eks` | Deploy Phase Console on AWS EKS with Helm and native AWS services | "deploy Phase on EKS" |
| `aks` | Deploy Phase Console on Azure AKS with Azure-native services and optional Tailscale networking | "deploy Phase on AKS" |

## How it works

Skills are markdown files that teach AI coding agents how to deploy Phase step-by-step. The [`skills`](https://skills.sh/) CLI installs them into your agent's skills directory (e.g. `.claude/skills/`). Your AI agent reads these files and uses them to automate the deployment interactively.

Each skill includes:
- **SKILL.md** — The main instruction file with workflow phases and principles
- **refs/** — Reference files with exact templates, commands, and troubleshooting guides

## Documentation

Full deployment guides: [docs.phase.dev/self-hosting](https://docs.phase.dev/self-hosting)

## License

MIT
