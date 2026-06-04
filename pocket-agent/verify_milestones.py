"""Run every milestone, record PASS/SKIP/FAIL, write BUILD_REPORT.md.
Exit code = number of FAILED *required* milestones (0 = good)."""
import os
import sys
import time
import sqlite3
import pathlib
import traceback
import importlib.metadata as md

sys.path.insert(0, os.getcwd())

TMP = pathlib.Path(".build_tmp")
TMP.mkdir(exist_ok=True)
os.environ.setdefault("POCKET_NOTES_PATH", str(TMP / "notes.json"))
NOTES = pathlib.Path(os.environ["POCKET_NOTES_PATH"])


def fresh(name):
    p = TMP / name
    if p.exists():
        p.unlink()
    return str(p)


def clear_notes():
    if NOTES.exists():
        NOTES.unlink()


# --- imports that the whole harness depends on ------------------------------
try:
    from langgraph.checkpoint.sqlite import SqliteSaver
    from langgraph.types import Command
    from langgraph.graph import StateGraph, START, END
    from pocket_agent.graph import build_graph, route_after_agent, TOOLS
    from pocket_agent.model import detect_mode, make_chat_model
    from pocket_agent.stream import drive
except Exception as e:
    pathlib.Path("BUILD_REPORT.md").write_text(
        f"# Pocket Agent build report\n\nCATASTROPHIC import failure: {e!r}\n\n"
        f"```\n{traceback.format_exc()}\n```\n", encoding="utf-8")
    print(f"[CATASTROPHIC] {e}")
    sys.exit(2)

MODE = detect_mode()
results = []  # (id, status, detail, required, secs)


def record(mid, fn, required=False):
    t = time.time()
    try:
        detail = fn() or "ok"
        results.append((mid, "PASS", detail, required, round(time.time() - t, 2)))
        print(f"[PASS] {mid}: {detail}")
    except Exception as e:
        results.append((mid, "FAIL", f"{type(e).__name__}: {e}", required,
                        round(time.time() - t, 2)))
        print(f"[FAIL] {mid}: {e}")
        traceback.print_exc(limit=2)


def skip(mid, reason):
    results.append((mid, "SKIP", reason, False, 0.0))
    print(f"[SKIP] {mid}: {reason}")


# ============================ milestones ====================================
def m0():
    from typing import TypedDict

    class S(TypedDict):
        value: str

    b = StateGraph(S)
    b.add_node("echo", lambda s: {"value": s["value"]})
    b.add_edge(START, "echo")
    b.add_edge("echo", END)
    g = b.compile()
    assert g.invoke({"value": "ping"})["value"] == "ping"
    return "START -> echo -> END returns input unchanged"


def m1():
    g, _ = build_graph()
    res = g.invoke({"messages": [{"role": "user", "content": "hello there"}]})
    msgs = res["messages"]
    assert len(msgs) >= 2 and msgs[-1].type == "ai"
    return f"{len(msgs)} messages; final is an AI answer"


def m2():
    cp = SqliteSaver(sqlite3.connect(fresh("m2.db"), check_same_thread=False))
    g, _ = build_graph(checkpointer=cp)
    a = {"configurable": {"thread_id": "m2-a"}}
    g.invoke({"messages": [{"role": "user", "content": "my name is Ada"}]}, a)
    r = g.invoke({"messages": [{"role": "user", "content": "what is my name?"}]}, a)
    assert "Ada" in str(r["messages"][-1].content), "did not recall name on same thread"
    b = {"configurable": {"thread_id": "m2-b"}}
    r2 = g.invoke({"messages": [{"role": "user", "content": "what is my name?"}]}, b)
    assert "Ada" not in str(r2["messages"][-1].content), "leaked across threads"
    return "recall on same thread_id; isolation across a new thread_id"


def m3():
    a, b = 918273, 6457
    expected = str(a * b)
    g, _ = build_graph()
    res = g.invoke({"messages": [{"role": "user",
                    "content": f"Use the calculator tool to compute {a} * {b}."}]})
    msgs = res["messages"]
    assert any(getattr(m, "type", "") == "tool" and expected in str(m.content)
               for m in msgs), "calculator tool did not run / wrong result"
    assert msgs[-1].type == "ai" and not getattr(msgs[-1], "tool_calls", None)
    return f"agent -> tool(calculator={expected}) -> final answer (the cycle)"


def m4():
    g, _ = build_graph()
    out, path = drive(g, "what is 12 + 30?", {"configurable": {"thread_id": "m4"}})
    assert out and len(out) > 0, "no streamed output"
    return f"streamed a final answer via path='{path}'"


def m5():
    clear_notes()
    cp = SqliteSaver(sqlite3.connect(fresh("m5.db"), check_same_thread=False))
    g, _ = build_graph(checkpointer=cp, hitl=True)
    # approve path
    ca = {"configurable": {"thread_id": "m5-approve"}}
    r = g.invoke({"messages": [{"role": "user",
                  "content": "Save a note with exactly this text: overnight build OK"}]}, ca)
    assert "__interrupt__" in r, "did not pause at the HITL gate"
    g.invoke(Command(resume=True), ca)
    assert NOTES.exists() and "overnight build OK" in NOTES.read_text(encoding="utf-8")
    # reject path
    cr = {"configurable": {"thread_id": "m5-reject"}}
    r2 = g.invoke({"messages": [{"role": "user",
                   "content": "Save a note with exactly this text: should NOT persist"}]}, cr)
    assert "__interrupt__" in r2
    g.invoke(Command(resume=False), cr)
    assert "should NOT persist" not in NOTES.read_text(encoding="utf-8")
    return "interrupt pauses before write; resume=True writes, resume=False cancels"


