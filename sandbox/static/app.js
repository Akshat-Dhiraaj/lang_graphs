const $ = (id) => document.getElementById(id);

const state = {
  docs: [],
  currentDocId: "",
  messages: [],
  timeline: [],
  toolTrace: [],
  lastOutput: "",
  threadId: newThreadId(),
  hitlThreadId: "",
  busy: false,
};

const CHAT_HISTORY_KEY = "pocket-agent-chat-history";

const PROVIDER_PRESETS = {
  "lmstudio-default": {
    provider: "lmstudio",
    baseUrl: "http://localhost:1234/v1",
    model: "qwen/qwen3.5-9b",
    temperature: 0.2,
    maxTokens: 900,
  },
  "openai-chat-mini": {
    provider: "openai",
    baseUrl: "",
    model: "gpt-5.4-mini",
    temperature: 0.2,
    maxTokens: 900,
  },
  "anthropic-haiku": {
    provider: "anthropic",
    baseUrl: "",
    model: "claude-haiku-4-5",
    temperature: 0.2,
    maxTokens: 900,
  },
  "gemini-flash": {
    provider: "gemini",
    baseUrl: "",
    model: "gemini-flash-latest",
    temperature: 0.2,
    maxTokens: 900,
  },
  "custom-openai": {
    provider: "custom-openai",
    baseUrl: "http://localhost:1234/v1",
    model: "",
    temperature: 0.2,
    maxTokens: 900,
  },
};

function newThreadId() {
  return `sandbox-${Math.random().toString(16).slice(2, 10)}`;
}

function readStoredTheme() {
  try {
    return localStorage.getItem("pocket-agent-theme");
  } catch {
    return null;
  }
}

function writeStoredTheme(theme) {
  try {
    localStorage.setItem("pocket-agent-theme", theme);
  } catch {
    return;
  }
}

function setTheme(theme) {
  const next = theme === "light" ? "light" : "dark";
  document.documentElement.dataset.theme = next;
  const button = $("themeToggle");
  button.textContent = next === "dark" ? "Light Mode" : "Dark Mode";
  button.setAttribute("aria-pressed", String(next === "dark"));
  writeStoredTheme(next);
}

function initTheme() {
  setTheme(readStoredTheme() || "dark");
}

function toggleTheme() {
  const current = document.documentElement.dataset.theme || "dark";
  setTheme(current === "dark" ? "light" : "dark");
}

function pill(text, kind = "") {
  const el = document.createElement("span");
  el.className = `pill ${kind}`.trim();
  el.textContent = text;
  return el;
}

function setStatus(items) {
  const target = $("status");
  target.innerHTML = "";
  for (const item of items) {
    target.appendChild(pill(item.text, item.kind));
  }
}

function setBusy(value, label = "") {
  state.busy = value;
  $("runPrompt").disabled = value;
  $("chatStatus").textContent = value ? label || "Running..." : "";
}

async function fetchJson(url, options = {}) {
  const res = await fetch(url, options);
  const data = await res.json().catch(() => ({}));
  if (!res.ok || data.ok === false) {
    throw new Error(data.error || `${res.status} ${res.statusText}`);
  }
  return data;
}

function updateThreadLabel() {
  $("threadLabel").textContent = `thread ${state.threadId}`;
}

function appendMessage(role, text) {
  const item = { role, text: String(text || "") };
  state.messages.push(item);
  renderTranscript();
  return item;
}

function renderTranscript() {
  const target = $("transcript");
  target.innerHTML = "";
  for (const msg of state.messages) {
    const el = document.createElement("div");
    el.className = `message ${msg.role}`;

    const role = document.createElement("div");
    role.className = "role";
    role.textContent = msg.role;

    const body = document.createElement("div");
    body.textContent = msg.text;

    el.append(role, body);
    target.appendChild(el);
  }
  target.scrollTop = target.scrollHeight;
}

function setMessageText(item, text) {
  item.text = String(text || "");
  renderTranscript();
}

function addTimeline(kind, text) {
  state.timeline.push({
    kind,
    text: String(text || ""),
    at: new Date().toLocaleTimeString(),
  });
  renderTimeline();
}

