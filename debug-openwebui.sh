#!/usr/bin/env bash
set -e
cd ~/dev/ai-dev/llm-openai-stack
cp docker-compose.override.yml docker-compose.override.yml.debugbak

# 1. Turn on LiteLLM debug logging (prints the full request Open WebUI sends)
python3 - <<'EOF'
import yaml
p = "docker-compose.override.yml"
d = yaml.safe_load(open(p))
d["services"].setdefault("litellm", {}).setdefault("environment", {})["LITELLM_LOG"] = "DEBUG"
yaml.safe_dump(d, open(p, "w"), sort_keys=False)
EOF
sudo docker compose up -d litellm
echo "Waiting 25s for LiteLLM to restart..."; sleep 25

# 2. You send a test message
echo
read -p ">>> Open a NEW chat in Open WebUI, pick llama3.2-cpp, send 'hi', wait for the reply, then press Enter here... "

# 3. Capture and summarize
sudo docker compose logs --since 10m litellm > ~/litellm-debug.log 2>&1
echo; echo "===== SUMMARY ====="
echo "Longest log line (chars): $(awk '{ if (length>m) m=length } END {print m+0}' ~/litellm-debug.log)"
echo "Lines mentioning tools: $(grep -cE "\"tools\"|'tools'" ~/litellm-debug.log || true)"
echo "Lines mentioning memory/context/knowledge: $(grep -ciE 'memory|<context>|knowledge|source_id' ~/litellm-debug.log || true)"
echo; echo "===== SYSTEM MESSAGE (first 2500 chars) ====="
grep -m1 -E "role.{0,4}system" ~/litellm-debug.log | cut -c1-2500 || echo "(no system message found)"
echo; echo "===== llama.cpp prompt size for this request ====="
sudo docker compose logs --since 10m llamacpp | grep "prompt eval" | tail -2

# 4. Undo the debug setting
mv docker-compose.override.yml.debugbak docker-compose.override.yml
sudo docker compose up -d litellm
echo; echo "Debug logging turned off again. Full log saved at ~/litellm-debug.log"
