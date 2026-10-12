#!/usr/bin/env bash
set -euo pipefail
STACK=~/dev/ai-dev/llm-openai-stack
cd "$STACK"
set -a; source .env; set +a
TS=$(date +%Y%m%d-%H%M%S)
KC=http://keycloak:8080

echo "== 1/5 Switching llama.cpp to Qwen2.5-Coder-3B on port 8080 =="
cp docker-compose.override.yml "docker-compose.override.yml.bak-$TS"
python3 - <<'EOF'
import yaml
p = "docker-compose.override.yml"
d = yaml.safe_load(open(p))
cmd = d["services"]["llamacpp"]["command"]
cmd[cmd.index("-hf") + 1] = "bartowski/Qwen2.5-Coder-3B-Instruct-GGUF:Q4_K_M"
cmd[cmd.index("--port") + 1] = "8080"
yaml.safe_dump(d, open(p, "w"), sort_keys=False)
print("override updated")
EOF

echo "== 2/5 Updating LiteLLM config =="
cp litellm/config.yaml "litellm/config.yaml.bak-$TS"
python3 - <<'EOF'
p = "litellm/config.yaml"
s = open(p).read()
s = s.replace("model_name: llama3.2-cpp", "model_name: qwen-coder")
s = s.replace("# same model, served by llama.cpp", "# Qwen2.5-Coder, served by llama.cpp")
s = s.replace("model: openai/llama3.2\n", "model: openai/qwen-coder\n")
s = s.replace("http://llamacpp:8081/v1", "http://llamacpp:8080/v1")
open(p, "w").write(s)
import yaml; yaml.safe_load(open(p))
assert "qwen-coder" in s and "llamacpp:8080" in s, "config.yaml not in expected format"
print("config.yaml updated and valid")
EOF

sudo docker compose up -d llamacpp
echo "Downloading/loading model (first time ~2 GB, can take several minutes)..."
ok=0
for i in $(seq 1 180); do
  if sudo docker compose logs llamacpp 2>/dev/null | grep -q "listening on http://0.0.0.0:8080"; then ok=1; break; fi
  sleep 5
done
[ "$ok" = 1 ] || { echo "llama.cpp did not start in 15 min. Check: sudo docker compose logs --tail 40 llamacpp"; exit 1; }
sudo docker compose restart litellm
sleep 20

echo "== 3/5 Setting llm-cli token lifespan to 8 hours in Keycloak =="
ADMIN_TOKEN=$(curl -s $KC/realms/master/protocol/openid-connect/token \
  -d grant_type=password -d client_id=admin-cli \
  -d username="$KEYCLOAK_ADMIN" -d password="$KEYCLOAK_ADMIN_PASSWORD" | jq -r .access_token)
CID=$(curl -s -H "Authorization: Bearer $ADMIN_TOKEN" "$KC/admin/realms/llmdemo/clients?clientId=llm-cli" | jq -r '.[0].id')
curl -s -H "Authorization: Bearer $ADMIN_TOKEN" "$KC/admin/realms/llmdemo/clients/$CID" \
  | jq '.attributes["access.token.lifespan"]="28800"' > /tmp/llmcli.json
CODE=$(curl -s -o /dev/null -w "%{http_code}" -X PUT -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" --data @/tmp/llmcli.json "$KC/admin/realms/llmdemo/clients/$CID")
rm -f /tmp/llmcli.json
[ "$CODE" = 204 ] && echo "token lifespan set" || echo "WARNING: Keycloak update returned $CODE (tokens stay at 5 min; refresh job still works)"

echo "== 4/5 Installing token refresh script =="
mkdir -p ~/bin ~/.continue
cat > ~/bin/llm-token-refresh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
set -a; source ~/dev/ai-dev/llm-openai-stack/.env; set +a
TOKEN=$(curl -s http://keycloak:8080/realms/llmdemo/protocol/openid-connect/token \
  -d grant_type=client_credentials -d client_id=llm-cli \
  -d client_secret="$LLMCLI_CLIENT_SECRET" | jq -r .access_token)
[ -n "$TOKEN" ] && [ "$TOKEN" != null ] || { echo "token fetch failed"; exit 1; }
sed -i "s|^\(\s*apiKey:\).*|\1 $TOKEN|" ~/.continue/config.yaml
echo "$(date): token refreshed"
EOF
chmod +x ~/bin/llm-token-refresh
( crontab -l 2>/dev/null | grep -v llm-token-refresh || true
  echo "0 */4 * * * $HOME/bin/llm-token-refresh >> $HOME/.continue/token-refresh.log 2>&1"
  echo "@reboot sleep 90 && $HOME/bin/llm-token-refresh >> $HOME/.continue/token-refresh.log 2>&1"
) | crontab -

echo "== 5/5 Configuring VS Code + Continue =="
[ -f ~/.continue/config.yaml ] && cp ~/.continue/config.yaml ~/.continue/config.yaml.bak-$TS
cat > ~/.continue/config.yaml <<'EOF'
name: Local Assistant
version: 1.0.0
schema: v1
models:
  - name: Qwen Coder (local)
    provider: openai
    model: qwen-coder
    apiBase: http://localhost:4001/v1
    apiKey: PLACEHOLDER
    roles:
      - chat
      - edit
      - apply
EOF
chmod 600 ~/.continue/config.yaml
~/bin/llm-token-refresh
if command -v code >/dev/null; then
  code --install-extension Continue.continue --force
else
  echo "VS Code 'code' command not found - install the Continue extension from the Extensions panel."
fi

echo "== Testing qwen-coder end to end =="
TOKEN=$(grep apiKey ~/.continue/config.yaml | awk '{print $2}')
curl -s http://localhost:4001/v1/chat/completions \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"model":"qwen-coder","messages":[{"role":"user","content":"Write a Python function that reverses a string. Code only."}]}' \
  | jq -r '.choices[0].message.content // .'
echo; echo "Done. Backups saved with suffix .bak-$TS"