function renderTimeline() {
  const target = $("timeline");
  target.innerHTML = "";
  for (const item of state.timeline) {
    const row = document.createElement("li");
    const label = document.createElement("strong");
    label.textContent = `${item.kind}: `;
    row.append(label, `${item.text} (${item.at})`);
    target.appendChild(row);
  }
}

function addToolTrace(phase, name, detail = "") {
  state.toolTrace.push({
    phase,
    name: name || "tool",
    detail: String(detail || ""),
    at: new Date().toLocaleTimeString(),
  });
  renderToolTrace();
}

function renderToolTrace() {
  const target = $("toolTrace");
  target.innerHTML = "";
  for (const item of state.toolTrace) {
    const row = document.createElement("div");
    row.className = "trace-item";
    const label = document.createElement("strong");
    label.textContent = `${item.phase}: ${item.name}`;
    row.append(label);
    if (item.detail) row.append(` - ${item.detail}`);
    row.append(` (${item.at})`);
    target.appendChild(row);
  }
}

function resetRunInspector() {
  state.timeline = [];
  state.toolTrace = [];
  renderTimeline();
  renderToolTrace();
}

function chatSnapshot() {
  return {
    version: 1,
    savedAt: new Date().toISOString(),
    threadId: state.threadId,
    messages: state.messages,
    timeline: state.timeline,
    toolTrace: state.toolTrace,
    lastOutput: state.lastOutput,
  };
}

function setTemporaryStatus(text) {
  $("chatStatus").textContent = text;
  setTimeout(() => {
    if (!state.busy && $("chatStatus").textContent === text) {
      $("chatStatus").textContent = "";
    }
  }, 1400);
}

function saveChatHistory() {
  try {
    localStorage.setItem(CHAT_HISTORY_KEY, JSON.stringify(chatSnapshot()));
    setTemporaryStatus("Chat saved");
  } catch (err) {
    setTemporaryStatus(`Save failed: ${err.message}`);
  }
}

function loadChatHistory() {
  try {
    const raw = localStorage.getItem(CHAT_HISTORY_KEY);
    if (!raw) {
      setTemporaryStatus("No saved chat");
      return;
    }
    const saved = JSON.parse(raw);
    state.threadId = saved.threadId || newThreadId();
    state.messages = Array.isArray(saved.messages) ? saved.messages : [];
    state.timeline = Array.isArray(saved.timeline) ? saved.timeline : [];
    state.toolTrace = Array.isArray(saved.toolTrace) ? saved.toolTrace : [];
    state.lastOutput = saved.lastOutput || "";
    updateThreadLabel();
    renderTranscript();
    renderTimeline();
    renderToolTrace();
    setTemporaryStatus("Saved chat loaded");
  } catch (err) {
    setTemporaryStatus(`Load failed: ${err.message}`);
  }
}

function exportChatHistory() {
  const snapshot = chatSnapshot();
  const blob = new Blob([JSON.stringify(snapshot, null, 2)], {
    type: "application/json",
  });
  const url = URL.createObjectURL(blob);
  const link = document.createElement("a");
  link.href = url;
  link.download = `pocket-agent-chat-${snapshot.threadId}.json`;
  document.body.appendChild(link);
  link.click();
  link.remove();
  URL.revokeObjectURL(url);
  setTemporaryStatus("Chat exported");
}

function applyPreset(id, status = null) {
  const preset = PROVIDER_PRESETS[id] || PROVIDER_PRESETS["lmstudio-default"];
  $("providerPreset").value = id;
  $("provider").value = preset.provider;
  $("baseUrl").value = preset.baseUrl;
  $("model").value = preset.model;
  $("temperature").value = preset.temperature;
  $("maxTokens").value = preset.maxTokens;
  providerDefaults(status);
}

function presetForProvider(provider) {
  return Object.entries(PROVIDER_PRESETS).find(([, preset]) => preset.provider === provider)?.[0] || "custom-openai";
}

function providerDefaults(status = null) {
  const provider = $("provider").value;
  if (provider === "lmstudio") {
    $("baseUrl").value = status?.lmstudio?.base_url || $("baseUrl").value || "http://localhost:1234/v1";
    $("model").value = status?.lmstudio?.model || status?.lmstudio?.default_model || $("model").value || "qwen/qwen3.5-9b";
  }
}

