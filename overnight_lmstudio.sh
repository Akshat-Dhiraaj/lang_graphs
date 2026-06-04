#!/usr/bin/env bash
# =============================================================================
# overnight_lmstudio.sh
# Unattended: provision an LM Studio model (load + tune), sanity-check tool
# calling, then run the Pocket Agent build against it. Safe to leave overnight.
#
#   bash overnight_lmstudio.sh
#
# Config (env overrides):
#   POCKET_MODEL          LM Studio model key   (default: qwen/qwen3.5-9b)
#   POCKET_CTX            context length        (default: 8192)
#   POCKET_GPU            GPU offload ratio      (default: max)   off|max|0..1
#   POCKET_LMSTUDIO_URL   OpenAI-compat base    (default: http://localhost:1234/v1)
#   POCKET_VERIFY_TIMEOUT seconds for verify    (default: 3600)
#
# Chosen default rationale (RTX 4060 = 8GB VRAM, 32GB RAM):
#   qwen/qwen3.5-9b fits VRAM (~6.1GB) with full GPU offload -> fast + stable,
#   and Qwen has top-tier tool-calling (the build's #1 success factor).
#   To try a bigger one in the morning, e.g.:
#     POCKET_MODEL=google/gemma-4-26b-a4b POCKET_GPU=0.6 bash overnight_lmstudio.sh
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
MODEL="${POCKET_MODEL:-qwen/qwen3.5-9b}"
CTX="${POCKET_CTX:-8192}"
GPU="${POCKET_GPU:-max}"
URL="${POCKET_LMSTUDIO_URL:-http://localhost:1234/v1}"

LMS="$HOME/.lmstudio/bin/lms"
command -v lms >/dev/null 2>&1 && LMS="$(command -v lms)"

LOG_DIR="$SCRIPT_DIR/pocket-agent/logs"; mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/overnight_lmstudio_$(date +%Y%m%d_%H%M%S).log"
say(){ printf '%s | %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$LOG"; }

say "================ Pocket Agent overnight (LM Studio) ================"
say "model=$MODEL  ctx=$CTX  gpu=$GPU  url=$URL"
say "lms=$LMS"
say "log=$LOG"

# ---- hardware snapshot (best-effort, no PowerShell quoting headaches) -------
say "---- hardware ----"
if command -v nvidia-smi >/dev/null 2>&1; then
  nvidia-smi --query-gpu=name,memory.total,memory.free,driver_version \
             --format=csv,noheader 2>/dev/null | while read -r l; do say "GPU: $l"; done
fi
MEM="$(awk '/MemTotal/{printf "%.1f GB",$2/1024/1024}' /proc/meminfo 2>/dev/null)"
say "CPU cores=$(nproc 2>/dev/null || echo '?')  RAM=${MEM:-?}"

# ---- ensure lms + server + model -------------------------------------------
[ -x "$LMS" ] || { say "FATAL: lms CLI not found at $LMS"; exit 1; }
say "---- ensuring LM Studio server ----"
"$LMS" server start >>"$LOG" 2>&1 || say "server start returned nonzero (likely already running)"

say "---- loading model (idempotent) ----"
if "$LMS" ps 2>/dev/null | grep -q "$MODEL"; then
  say "model already loaded"
else
  if "$LMS" load "$MODEL" --gpu "$GPU" -c "$CTX" -y >>"$LOG" 2>&1; then
    say "model loaded"
  else
    say "FATAL: lms load failed for $MODEL (is it downloaded? run: lms get \"$MODEL\" -y)"
    exit 1
  fi
fi
"$LMS" ps 2>&1 | tee -a "$LOG"

# ---- tool-calling sanity check (no python deps) ----------------------------
say "---- tool-calling sanity check ----"
python - "$MODEL" "$URL" <<'PY' 2>&1 | tee -a "$LOG"
import sys, json, urllib.request
model, url = sys.argv[1], sys.argv[2].rstrip("/")
payload = {"model": model, "temperature": 0, "tool_choice": "auto",
  "messages": [{"role": "user",
                "content": "What is 918273 * 6457? Use the calculator tool."}],
  "tools": [{"type": "function", "function": {"name": "calculator",
    "description": "Evaluate a basic arithmetic expression",
    "parameters": {"type": "object",
                   "properties": {"expression": {"type": "string"}},
                   "required": ["expression"]}}}]}
try:
    req = urllib.request.Request(url + "/chat/completions",
        data=json.dumps(payload).encode(), headers={"Content-Type": "application/json"})
    r = json.load(urllib.request.urlopen(req, timeout=120))
    tc = r["choices"][0]["message"].get("tool_calls")
    print("SANITY: tool-calling OK -> " + tc[0]["function"]["name"] if tc
          else "SANITY: NO TOOL CALL (M3/M5 may fail with this model)")
except Exception as e:
    print("SANITY: check failed:", e)
PY

# ---- run the Pocket Agent build, pointed at LM Studio ----------------------
say "---- launching build_pocket_agent.sh against LM Studio ----"
export POCKET_USE_LMSTUDIO=1
export POCKET_LMSTUDIO_URL="$URL"
export POCKET_MODEL="$MODEL"
export POCKET_VERIFY_TIMEOUT="${POCKET_VERIFY_TIMEOUT:-3600}"
unset POCKET_FORCE_MOCK
bash "$SCRIPT_DIR/build_pocket_agent.sh" 2>&1 | tee -a "$LOG"
rc=${PIPESTATUS[0]}

say "================ DONE (build exit=$rc) ================"
say "report : $SCRIPT_DIR/pocket-agent/BUILD_REPORT.md"
say "log    : $LOG"
say "model still loaded in LM Studio: $MODEL (run 'lms unload --all' to free VRAM)"
exit "$rc"
