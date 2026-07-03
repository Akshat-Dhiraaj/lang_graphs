const $ = (id) => document.getElementById(id);

const state = {
  docs: [],
  messages: [],
  lastOutput: "",
  threadId: newThreadId(),
  hitlThreadId: "",
  busy: false,
};

function newThreadId() {
  return `sandbox-${Math.random().toString(16).slice(2, 10)}`;
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

function providerDefaults(status = null) {
  const provider = $("provider").value;
  if (provider === "lmstudio") {
    $("baseUrl").value = status?.lmstudio?.base_url || $("baseUrl").value || "http://localhost:1234/v1";
    $("model").value = status?.lmstudio?.model || status?.lmstudio?.default_model || $("model").value || "qwen/qwen3.5-9b";
  } else if (provider === "openai" && !$("model").value) {
    $("model").value = "gpt-4o-mini";
  } else if (provider === "anthropic" && !$("model").value) {
    $("model").value = "claude-3-5-haiku-latest";
  } else if (provider === "gemini" && !$("model").value) {
    $("model").value = "gemini-1.5-flash";
  }
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

function renderDocButtons() {
  const target = $("docList");
  target.innerHTML = "";
  for (const doc of state.docs) {
    const btn = document.createElement("button");
    btn.type = "button";
    btn.textContent = doc.title;
    btn.dataset.doc = doc.id;
    btn.addEventListener("click", () => selectDoc(doc.id));
    target.appendChild(btn);
  }
}

function selectDoc(id) {
  const doc = state.docs.find((item) => item.id === id);
  if (!doc) return;
  for (const btn of $("docList").querySelectorAll("button")) {
    btn.classList.toggle("active", btn.dataset.doc === id);
  }
  $("docTitle").textContent = doc.title;
  $("docMeta").textContent = `${doc.path}${doc.truncated ? " - trimmed" : ""}`;
  $("docView").textContent = doc.content || "";
}

async function runDirectChat(prompt, assistantMsg) {
  const payload = {
    provider: $("provider").value,
    baseUrl: $("baseUrl").value.trim(),
    model: $("model").value.trim(),
    apiKey: $("apiKey").value.trim(),
    prompt,
  };
  const data = await fetchJson("/api/chat", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload),
  });
  const text = data.text || "(empty response)";
  setMessageText(assistantMsg, text);
  state.lastOutput = text;
}

async function runGraphStream(prompt, assistantMsg) {
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
    setMessageText(assistantMsg, `graph started (${event.mode})`);
  } else if (event.event === "update") {
    progress.push(event.text);
    setMessageText(assistantMsg, progress.join("\n"));
  } else if (event.event === "final") {
    const text = event.text || "(empty response)";
    setMessageText(assistantMsg, text);
    state.lastOutput = text;
  } else if (event.event === "error") {
    throw new Error(event.error || "stream error");
  }
}

async function runPrompt() {
  const prompt = $("prompt").value.trim();
  if (!prompt) return;
  appendMessage("user", prompt);
  const assistantMsg = appendMessage("assistant", "");
  setBusy(true, "Running...");
  try {
    if ($("mode").value === "graph") {
      await runGraphStream(prompt, assistantMsg);
    } else {
      await runDirectChat(prompt, assistantMsg);
    }
  } catch (err) {
    setMessageText(assistantMsg, `Error: ${err.message}`);
    state.lastOutput = assistantMsg.text;
  } finally {
    setBusy(false);
  }
}

async function copyLast() {
  if (!state.lastOutput) return;
  await navigator.clipboard.writeText(state.lastOutput);
  $("chatStatus").textContent = "Copied";
  setTimeout(() => {
    if (!state.busy) $("chatStatus").textContent = "";
  }, 1200);
}

function resetThread() {
  state.threadId = newThreadId();
  state.messages = [];
  state.lastOutput = "";
  renderTranscript();
  updateThreadLabel();
  $("chatStatus").textContent = "Thread reset";
  setTimeout(() => {
    if (!state.busy) $("chatStatus").textContent = "";
  }, 1200);
}

async function callTool(name, args = {}) {
  const data = await fetchJson("/api/tool", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ name, args }),
  });
  const text = `${data.tool}: ${data.result}`;
  $("toolResult").textContent = text;
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
    appendMessage("tool", data.text || (approve ? "Approved" : "Rejected"));
    state.lastOutput = data.text || "";
  } catch (err) {
    $("hitlResult").textContent = `Error: ${err.message}`;
  } finally {
    state.hitlThreadId = "";
    setHitlPending(false);
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
  $("refreshStatus").addEventListener("click", refreshStatus);
  $("checkModel").addEventListener("click", refreshStatus);
  $("loadDefaultModel").addEventListener("click", loadDefaultModel);
  $("provider").addEventListener("change", () => providerDefaults());
  $("runPrompt").addEventListener("click", runPrompt);
  $("prompt").addEventListener("keydown", (event) => {
    if ((event.ctrlKey || event.metaKey) && event.key === "Enter") {
      runPrompt();
    }
  });
  $("copyLast").addEventListener("click", copyLast);
  $("resetThread").addEventListener("click", resetThread);
  for (const btn of document.querySelectorAll("[data-prompt]")) {
    btn.addEventListener("click", () => {
      $("prompt").value = btn.dataset.prompt || "";
      $("prompt").focus();
    });
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

wireEvents();
updateThreadLabel();
setHitlPending(false);
refreshStatus();
loadDocs();