function chatSettingsPayload(prompt) {
  return {
    provider: $("provider").value,
    baseUrl: $("baseUrl").value.trim(),
    model: $("model").value.trim(),
    apiKey: $("apiKey").value.trim(),
    temperature: Number($("temperature").value || 0.2),
    maxTokens: Number.parseInt($("maxTokens").value || "900", 10),
    prompt,
  };
}

async function refreshStatus() {
  setStatus([{ text: "Checking local status...", kind: "warn" }]);
  try {
    const data = await fetchJson("/api/status");
    providerDefaults(data);
    const lm = data.lmstudio || {};
    setStatus([
      { text: data.git?.clean ? "git clean" : "git has changes", kind: data.git?.clean ? "good" : "warn" },
      { text: data.build?.ok ? `build ${data.build.result || "ok"}` : "build report missing/failing", kind: data.build?.ok ? "good" : "warn" },
      { text: `python ${data.python || "unknown"}`, kind: "good" },
      { text: lm.up ? `LM Studio server ${lm.model || "up"}` : "LM Studio server offline", kind: lm.up ? "good" : "warn" },
      { text: lm.default_loaded && lm.settings_ok ? "default model ready" : "default model not normalized", kind: lm.default_loaded && lm.settings_ok ? "good" : "warn" },
    ]);
  } catch (err) {
    setStatus([{ text: err.message, kind: "bad" }]);
  }
}

async function loadDocs() {
  try {
    const data = await fetchJson("/api/docs/reference");
    state.docs = data.items || [];
    renderDocButtons();
    if (state.docs.length) {
      selectDoc(state.docs[0].id);
    }
  } catch (err) {
    $("docView").textContent = err.message;
  }
}

function docMatchesSearch(doc, query) {
  if (!query) return true;
  const haystack = [
    doc.title,
    doc.path,
    doc.description,
    doc.content,
  ].join("\n").toLowerCase();
  return haystack.includes(query);
}

function renderDocButtons() {
  const target = $("docList");
  target.innerHTML = "";
  const query = ($("docSearch")?.value || "").trim().toLowerCase();
  const docs = state.docs.filter((doc) => docMatchesSearch(doc, query));
  $("docCount").textContent = `${docs.length} of ${state.docs.length} docs`;
  for (const doc of docs) {
    const btn = document.createElement("button");
    btn.type = "button";
    btn.textContent = doc.title;
    btn.dataset.doc = doc.id;
    btn.addEventListener("click", () => selectDoc(doc.id));
    target.appendChild(btn);
  }
  if (docs.length && !docs.some((doc) => doc.id === state.currentDocId)) {
    selectDoc(docs[0].id);
  } else if (!docs.length) {
    $("docTitle").textContent = "No matching docs";
    $("docMeta").textContent = "";
    $("docView").textContent = "Try a different search term.";
  }
}

function selectDoc(id) {
  const doc = state.docs.find((item) => item.id === id);
  if (!doc) return;
  state.currentDocId = id;
  for (const btn of $("docList").querySelectorAll("button")) {
    btn.classList.toggle("active", btn.dataset.doc === id);
  }
  $("docTitle").textContent = doc.title;
  $("docMeta").textContent = `${doc.path}${doc.truncated ? " - trimmed" : ""}`;
  $("docView").textContent = doc.content || "";
}

function filterDocs() {
  renderDocButtons();
}

async function runDirectChat(prompt, assistantMsg) {
  const payload = chatSettingsPayload(prompt);
  const data = await fetchJson("/api/chat", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload),
  });
  const text = data.text || "(empty response)";
  setMessageText(assistantMsg, text);
  state.lastOutput = text;
}

function showChatError(assistantMsg, err) {
  const text = `Error: ${err.message || err}`;
  setMessageText(assistantMsg, text);
  state.lastOutput = text;
}

async function runGraphStream(prompt, assistantMsg) {
  resetRunInspector();
  const res = await fetch("/api/agent/stream", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ prompt, threadId: state.threadId }),
  });
  if (!res.ok || !res.body) {
    const text = await res.text();
    throw new Error(text || `${res.status} ${res.statusText}`);
  }

  const reader = res.body.getReader();
  const decoder = new TextDecoder();
  let buffer = "";
  const progress = [];

  while (true) {
    const { value, done } = await reader.read();
    if (done) break;
    buffer += decoder.decode(value, { stream: true });
    const lines = buffer.split("\n");
    buffer = lines.pop() || "";
    for (const line of lines) {
      if (line.trim()) {
        handleStreamEvent(JSON.parse(line), assistantMsg, progress);
      }
    }
  }
  if (buffer.trim()) {
    handleStreamEvent(JSON.parse(buffer), assistantMsg, progress);
  }
}

