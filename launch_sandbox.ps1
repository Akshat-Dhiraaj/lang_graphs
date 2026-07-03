param(
    [int]$Port = 8765,
    [switch]$NoBrowser,
    [switch]$Foreground,
    [switch]$Stop
)

$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$BuildTmp = Join-Path $Root "pocket-agent\.build_tmp"
$LogDir = Join-Path $Root "pocket-agent\logs"
$ServerPath = Join-Path $BuildTmp "sandbox_server.py"
$PidFile = Join-Path $BuildTmp "sandbox_server.pid"
$Url = "http://127.0.0.1:$Port"

New-Item -ItemType Directory -Force -Path $BuildTmp, $LogDir | Out-Null

function Test-LocalPort {
    param([int]$TestPort)
    $client = $null
    try {
        $client = [System.Net.Sockets.TcpClient]::new()
        $iar = $client.BeginConnect("127.0.0.1", $TestPort, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne(250)) {
            return $false
        }
        $client.EndConnect($iar)
        return $true
    } catch {
        return $false
    } finally {
        if ($client) {
            $client.Dispose()
        }
    }
}

function Test-SandboxEndpoint {
    try {
        $resp = Invoke-WebRequest -Uri "$Url/api/status" -UseBasicParsing -TimeoutSec 1
        return ($resp.Content -like "*Pocket*" -or $resp.Content -like "*lmstudio*") -and ($resp.Content -like "*git*")
    } catch {
        return $false
    }
}

function Stop-Sandbox {
    if (-not (Test-Path $PidFile)) {
        Write-Host "No sandbox PID file found."
        return
    }
    $rawPid = (Get-Content -Path $PidFile -Raw).Trim()
    if (-not $rawPid) {
        Remove-Item -Path $PidFile -Force -ErrorAction SilentlyContinue
        Write-Host "Sandbox PID file was empty; removed it."
        return
    }
    $proc = Get-Process -Id ([int]$rawPid) -ErrorAction SilentlyContinue
    if ($proc) {
        Stop-Process -Id $proc.Id -Force
        Write-Host "Stopped sandbox server PID $($proc.Id)."
    } else {
        Write-Host "Sandbox server PID $rawPid was not running."
    }
    Remove-Item -Path $PidFile -Force -ErrorAction SilentlyContinue
}

if ($Stop) {
    Stop-Sandbox
    return
}

if (Test-LocalPort -TestPort $Port) {
    if (Test-SandboxEndpoint) {
        Write-Host "Sandbox already appears to be running at $Url"
        if (-not $NoBrowser) {
            Start-Process $Url
        }
        return
    }
    throw "Port $Port is already in use by another service. Retry with -Port <free-port>."
}

$Python = Join-Path $Root "pocket-agent\.venv\Scripts\python.exe"
$PythonArgs = @()
if (-not (Test-Path $Python)) {
    $pyLauncher = Get-Command py -ErrorAction SilentlyContinue
    if ($pyLauncher) {
        $Python = $pyLauncher.Source
        $PythonArgs = @("-3")
    } else {
        $pythonCmd = Get-Command python -ErrorAction SilentlyContinue
        if (-not $pythonCmd) {
            throw "Python was not found. Run .\build.cmd once, or install Python 3.10+."
        }
        $Python = $pythonCmd.Source
    }
}

$ServerCode = @'
import json
import os
import subprocess
import sys
import threading
import urllib.error
import urllib.parse
import urllib.request
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


ROOT = Path(os.environ["POCKET_SANDBOX_ROOT"]).resolve()
PORT = int(os.environ.get("POCKET_SANDBOX_PORT", "8765"))
LMSTUDIO_BASE = os.environ.get("POCKET_LMSTUDIO_URL", "http://localhost:1234/v1").rstrip("/")
TIMEOUT = 90
MAX_PROMPT_CHARS = 12000


