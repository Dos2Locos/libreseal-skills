# LibreSeal Skills

Agent skills for deploying and using [LibreSeal](https://github.com/Dos2Locos/libreseal), a free, self-hosted secrets manager.

> LibreSeal is an independent fork of Phase; this repository is a fork of [phasehq/ai](https://github.com/phasehq/ai). It is not affiliated with or endorsed by Phase.

## Skills

| Skill | Status | Purpose | Trigger phrase |
|-------|--------|---------|----------------|
| `docker-compose` | Supported | Deploy LibreSeal from source with Docker Compose (homelab first, optional Let's Encrypt), back up and upgrade it | "deploy LibreSeal with Docker Compose" |
| `libreseal-usage` | Supported | Use a LibreSeal server safely from an agent with the `libreseal` CLI and a least-privilege service account | "run my app with LibreSeal secrets" |
| `k8s`, `eks`, `aks` | **Not adapted** | Upstream Phase Helm/cloud guides, kept for reference. They deploy Phase images and charts, not LibreSeal | — |

## Install

With the [skills](https://skills.sh/) CLI:

```bash
npx skills add Dos2Locos/libreseal-skills -s docker-compose
npx skills add Dos2Locos/libreseal-skills -s libreseal-usage
```

Or copy a skill directory manually, e.g. for Claude Code:

```bash
git clone https://github.com/Dos2Locos/libreseal-skills.git
mkdir -p ~/.claude/skills
cp -R libreseal-skills/docker-compose ~/.claude/skills/libreseal-docker-compose
cp -R libreseal-skills/libreseal-usage ~/.claude/skills/libreseal-usage
```

The version-matched CLI guide is embedded in the CLI itself: a human runs `libreseal ai enable` to install it for the agent, or `libreseal ai skill` to print it.

## Safety model

- Agents get credentials only through `LIBRESEAL_HOST` / `LIBRESEAL_SERVICE_TOKEN` set by the user, from a service account restricted to the apps and environments they need — never an admin or personal token.
- Secrets are injected into processes with `libreseal run`; skills forbid printing them, putting them in prompts or writing them to version-controlled files.
- The CLI's agent detection (blocking `printenv` and friends) is defence in depth, not a security boundary.

`libreseal-usage/examples/agent-demo.sh` demonstrates the flow end to end and checks that access outside the token scope is denied.

## Verified combination

See the [LibreSeal README](https://github.com/Dos2Locos/libreseal#compatibility-and-limitations) for the server, CLI and skills commits verified together.

## License

MIT — see [LICENSE](LICENSE). Original skills © Phase; LibreSeal changes released under the same license.