function handleStreamEvent(event, assistantMsg, progress) {
  if (event.thread_id) {
    state.threadId = event.thread_id;
    updateThreadLabel();
  }
  if (event.event === "start") {
    addTimeline("start", `graph started (${event.mode})`);
    setMessageText(assistantMsg, `graph started (${event.mode})`);
  } else if (event.event === "update") {
    addTimeline(event.kind || "update", event.text || "");
    if (event.kind === "tool_call") {
      addToolTrace("requested", (event.text || "").replace("agent requested ", ""), "");
    } else if (event.kind === "tool") {
      addToolTrace("result", "tool", event.text || "");
    }
    progress.push(event.text);
    setMessageText(assistantMsg, progress.join("\n"));
  } else if (event.event === "final") {
    const text = event.text || "(empty response)";
    addTimeline("final", text);
    setMessageText(assistantMsg, text);
    state.lastOutput = text;
  } else if (event.event === "error") {
    addTimeline("error", event.error || "stream error");
    throw new Error(event.error || "stream error");
  }
}

async function runPromptText(prompt, mode = $("mode").value) {
  if (!prompt) return;
  $("mode").value = mode;
  appendMessage("user", prompt);
  const assistantMsg = appendMessage("assistant", "");
  setBusy(true, "Running...");
  try {
    if (mode === "graph") {
      await runGraphStream(prompt, assistantMsg);
    } else {
      await runDirectChat(prompt, assistantMsg);
    }
  } catch (err) {
    showChatError(assistantMsg, err);
  } finally {
    setBusy(false);
  }
}

async function runPrompt() {
  await runPromptText($("prompt").value.trim());
}

async function copyLast() {
  if (!state.lastOutput) return;
  await navigator.clipboard.writeText(state.lastOutput);
  setTemporaryStatus("Copied");
}

function resetThread() {
  state.threadId = newThreadId();
  state.messages = [];
  resetRunInspector();
  state.lastOutput = "";
  renderTranscript();
  updateThreadLabel();
  setTemporaryStatus("Thread reset");
}

async function callTool(name, args = {}) {
  const data = await fetchJson("/api/tool", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ name, args }),
  });
  const text = `${data.tool}: ${data.result}`;
  $("toolResult").textContent = text;
  addTimeline("tool", text);
  addToolTrace("direct", data.tool, data.result);
  appendMessage("tool", text);
  state.lastOutput = text;
}

async function guardedToolCall(name, args) {
  try {
    await callTool(name, args);
  } catch (err) {
    $("toolResult").textContent = `Error: ${err.message}`;
  }
}

function setHitlPending(enabled) {
  $("approveHitl").disabled = !enabled;
  $("rejectHitl").disabled = !enabled;
}

async function startHitl() {
  const text = $("hitlNote").value.trim();
  if (!text) return;
  $("hitlResult").textContent = "Starting graph...";
  setHitlPending(false);
  try {
    const data = await fetchJson("/api/hitl/start", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ text }),
    });
    state.hitlThreadId = data.thread_id || "";
    $("hitlResult").textContent = JSON.stringify(data, null, 2);
    setHitlPending(Boolean(data.paused));
    addTimeline(data.paused ? "hitl paused" : "hitl finished", data.text || "");
    addToolTrace("pending", "save_note", text);
    appendMessage("tool", data.text || "HITL started");
  } catch (err) {
    $("hitlResult").textContent = `Error: ${err.message}`;
  }
}

async function resumeHitl(approve) {
  if (!state.hitlThreadId) return;
  $("hitlResult").textContent = approve ? "Approving..." : "Rejecting...";
  try {
    const data = await fetchJson("/api/hitl/resume", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ threadId: state.hitlThreadId, approve }),
    });
    $("hitlResult").textContent = JSON.stringify(data, null, 2);
    addTimeline(approve ? "hitl approved" : "hitl rejected", data.text || "");
    addToolTrace(approve ? "approved" : "rejected", "save_note", data.note || "");
    appendMessage("tool", data.text || (approve ? "Approved" : "Rejected"));
    state.lastOutput = data.text || "";
  } catch (err) {
    $("hitlResult").textContent = `Error: ${err.message}`;
  } finally {
    state.hitlThreadId = "";
    setHitlPending(false);
  }
}

