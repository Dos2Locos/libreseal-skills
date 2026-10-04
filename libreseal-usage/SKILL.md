---
name: libreseal-usage
description: |
  Use a self-hosted LibreSeal server safely from an AI agent through the libreseal CLI.
  Triggers: "use LibreSeal", "get secrets from LibreSeal", "run my app with LibreSeal secrets",
  "set up the libreseal CLI", "configure an agent for LibreSeal", "libreseal run".
---

# Use LibreSeal safely from an agent

The authoritative, version-matched command guide ships inside the CLI. Prefer it over this file when they differ:

```bash
libreseal ai skill        # prints the guide for the installed CLI version
```

A human can install it into the agent's skill directory with `libreseal ai enable` (agents cannot run that command).

## Rules

- **Least privilege.** Use only a token from a dedicated LibreSeal **service account** limited to the app(s) and environment(s) required. Never use, request or store a personal or administrator token for routine agent work.
- **The user provides credentials through the environment**, never through chat or files you can read:
  ```bash
  export LIBRESEAL_HOST=https://secrets.example.lan
  export LIBRESEAL_SERVICE_TOKEN=...        # set by the user; never echo it
  ```
- **Never reveal secret values.** Do not print them, paste them into prompts, logs, commit messages or issues, and do not write them into version-controlled files (`.env`, YAML, source). Do not redirect `libreseal secrets export` to files.
- **Inject, don't copy.** Start processes with `libreseal run '<command>'` so secrets go straight into the process environment.
- **Generate sensitive values** with `--random` (`libreseal secrets create KEY --random base64url --length 48 --type sealed`). Ask the user to type any specific sensitive value themselves.
- **On 401/403, stop.** Report which app/environment was denied; do not ask for broader credentials.
- The CLI blocks `printenv`/`env`/`export`/`set` inside `libreseal run` when it detects an agent; this is defence in depth and can be bypassed, so the rules above still apply.

## Setup check

```bash
command -v libreseal || echo "Install: https://github.com/Dos2Locos/libreseal-cli#install"
libreseal --version
libreseal apps list            # confirms host + token work and shows the reachable apps
```

For self-signed LAN certificates during testing only: `export LIBRESEAL_VERIFY_SSL=False`.

## Common tasks

```bash
libreseal init --app-id <APP_ID> --env development           # link the working directory
libreseal secrets list                                       # metadata; values masked by default
libreseal secrets create API_KEY --random hex --length 64 --type sealed
echo "info" | libreseal secrets create LOG_LEVEL --type config
libreseal run 'npm start'                                    # run with secrets injected
libreseal run 'sh -c "test -n \"$DATABASE_URL\" && echo DATABASE_URL is set"'   # check presence only
```

## Verifiable example

`examples/agent-demo.sh` walks through the safe flow (list apps, inject a secret into a process and check it without printing it, confirm access outside the token's scope is denied):

```bash
export LIBRESEAL_HOST=https://localhost:8443 LIBRESEAL_VERIFY_SSL=False
export LIBRESEAL_SERVICE_TOKEN=...                 # service account limited to demo/Development
APP_ID=<id> SECRET_KEY_NAME=LS_TEST_KEY ALLOWED_ENV=Development DENIED_ENV=Production \
  ./examples/agent-demo.sh
```

## Not available in LibreSeal

Dynamic secrets, secret rotation, log streams, SCIM and organisation-level OIDC SSO are not part of LibreSeal.
