#!/usr/bin/env bash
# Safe agent workflow against a LibreSeal server. Never prints secret values.
#
# Required environment:
#   LIBRESEAL_HOST            server URL
#   LIBRESEAL_SERVICE_TOKEN   token of a service account limited to APP_ID/ALLOWED_ENV
#   APP_ID                    application ID (see `libreseal apps list`)
#   SECRET_KEY_NAME           a secret expected in ALLOWED_ENV (e.g. LS_TEST_KEY)
#   ALLOWED_ENV               environment the token can read (e.g. Development)
#   DENIED_ENV                environment the token must NOT read (e.g. Production)
set -euo pipefail

for v in LIBRESEAL_HOST LIBRESEAL_SERVICE_TOKEN APP_ID SECRET_KEY_NAME ALLOWED_ENV DENIED_ENV; do
  if [ -z "${!v:-}" ]; then echo "missing required variable: $v" >&2; exit 2; fi
done
case "$SECRET_KEY_NAME" in *[!A-Z0-9_]*|'') echo "SECRET_KEY_NAME must match [A-Z0-9_]+" >&2; exit 2 ;; esac

step() { printf '\n== %s\n' "$1"; }

step "1. Apps visible to this service account"
libreseal apps list >/dev/null
echo "OK: authenticated against $LIBRESEAL_HOST"

step "2. Inject $SECRET_KEY_NAME into a process and check it without printing it"
libreseal run --app-id "$APP_ID" --env "$ALLOWED_ENV" \
  "sh -c 'if [ -n \"\${$SECRET_KEY_NAME:-}\" ]; then echo \"OK: $SECRET_KEY_NAME is set in the process\"; else echo \"MISSING: $SECRET_KEY_NAME\"; exit 1; fi'"

step "3. Access outside the token scope must be denied"
if libreseal secrets list --app-id "$APP_ID" --env "$DENIED_ENV" >/dev/null 2>&1; then
  echo "UNEXPECTED: the token can read $DENIED_ENV — reduce the service account's access" >&2
  exit 1
fi
echo "OK: access to $DENIED_ENV denied"

step "Done: no secret values were printed"