def m6():
    from langgraph.store.memory import InMemoryStore
    st = InMemoryStore()
    ns = ("user-1", "memories")
    st.put(ns, "name", {"value": "Ada"})
    got = st.get(ns, "name")
    assert got and got.value["value"] == "Ada"
    found = st.search(("user-1",))
    assert any(it.key == "name" for it in found), "prefix search missed the item"
    g, _ = build_graph(store=st)  # graph accepts a store
    return "Store put/get/prefix-search works; graph compiles with store="


def m7():
    cp = SqliteSaver(sqlite3.connect(fresh("m7.db"), check_same_thread=False))
    g, _ = build_graph(checkpointer=cp)
    c = {"configurable": {"thread_id": "m7"}}
    g.invoke({"messages": [{"role": "user", "content": "hello"}]}, c)
    g.invoke({"messages": [{"role": "user", "content": "again"}]}, c)
    hist = list(g.get_state_history(c))
    assert len(hist) >= 2, "not enough checkpoints to time-travel"
    oldest = hist[-1]
    cid = oldest.config["configurable"]["checkpoint_id"]
    g.invoke(None, {"configurable": {"thread_id": "m7", "checkpoint_id": cid}})
    return f"{len(hist)} checkpoints enumerated; replayed from {cid[:8]}..."


def alt():
    if MODE == "mock":
        raise RuntimeError(
            "create_agent needs a live model; set ANTHROPIC_API_KEY/OPENAI_API_KEY "
            "or POCKET_USE_OLLAMA=1")
    from langchain.agents import create_agent
    _, model = make_chat_model()
    cp = SqliteSaver(sqlite3.connect(fresh("alt.db"), check_same_thread=False))
    agent = create_agent(model, tools=TOOLS, checkpointer=cp)
    r = agent.invoke({"messages": [{"role": "user", "content": "what is 6 * 7?"}]},
                     {"configurable": {"thread_id": "alt"}})
    assert "42" in str(r["messages"][-1].content)
    return "create_agent reached behavioral parity (6*7=42)"


# ============================ run ===========================================
print(f"\n=== verifying milestones (model mode: {MODE}) ===")
record("M0 empty graph", m0, required=True)
record("M1 model + chat memory", m1, required=True)
record("M2 durable multi-turn memory", m2, required=True)
record("M3 tools + the cycle", m3, required=True)
record("M4 streaming (v3 + fallback)", m4, required=False)
record("M5 human-approval gate (HITL)", m5, required=True)
record("M6 long-term Store", m6, required=False)
record("M7 time travel", m7, required=False)
if MODE == "mock":
    skip("ALT create_agent track", "no live model in mock mode")
else:
    record("ALT create_agent track", alt, required=False)


# ============================ report ========================================
def ver(p):
    try:
        return md.version(p)
    except Exception:
        return "-"


pkgs = ["langgraph", "langchain", "langchain-core", "langgraph-checkpoint",
        "langgraph-checkpoint-sqlite", "langgraph-sdk", "langgraph-prebuilt",
        "langchain-anthropic", "langchain-openai", "langchain-ollama"]

n_pass = sum(1 for r in results if r[1] == "PASS")
n_fail = sum(1 for r in results if r[1] == "FAIL")
n_skip = sum(1 for r in results if r[1] == "SKIP")
req_fail = sum(1 for r in results if r[1] == "FAIL" and r[3])

lines = []
lines.append("# Pocket Agent — overnight build report\n")
lines.append(f"- Python: `{sys.version.split()[0]}`")
lines.append(f"- Model mode: **{MODE}**"
             + ("  _(mock: structural verification only — set a provider key for"
                " real answers)_" if MODE == "mock" else ""))
lines.append(f"- Result: **{n_pass} passed, {n_fail} failed, {n_skip} skipped**"
             f"  (required failures: {req_fail})\n")
lines.append("## Milestones\n")
lines.append("| Milestone | Status | Detail | Req | Secs |")
lines.append("|---|---|---|---|---|")
for mid, status, detail, req, secs in results:
    badge = {"PASS": "PASS", "FAIL": "FAIL", "SKIP": "SKIP"}[status]
    lines.append(f"| {mid} | {badge} | {str(detail).replace('|', '/')} | "
                 f"{'yes' if req else ''} | {secs} |")
lines.append("\n## Installed versions\n")
lines.append("| Package | Version |")
lines.append("|---|---|")
for p in pkgs:
    lines.append(f"| {p} | {ver(p)} |")
lines.append("\n## Next steps (need a human / a model)\n")
lines.append("- Provide a tool-calling model for *real* answers: set "
             "`ANTHROPIC_API_KEY` or `OPENAI_API_KEY` (or `POCKET_USE_OLLAMA=1` "
             "with `ollama serve` + a tool-capable model) and re-run.")
lines.append("- Try it interactively: `python -m pocket_agent.cli`")
lines.append("- Optional Studio/server track: install `langgraph-cli[inmem]`, "
             "add a `langgraph.json`, run `langgraph dev`.")
pathlib.Path("BUILD_REPORT.md").write_text("\n".join(lines) + "\n", encoding="utf-8")

print(f"\n=== {n_pass} passed / {n_fail} failed / {n_skip} skipped "
      f"(required failures: {req_fail}) ===")
print("report: BUILD_REPORT.md")
sys.exit(min(req_fail, 120))