HTML = r"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Pocket Agent Sandbox</title>
  <style>
    :root {
      color-scheme: light;
      --bg: #f5f7f9;
      --panel: #ffffff;
      --ink: #18212f;
      --muted: #5d697a;
      --line: #d7dee8;
      --blue: #2563eb;
      --green: #16794c;
      --amber: #a15c07;
      --red: #b42318;
      --shadow: 0 8px 24px rgba(24, 33, 47, 0.08);
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      background: var(--bg);
      color: var(--ink);
      font: 14px/1.45 system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    }
    header {
      border-bottom: 1px solid var(--line);
      background: #ffffff;
    }
    .wrap {
      max-width: 1180px;
      margin: 0 auto;
      padding: 18px;
    }
    .topbar {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 16px;
      flex-wrap: wrap;
    }
    h1 {
      margin: 0;
      font-size: 24px;
      line-height: 1.15;
      letter-spacing: 0;
    }
    h2 {
      margin: 0 0 10px;
      font-size: 16px;
      letter-spacing: 0;
    }
    h3 {
      margin: 0 0 8px;
      font-size: 14px;
      letter-spacing: 0;
    }
    p { margin: 0 0 10px; }
    a { color: var(--blue); }
    .sub {
      color: var(--muted);
      margin-top: 4px;
      max-width: 760px;
    }
    .grid {
      display: grid;
      grid-template-columns: minmax(0, 0.9fr) minmax(380px, 1.35fr);
      gap: 16px;
      align-items: start;
    }
    .panel {
      background: var(--panel);
      border: 1px solid var(--line);
      border-radius: 8px;
      box-shadow: var(--shadow);
      padding: 16px;
    }
    .stack { display: grid; gap: 16px; }
    .status {
      display: flex;
      flex-wrap: wrap;
      gap: 8px;
      margin-top: 14px;
    }
    .pill {
      border: 1px solid var(--line);
      border-radius: 999px;
      padding: 5px 9px;
      background: #fff;
      color: var(--muted);
      white-space: nowrap;
      font-size: 12px;
    }
    .pill.good { color: var(--green); border-color: #b7e2ce; background: #f0fbf6; }
    .pill.warn { color: var(--amber); border-color: #f3d49d; background: #fff8ea; }
    .pill.bad { color: var(--red); border-color: #f3b4ae; background: #fff4f2; }
    ul.clean {
      margin: 0;
      padding-left: 18px;
      display: grid;
      gap: 6px;
    }
    .capabilities {
      display: grid;
      grid-template-columns: repeat(2, minmax(0, 1fr));
      gap: 10px;
    }
    .cap {
      border: 1px solid var(--line);
      border-radius: 8px;
      padding: 10px;
      background: #fbfcfe;
      min-height: 86px;
    }
    .cap strong { display: block; margin-bottom: 4px; }
    .cap span { color: var(--muted); font-size: 13px; }
    label {
      display: block;
      font-weight: 650;
      margin-bottom: 6px;
    }
    input, select, textarea {
      width: 100%;
      border: 1px solid var(--line);
      border-radius: 7px;
      padding: 9px 10px;
      background: #fff;
      color: var(--ink);
      font: inherit;
    }
    textarea {
      resize: vertical;
      min-height: 136px;
    }
    input:focus, select:focus, textarea:focus {
      outline: 2px solid rgba(37, 99, 235, 0.18);
      border-color: var(--blue);
    }
    .form-grid {
      display: grid;
      grid-template-columns: repeat(2, minmax(0, 1fr));
      gap: 12px;
    }
    .full { grid-column: 1 / -1; }
    .buttons {
      display: flex;
      flex-wrap: wrap;
      gap: 8px;
      align-items: center;
    }
    button {
      border: 1px solid #1d4ed8;
      border-radius: 7px;
      background: var(--blue);
      color: #fff;
      font-weight: 700;
      padding: 9px 12px;
      cursor: pointer;
      min-height: 38px;
    }
    button.secondary {
      color: var(--ink);
      background: #ffffff;
      border-color: var(--line);
    }
    button:disabled {
      opacity: 0.55;
      cursor: not-allowed;
    }
    .hint {
      color: var(--muted);
      font-size: 12px;
      margin-top: 5px;
    }
    .output {
      white-space: pre-wrap;
      border: 1px solid var(--line);
      border-radius: 8px;
      min-height: 180px;
      padding: 12px;
      background: #111827;
      color: #f9fafb;
      overflow-wrap: anywhere;
    }
    .meta {
      color: var(--muted);
      font-size: 12px;
      margin-top: 8px;
    }
    .examples {
      display: flex;
      flex-wrap: wrap;
      gap: 8px;
      margin: 8px 0 12px;
    }
    .examples button {
      min-height: 30px;
      padding: 6px 8px;
      font-size: 12px;
    }
    footer {
      color: var(--muted);
      font-size: 12px;
      padding-bottom: 22px;
    }
    @media (max-width: 900px) {
      .grid { grid-template-columns: 1fr; }
      .form-grid { grid-template-columns: 1fr; }
      .capabilities { grid-template-columns: 1fr; }
    }
  </style>
</head>
<body>
  <header>
    <div class="wrap">
      <div class="topbar">
        <div>
          <h1>Pocket Agent Sandbox</h1>
          <p class="sub">A local-first LangGraph learning project that demonstrates the agent loop, tools, memory, streaming, human approval, server mode, semantic search, and persistence without requiring paid APIs.</p>
        </div>
        <button class="secondary" id="refreshStatus" title="Refresh local status">Refresh</button>
      </div>
      <div id="status" class="status">
        <span class="pill">Loading local status...</span>
      </div>
    </div>
  </header>

  <main class="wrap grid">
    <section class="stack">
      <div class="panel">
        <h2>Objective</h2>
        <p>Pocket Agent is a compact, self-verified LangGraph foundations repo. Its goal is understanding the primitives: state, nodes, edges, the ReAct cycle, persistence, memory, streaming, human-in-the-loop, and the high-level create_agent path.</p>
        <ul class="clean">
          <li>Runs keyless in deterministic mock mode.</li>
          <li>Runs locally through LM Studio when its OpenAI-compatible server is up.</li>
          <li>Can also use provider keys for cloud model experiments.</li>
        </ul>
      </div>

      <div class="panel">
        <h2>What You Can Do</h2>
        <div class="capabilities">
          <div class="cap"><strong>Tool cycle</strong><span>Ask arithmetic or note questions and watch the agent call tools before answering.</span></div>
          <div class="cap"><strong>Memory</strong><span>SQLite checkpoints preserve multi-turn state by thread id.</span></div>
          <div class="cap"><strong>HITL</strong><span>The CLI and server graph can pause before saving notes and resume from a human decision.</span></div>
          <div class="cap"><strong>Streaming</strong><span>v3 event streaming plus a fallback path are verified.</span></div>
          <div class="cap"><strong>Server/Studio</strong><span>langgraph.json exposes plain and HITL graphs for langgraph dev and SDK calls.</span></div>
          <div class="cap"><strong>Depth demos</strong><span>Semantic store search, DeltaChannel, Postgres helpers, node caching, and stream projection are included.</span></div>
        </div>
      </div>
    </section>

    <section class="panel">
      <h2>Sandbox</h2>
      <p class="hint">API keys are sent only to this localhost server for the current request. This launcher does not write them to disk.</p>

      <div class="examples">
        <button class="secondary example" data-prompt="What can this project demonstrate in five bullets?">Project summary</button>
        <button class="secondary example" data-prompt="Use the calculator tool to compute 1234 * 5678.">Tool probe</button>
        <button class="secondary example" data-prompt="Explain LangGraph persistence in one short paragraph.">Persistence</button>
      </div>

      <div class="form-grid">
        <div>
          <label for="mode">Run Mode</label>
          <select id="mode">
            <option value="agent">Pocket Agent graph</option>
            <option value="provider">Direct provider chat</option>
          </select>
          <div class="hint">Agent mode uses this repo's graph. Provider mode calls the selected API directly.</div>
        </div>
        <div>
          <label for="provider">Provider</label>
          <select id="provider">
            <option value="lmstudio">LM Studio local</option>
            <option value="openai">OpenAI / GPT</option>
            <option value="anthropic">Anthropic / Claude</option>
            <option value="gemini">Google Gemini</option>
            <option value="custom-openai">Other OpenAI-compatible</option>
          </select>
        </div>
        <div>
          <label for="baseUrl">Base URL</label>
          <input id="baseUrl" value="http://localhost:1234/v1">
          <div class="hint">Used for LM Studio and other OpenAI-compatible servers.</div>
        </div>
        <div>
          <label for="model">Model</label>
          <input id="model" placeholder="Auto for LM Studio; otherwise enter provider model">
        </div>
        <div class="full">
          <label for="apiKey">API Key</label>
          <input id="apiKey" type="password" autocomplete="off" placeholder="Not needed for LM Studio">
        </div>
        <div class="full">
          <label for="prompt">Prompt</label>
          <textarea id="prompt">What can this project demonstrate in five bullets?</textarea>
        </div>
      </div>

      <div class="buttons" style="margin-top: 12px;">
        <button id="send">Run</button>
        <button class="secondary" id="clear">Clear</button>
      </div>

      <h3 style="margin-top: 16px;">Result</h3>
      <div id="output" class="output">Ready.</div>
      <div id="meta" class="meta"></div>
    </section>
  </main>

  <footer class="wrap">
    Provider wiring was checked against LM Studio OpenAI-compatible tool docs, OpenAI Chat Completions API reference, Anthropic Messages/versioning docs, and Google Gemini generateContent/API-key docs. Links are recorded in docs/project/sandbox_launcher.md.
  </footer>

  <script>
    const $ = (id) => document.getElementById(id);

    function pill(text, kind) {
      const s = document.createElement("span");
      s.className = "pill" + (kind ? " " + kind : "");
      s.textContent = text;
      return s;
    }

    async function refreshStatus() {
      const status = $("status");
      status.innerHTML = "";
      status.appendChild(pill("Checking...", ""));
      try {
        const res = await fetch("/api/status");
        const data = await res.json();
        status.innerHTML = "";
        status.appendChild(pill(data.git.clean ? "Git clean" : "Git has changes", data.git.clean ? "good" : "warn"));
        status.appendChild(pill(data.build.result || "No build report", data.build.ok ? "good" : "warn"));
        status.appendChild(pill(data.lmstudio.up ? "LM Studio up" : "LM Studio offline", data.lmstudio.up ? "good" : "warn"));
        if (data.lmstudio.model) status.appendChild(pill("Model: " + data.lmstudio.model, "good"));
        if (data.python) status.appendChild(pill("Python: " + data.python, ""));
        if (data.lmstudio.model && !$("model").value.trim() && $("provider").value === "lmstudio") {
          $("model").value = data.lmstudio.model;
        }
      } catch (err) {
        status.innerHTML = "";
        status.appendChild(pill("Status failed: " + err.message, "bad"));
      }
    }

    function syncProviderFields() {
      const provider = $("provider").value;
      const needsKey = provider !== "lmstudio";
      $("apiKey").disabled = !needsKey;
      $("apiKey").placeholder = needsKey ? "Paste key for this request only" : "Not needed for LM Studio";
      $("baseUrl").disabled = !(provider === "lmstudio" || provider === "custom-openai");
      if (provider === "openai" && !$("model").value.trim()) $("model").value = "";
      if (provider === "anthropic" && !$("model").value.trim()) $("model").value = "";
      if (provider === "gemini" && !$("model").value.trim()) $("model").value = "";
    }

    async function runSandbox() {
      const send = $("send");
      const output = $("output");
      const meta = $("meta");
      const prompt = $("prompt").value.trim();
      if (!prompt) {
        output.textContent = "Enter a prompt first.";
        return;
      }
      send.disabled = true;
      output.textContent = "Running...";
      meta.textContent = "";
      const body = {
        mode: $("mode").value,
        provider: $("provider").value,
        baseUrl: $("baseUrl").value.trim(),
        model: $("model").value.trim(),
        apiKey: $("apiKey").value,
        prompt
      };
      try {
        const endpoint = body.mode === "agent" ? "/api/agent" : "/api/chat";
        const res = await fetch(endpoint, {
          method: "POST",
          headers: {"Content-Type": "application/json"},
          body: JSON.stringify(body)
        });
        const data = await res.json();
        if (!res.ok || data.error) throw new Error(data.error || "Request failed");
        output.textContent = data.text || "(empty response)";
        meta.textContent = [
          data.provider ? "provider=" + data.provider : "",
          data.model ? "model=" + data.model : "",
          data.mode ? "mode=" + data.mode : "",
          data.thread_id ? "thread=" + data.thread_id : ""
        ].filter(Boolean).join(" | ");
      } catch (err) {
        output.textContent = err.message;
        meta.textContent = "Request failed.";
      } finally {
        send.disabled = false;
      }
    }

    $("refreshStatus").addEventListener("click", refreshStatus);
    $("provider").addEventListener("change", syncProviderFields);
    $("send").addEventListener("click", runSandbox);
    $("clear").addEventListener("click", () => {
      $("output").textContent = "Ready.";
      $("meta").textContent = "";
    });
    document.querySelectorAll(".example").forEach((btn) => {
      btn.addEventListener("click", () => { $("prompt").value = btn.dataset.prompt; });
    });

    syncProviderFields();
    refreshStatus();
  </script>
</body>
</html>
"""


def json_response(handler, payload, status=200):
    data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    handler.send_response(status)
    handler.send_header("Content-Type", "application/json; charset=utf-8")
    handler.send_header("Content-Length", str(len(data)))
    handler.end_headers()
    handler.wfile.write(data)


def html_response(handler):
    data = HTML.encode("utf-8")
    handler.send_response(200)
    handler.send_header("Content-Type", "text/html; charset=utf-8")
    handler.send_header("Content-Length", str(len(data)))
    handler.end_headers()
    handler.wfile.write(data)


def read_body(handler):
    length = int(handler.headers.get("Content-Length", "0"))
    if length > 200000:
        raise ValueError("Request body is too large")
    raw = handler.rfile.read(length).decode("utf-8")
    return json.loads(raw or "{}")


def http_json(url, payload=None, headers=None, timeout=TIMEOUT):
    data = None if payload is None else json.dumps(payload).encode("utf-8")
    method = "GET" if data is None else "POST"
    req = urllib.request.Request(url, data=data, method=method)
    for key, value in (headers or {}).items():
        req.add_header(key, value)
    if data is not None and "Content-Type" not in (headers or {}):
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            body = resp.read().decode("utf-8", errors="replace")
            return json.loads(body or "{}")
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"HTTP {exc.code}: {body[:1800]}") from exc
    except urllib.error.URLError as exc:
        raise RuntimeError(str(exc.reason)) from exc


def first_lmstudio_model(base_url):
    try:
        data = http_json(base_url.rstrip("/") + "/models", timeout=3)
    except Exception:
        return ""
    for item in data.get("data", []):
        model_id = str(item.get("id", ""))
        if model_id and "embed" not in model_id.lower():
            return model_id
    return ""


def openai_compat_chat(base_url, model, messages, api_key=None):
    headers = {"Content-Type": "application/json"}
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"
    payload = {
        "model": model,
        "messages": messages,
        "temperature": 0.2,
        "max_tokens": 900,
    }
    data = http_json(base_url.rstrip("/") + "/chat/completions", payload, headers)
    choices = data.get("choices") or []
    if not choices:
        return "", data
    message = choices[0].get("message") or {}
    content = message.get("content")
    if isinstance(content, list):
        text = "\n".join(str(part.get("text", "")) for part in content if isinstance(part, dict))
    else:
        text = str(content or "")
    return text, data


def anthropic_chat(model, prompt, api_key):
    payload = {
        "model": model,
        "max_tokens": 900,
        "messages": [{"role": "user", "content": prompt}],
    }
    headers = {
        "Content-Type": "application/json",
        "x-api-key": api_key,
        "anthropic-version": "2023-06-01",
    }
    data = http_json("https://api.anthropic.com/v1/messages", payload, headers)
    parts = []
    for part in data.get("content", []):
        if isinstance(part, dict) and part.get("type") == "text":
            parts.append(part.get("text", ""))
    return "\n".join(parts), data


def gemini_chat(model, prompt, api_key):
    safe_model = urllib.parse.quote(model, safe="-_.~/")
    url = f"https://generativelanguage.googleapis.com/v1beta/models/{safe_model}:generateContent"
    payload = {"contents": [{"parts": [{"text": prompt}]}]}
    headers = {
        "Content-Type": "application/json",
        "x-goog-api-key": api_key,
    }
    data = http_json(url, payload, headers)
    parts = []
    for candidate in data.get("candidates", []):
        content = candidate.get("content", {})
        for part in content.get("parts", []):
            if "text" in part:
                parts.append(part["text"])
    return "\n".join(parts), data


def chat(payload):
    provider = str(payload.get("provider") or "lmstudio").strip()
    prompt = str(payload.get("prompt") or "").strip()
    model = str(payload.get("model") or "").strip()
    api_key = str(payload.get("apiKey") or "").strip()
    base_url = str(payload.get("baseUrl") or "").strip()
    if not prompt:
        raise ValueError("Prompt is required")
    if len(prompt) > MAX_PROMPT_CHARS:
        raise ValueError(f"Prompt is too long; keep it under {MAX_PROMPT_CHARS} characters")

    messages = [
        {"role": "system", "content": "You are Pocket Agent Sandbox. Be concise and practical."},
        {"role": "user", "content": prompt},
    ]

    if provider == "lmstudio":
        base = (base_url or LMSTUDIO_BASE).rstrip("/")
        selected = model or first_lmstudio_model(base) or os.environ.get("POCKET_MODEL", "local-model")
        text, _raw = openai_compat_chat(base, selected, messages, api_key or "lm-studio")
        return {"provider": "lmstudio", "model": selected, "text": text}
    if provider == "custom-openai":
        if not base_url:
            raise ValueError("Base URL is required for an OpenAI-compatible provider")
        if not model:
            raise ValueError("Model is required for this provider")
        text, _raw = openai_compat_chat(base_url, model, messages, api_key or None)
        return {"provider": "custom-openai", "model": model, "text": text}
    if provider == "openai":
        if not api_key:
            raise ValueError("OpenAI API key is required")
        if not model:
            raise ValueError("Enter an OpenAI model id")
        text, _raw = openai_compat_chat("https://api.openai.com/v1", model, messages, api_key)
        return {"provider": "openai", "model": model, "text": text}
    if provider == "anthropic":
        if not api_key:
            raise ValueError("Anthropic API key is required")
        if not model:
            raise ValueError("Enter a Claude model id")
        text, _raw = anthropic_chat(model, prompt, api_key)
        return {"provider": "anthropic", "model": model, "text": text}
    if provider == "gemini":
        if not api_key:
            raise ValueError("Gemini API key is required")
        if not model:
            raise ValueError("Enter a Gemini model id")
        text, _raw = gemini_chat(model, prompt, api_key)
        return {"provider": "gemini", "model": model, "text": text}
    raise ValueError(f"Unknown provider: {provider}")


_agent_lock = threading.Lock()
_agent_graph = None
_agent_mode = None


def run_agent(payload):
    global _agent_graph, _agent_mode
    prompt = str(payload.get("prompt") or "").strip()
    if not prompt:
        raise ValueError("Prompt is required")
    if len(prompt) > MAX_PROMPT_CHARS:
        raise ValueError(f"Prompt is too long; keep it under {MAX_PROMPT_CHARS} characters")

    with _agent_lock:
        if _agent_graph is None:
            os.environ.setdefault("POCKET_NOTES_PATH", str(ROOT / "pocket-agent" / ".build_tmp" / "sandbox_notes.json"))
            package_root = str(ROOT / "pocket-agent")
            if package_root not in sys.path:
                sys.path.insert(0, package_root)
            from langgraph.checkpoint.memory import MemorySaver
            from pocket_agent.graph import build_graph
            _agent_graph, _agent_mode = build_graph(checkpointer=MemorySaver(), hitl=False)

    thread_id = str(payload.get("threadId") or "sandbox-" + uuid.uuid4().hex[:8])
    cfg = {"configurable": {"thread_id": thread_id}}
    result = _agent_graph.invoke({"messages": [{"role": "user", "content": prompt}]}, cfg)
    messages = result.get("messages", [])
    text = str(getattr(messages[-1], "content", "")) if messages else ""
    return {"mode": _agent_mode, "provider": "pocket-agent", "model": os.environ.get("POCKET_MODEL", ""), "thread_id": thread_id, "text": text}


def git_status():
    try:
        proc = subprocess.run(
            ["git", "status", "--short", "--branch"],
            cwd=str(ROOT),
            text=True,
            capture_output=True,
            timeout=5,
        )
        lines = [line for line in proc.stdout.splitlines() if line.strip()]
        clean = len(lines) <= 1 and proc.returncode == 0
        return {"clean": clean, "text": proc.stdout.strip()}
    except Exception as exc:
        return {"clean": False, "text": str(exc)}


def build_report():
    path = ROOT / "pocket-agent" / "BUILD_REPORT.md"
    if not path.exists():
        return {"ok": False, "result": ""}
    result = ""
    try:
        for line in path.read_text(encoding="utf-8").splitlines():
            if line.startswith("- Result:"):
                result = line.replace("- Result:", "").strip().replace("**", "")
                break
        return {"ok": "0 failed" in result, "result": result}
    except Exception as exc:
        return {"ok": False, "result": str(exc)}


def lmstudio_status():
    try:
        model = first_lmstudio_model(LMSTUDIO_BASE)
        return {"up": bool(model), "base_url": LMSTUDIO_BASE, "model": model}
    except Exception:
        return {"up": False, "base_url": LMSTUDIO_BASE, "model": ""}


def status():
    return {
        "root": str(ROOT),
        "python": sys.version.split()[0],
        "git": git_status(),
        "build": build_report(),
        "lmstudio": lmstudio_status(),
    }


class Handler(BaseHTTPRequestHandler):
    server_version = "PocketAgentSandbox/1.0"

    def log_message(self, fmt, *args):
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    def do_GET(self):
        if self.path in ("/", "/index.html"):
            html_response(self)
            return
        if self.path == "/api/status":
            json_response(self, status())
            return
        if self.path == "/favicon.ico":
            self.send_response(204)
            self.end_headers()
            return
        json_response(self, {"error": "Not found"}, 404)

    def do_POST(self):
        try:
            payload = read_body(self)
            if self.path == "/api/chat":
                json_response(self, chat(payload))
                return
            if self.path == "/api/agent":
                json_response(self, run_agent(payload))
                return
            json_response(self, {"error": "Not found"}, 404)
        except Exception as exc:
            json_response(self, {"error": str(exc)}, 400)


def main():
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    print(f"Pocket Agent Sandbox listening on http://127.0.0.1:{PORT}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
'@

Set-Content -Path $ServerPath -Value $ServerCode -Encoding UTF8

$env:POCKET_SANDBOX_ROOT = $Root
$env:POCKET_SANDBOX_PORT = [string]$Port
$env:PYTHONIOENCODING = "utf-8"

if ($Foreground) {
    Write-Host "Starting Pocket Agent Sandbox in the foreground at $Url"
    if (-not $NoBrowser) {
        Start-Process $Url
    }
    & $Python @PythonArgs $ServerPath
    return
}

$OutLog = Join-Path $LogDir "sandbox_server.out.log"
$ErrLog = Join-Path $LogDir "sandbox_server.err.log"
$Args = @($PythonArgs + @("-u", $ServerPath))
$proc = Start-Process -FilePath $Python -ArgumentList $Args -WorkingDirectory $Root -WindowStyle Hidden -PassThru -RedirectStandardOutput $OutLog -RedirectStandardError $ErrLog
Set-Content -Path $PidFile -Value $proc.Id -Encoding ASCII

$ready = $false
for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Milliseconds 150
    if (Test-LocalPort -TestPort $Port) {
        $ready = $true
        break
    }
}

if (-not $ready) {
    throw "Sandbox server did not start. Check $ErrLog"
}

Write-Host "Pocket Agent Sandbox is running at $Url"
Write-Host "Stop it with: .\launch_sandbox.ps1 -Stop"
if (-not $NoBrowser) {
    Start-Process $Url
}