function setDemoBusy(value) {
  for (const btn of document.querySelectorAll("[data-demo]")) {
    btn.disabled = value;
  }
}

async function runDemoScript(name) {
  setDemoBusy(true);
  try {
    if (name === "memory") {
      resetThread();
      $("prompt").value = "My name is Ada.";
      await runPromptText("My name is Ada.", "graph");
      $("prompt").value = "What is my name?";
      await runPromptText("What is my name?", "graph");
      setTemporaryStatus("Memory demo complete");
    } else if (name === "tools") {
      $("prompt").value = "What is 18 * 24? Use the calculator tool.";
      await runPromptText("What is 18 * 24? Use the calculator tool.", "graph");
      setTemporaryStatus("Tools demo complete");
    } else if (name === "hitl") {
      $("hitlNote").value = "demo script HITL note";
      await startHitl();
      setTemporaryStatus("HITL demo paused");
    } else if (name === "streaming") {
      $("prompt").value = "What is 123 * 4? Use the calculator tool.";
      await runPromptText("What is 123 * 4? Use the calculator tool.", "graph");
      setTemporaryStatus("Streaming demo complete");
    }
  } catch (err) {
    setTemporaryStatus(`Demo failed: ${err.message}`);
  } finally {
    setDemoBusy(false);
  }
}

async function loadDefaultModel() {
  setStatus([{ text: "Loading default LM Studio model...", kind: "warn" }]);
  try {
    const data = await fetchJson("/api/lmstudio/load-default", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({}),
    });
    setStatus([{ text: data.message || "Default model ready", kind: "good" }]);
    await refreshStatus();
  } catch (err) {
    setStatus([{ text: err.message, kind: "bad" }]);
  }
}

function wireEvents() {
  $("themeToggle").addEventListener("click", toggleTheme);
  $("refreshStatus").addEventListener("click", refreshStatus);
  $("checkModel").addEventListener("click", refreshStatus);
  $("loadDefaultModel").addEventListener("click", loadDefaultModel);
  $("docSearch").addEventListener("input", filterDocs);
  $("providerPreset").addEventListener("change", () => applyPreset($("providerPreset").value));
  $("provider").addEventListener("change", () => applyPreset(presetForProvider($("provider").value)));
  $("runPrompt").addEventListener("click", runPrompt);
  $("prompt").addEventListener("keydown", (event) => {
    if ((event.ctrlKey || event.metaKey) && event.key === "Enter") {
      runPrompt();
    }
  });
  $("copyLast").addEventListener("click", copyLast);
  $("saveChat").addEventListener("click", saveChatHistory);
  $("loadChat").addEventListener("click", loadChatHistory);
  $("exportChat").addEventListener("click", exportChatHistory);
  $("resetThread").addEventListener("click", resetThread);
  for (const btn of document.querySelectorAll("[data-prompt]")) {
    btn.addEventListener("click", () => {
      $("prompt").value = btn.dataset.prompt || "";
      $("prompt").focus();
    });
  }
  for (const btn of document.querySelectorAll("[data-demo]")) {
    btn.addEventListener("click", () => runDemoScript(btn.dataset.demo || ""));
  }
  $("runCalculator").addEventListener("click", () => {
    guardedToolCall("calculator", { expression: $("calcExpression").value.trim() });
  });
  $("runTime").addEventListener("click", () => guardedToolCall("get_time", {}));
  $("saveNoteTool").addEventListener("click", () => {
    guardedToolCall("save_note", { text: $("noteText").value.trim() });
  });
  $("readNotesTool").addEventListener("click", () => guardedToolCall("read_notes", {}));
  $("startHitl").addEventListener("click", startHitl);
  $("approveHitl").addEventListener("click", () => resumeHitl(true));
  $("rejectHitl").addEventListener("click", () => resumeHitl(false));
}

initTheme();
wireEvents();
applyPreset("lmstudio-default");
updateThreadLabel();
setHitlPending(false);
refreshStatus();
loadDocs();
