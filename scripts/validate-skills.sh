#!/usr/bin/env bash
# Validates the skills repository without network services or secrets.
# Run locally or in CI: scripts/validate-skills.sh
#
# Checks:
#   1. Every SKILL.md has front matter with `name` equal to its directory and
#      a non-empty `description`.
#   2. Tracked shell scripts pass shellcheck.
#   3. Every ```nginx block in tracked Markdown passes `nginx -t` (blocks whose
#      first line starts with "# fragment" are partial and skipped).
#   4. No .env files or LibreSeal/Phase tokens are tracked (values never shown).
#
# Requires: git, python3, openssl, docker; shellcheck (or docker to run it).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Official nginx image, pinned by digest (nginx:stable, 1.30.5).
NGINX_IMAGE="nginx@sha256:9bf97bd7714f5e24c1ccd545ecb9eb5435cb6d109c97cebb15e7e455e0239edb"
SHELLCHECK_IMAGE="koalaman/shellcheck:stable"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
failures=0
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }
ok() { echo "ok: $*"; }

# 1. SKILL.md front matter ----------------------------------------------------
while IFS= read -r skill; do
  if msg="$(python3 - "$skill" 2>&1 <<'PY'
import os, sys

path = sys.argv[1]
lines = open(path, encoding="utf-8").read().splitlines()
if not lines or lines[0].strip() != "---":
    sys.exit("missing front matter")
try:
    end = lines.index("---", 1)
except ValueError:
    sys.exit("unterminated front matter")
fields, key = {}, None
for line in lines[1:end]:
    if line[:1] in (" ", "\t"):
        if key:
            fields[key] += " " + line.strip()
        continue
    if ":" in line:
        key, value = line.split(":", 1)
        key, value = key.strip(), value.strip()
        fields[key] = "" if value in ("|", ">", "|-", ">-") else value.strip("'\"")
expected = os.path.basename(os.path.dirname(path))
if fields.get("name") != expected:
    sys.exit(f"name is {fields.get('name')!r}, expected {expected!r}")
if not fields.get("description", "").strip():
    sys.exit("empty description")
PY
  )"; then
    ok "front matter $skill"
  else
    fail "front matter $skill: $msg"
  fi
done < <(git ls-files '*SKILL.md')

# 2. shellcheck ---------------------------------------------------------------
mapfile -t scripts < <(git ls-files '*.sh')
if [ "${#scripts[@]}" -gt 0 ]; then
  if command -v shellcheck >/dev/null 2>&1; then
    sc=(shellcheck)
  else
    sc=(docker run --rm -v "$ROOT:/mnt" -w /mnt "$SHELLCHECK_IMAGE")
  fi
  if "${sc[@]}" "${scripts[@]}"; then
    ok "shellcheck (${#scripts[@]} scripts)"
  else
    fail "shellcheck"
  fi
fi

# 3. nginx blocks -------------------------------------------------------------
python3 - "$WORK/nginx" <<'PY'
import os, re, subprocess, sys, textwrap

out = sys.argv[1]
os.makedirs(out)
files = subprocess.run(["git", "ls-files", "*.md"], capture_output=True, text=True, check=True).stdout.split()
n = 0
for path in files:
    lines = open(path, encoding="utf-8").read().splitlines()
    i = 0
    while i < len(lines):
        m = re.match(r"^(\s*)```nginx\s*$", lines[i])
        if not m:
            i += 1
            continue
        start, j = i + 1, i + 1
        while j < len(lines) and lines[j].strip() != "```":
            j += 1
        body = textwrap.dedent("\n".join(lines[start:j]))
        first = next((l.strip() for l in body.splitlines() if l.strip()), "")
        if not first.startswith("# fragment"):
            n += 1
            body = re.sub(r"\{[A-Z_]+\}", "example.com", body)
            with open(os.path.join(out, f"{n:02d}.conf"), "w") as f:
                f.write(f"# source: {path}:{start}\n{body}\n")
        i = j + 1
PY
blocks=("$WORK"/nginx/*.conf)
if [ -e "${blocks[0]}" ]; then
  mkdir -p "$WORK/ssl"
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=example.com" \
    -keyout "$WORK/ssl/nginx.key" -out "$WORK/ssl/nginx.crt" >/dev/null 2>&1
  : >"$WORK/real-ip.conf"
  for conf in "${blocks[@]}"; do
    src="$(head -1 "$conf" | sed 's/^# source: //')"
    if result="$(docker run --rm \
      -v "$conf:/etc/nginx/conf.d/default.conf:ro" \
      -v "$WORK/ssl:/etc/nginx/ssl:ro" \
      -v "$WORK/real-ip.conf:/etc/nginx/real-ip.conf:ro" \
      "$NGINX_IMAGE" nginx -t 2>&1)"; then
      ok "nginx -t $src"
    else
      fail "nginx -t $src"
      echo "$result" >&2
    fi
  done
fi

# 4. No .env files or tokens ----------------------------------------------------
while IFS= read -r f; do
  fail "tracked env file: $f"
done < <(git ls-files | grep -E '(^|/)\.env(\..+)?$' | grep -vE '\.example$' || true)
if hits="$(git grep -nE 'pss_(service|user):v?[0-9]+:[A-Za-z0-9]' -- . || true)" && [ -n "$hits" ]; then
  # Show file:line only, never the token value.
  while IFS= read -r hit; do
    fail "token-like value at $(echo "$hit" | cut -d: -f1-2)"
  done <<<"$hits"
else
  ok "no tracked .env files or tokens"
fi

if [ "$failures" -gt 0 ]; then
  echo "validate-skills: $failures check(s) failed" >&2
  exit 1
fi
echo "validate-skills: all checks passed"
