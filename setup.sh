#!/usr/bin/env bash
# One-time setup: create .env (with generated secrets on first run) and render
# the Keycloak realm file from it. Safe to re-run — it never overwrites .env.
set -euo pipefail
cd "$(dirname "$0")"

# 1. Create .env from the template, filling every CHANGE_ME with a random secret.
if [[ ! -f .env ]]; then
  echo "Creating .env with generated secrets..."
  cp .env.example .env
  # replace each CHANGE_ME_* value with a fresh random hex string
  while IFS= read -r line; do
    if [[ "$line" =~ ^([A-Z_]+)=(sk-)?CHANGE_ME ]]; then
      key="${BASH_REMATCH[1]}"; prefix="${BASH_REMATCH[2]:-}"
      val="${prefix}$(openssl rand -hex 24)"
      # portable in-place edit
      sed -i.bak "s|^${key}=.*|${key}=${val}|" .env && rm -f .env.bak
    fi
  done < .env.example
  echo "  -> .env created. Review it; admin login is in KEYCLOAK_ADMIN_PASSWORD."
else
  echo ".env already exists — leaving it untouched."
fi

# 2. Render the realm file from the template using .env values.
echo "Rendering keycloak/realm-export.json from template..."
set -a; source .env; set +a
envsubst '${OPENWEBUI_CLIENT_SECRET} ${LLMCLI_CLIENT_SECRET} ${DEMO_USER_PASSWORD}' \
  < keycloak/realm-export.template.json > keycloak/realm-export.json
echo "  -> keycloak/realm-export.json written."

echo
echo "Setup complete. Next:"
echo "  1. Add '127.0.0.1  keycloak' to /etc/hosts   (one line, once)"
echo "  2. docker compose up -d --build"
echo "  3. docker compose exec ollama ollama pull llama3.2:3b"
echo "  4. Open http://localhost:3000  and sign in with Keycloak (user: demo)"
