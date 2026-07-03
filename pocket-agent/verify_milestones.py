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
        try:
            p.unlink()
        except PermissionError:
            p = TMP / f"{p.stem}-{time.time_ns()}{p.suffix}"
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


def server_cfg():
    """§8 - the graph is exposed for `langgraph dev` / Studio / the SDK.

    Deterministic, no server boot: assert langgraph.json parses, each declared
    graph imports to a *compiled* graph (NOT the (graph, mode) tuple), and the
    SDK client entrypoint imports. Booting `langgraph dev` + a live SDK run is a
    manual step (see README)."""
    import json as _json
    import importlib
    cfgp = pathlib.Path("langgraph.json")
    if not cfgp.exists():
        raise RuntimeError("langgraph.json not found")
    cfg = _json.loads(cfgp.read_text(encoding="utf-8"))
    graphs = cfg.get("graphs", {})
    assert graphs, "no graphs declared in langgraph.json"
    loaded = []
    for name, spec in graphs.items():
        path_part, _, attr = spec.partition(":")
        assert attr, f"graph '{name}' spec missing ':attr'"
        modname = ("pocket_agent." + pathlib.Path(path_part).stem
                   if path_part.endswith(".py") else path_part)
        factory = getattr(importlib.import_module(modname), attr)
        g = factory() if callable(factory) else factory
        assert not isinstance(g, tuple), (
            f"graph '{name}' resolved to a tuple; the server needs a compiled "
            "graph (unwrap build_graph()[0])")
        assert hasattr(g, "invoke") and hasattr(g, "stream"), \
            f"graph '{name}' is not a compiled graph"
        loaded.append(name)
    from langgraph_sdk import get_sync_client  # noqa: F401  (call the live server)
    return f"langgraph.json OK; compiled graphs: {', '.join(loaded)}; SDK client importable"


def m9_middleware():
    """§7+ (Phase 3) - middleware showcase + custom middleware + structured output.

    Deterministic (mock-safe): the custom NoteGuardMiddleware hooks behave
    correctly, and create_agent compiles with the full middleware stack +
    response_format (verified with a keyless fake chat model). With a live model
    configured, additionally run the agent and assert a structured_response."""
    import itertools
    from langchain_core.messages import AIMessage, SystemMessage, HumanMessage, ToolMessage
    from langchain_core.language_models.fake_chat_models import GenericFakeChatModel
    from langgraph.checkpoint.memory import InMemorySaver
    from langchain.agents.middleware import ToolCallRequest
    from alt_create_agent.middleware_showcase import (
        NoteGuardMiddleware, build_showcase_agent, build_live_showcase_agent)

    # (1) custom before_model: inject a guardrail note once, then idempotent
    mw = NoteGuardMiddleware()
    out = mw.before_model({"messages": [HumanMessage(content="hi")]})
    assert out and any(isinstance(m, SystemMessage) for m in out["messages"]), \
        "before_model should inject a system note"
    assert mw.before_model({"messages": out["messages"]}) is None, \
        "before_model must be idempotent"

    # (2) custom wrap_tool_call: block an empty save_note WITHOUT running it
    ran = {"called": False}
    def _handler(req):
        ran["called"] = True
        return ToolMessage(content="saved", tool_call_id="x")
    empty = ToolCallRequest(
        tool_call={"name": "save_note", "args": {"text": "  "}, "id": "x", "type": "tool_call"},
        tool=None, state={"messages": []}, runtime=None)
    blocked = mw.wrap_tool_call(empty, _handler)
    assert getattr(blocked, "status", None) == "error" and not ran["called"], \
        "empty save_note must be blocked and the tool not run"
    ok = ToolCallRequest(
        tool_call={"name": "save_note", "args": {"text": "real"}, "id": "y", "type": "tool_call"},
        tool=None, state={"messages": []}, runtime=None)
    delivered = mw.wrap_tool_call(ok, _handler)
    assert ran["called"] and getattr(delivered, "content", None) == "saved", \
        "a valid save_note must be delegated to the tool"

    # (3) the whole stack + structured output COMPILES keyless (fake model)
    fake = GenericFakeChatModel(messages=itertools.cycle([AIMessage(content="ok")]))
    agent = build_showcase_agent(fake, checkpointer=InMemorySaver())
    assert hasattr(agent, "invoke") and hasattr(agent, "stream"), \
        "showcase agent did not compile"

    # (4) live behaviour only when a real model is configured
    if MODE == "mock":
        return ("custom hooks OK; create_agent compiled with 6 middleware + "
                "structured output (live run skipped: mock mode)")
    agent_live, lmode = build_live_showcase_agent(db_path=fresh("showcase.db"))
    cfg = {"configurable": {"thread_id": "m9"}}
    r = agent_live.invoke(
        {"messages": [{"role": "user", "content": "What is 6 * 7? Answer concisely."}]}, cfg)
    assert "structured_response" in r, "expected a structured_response (response_format)"
    return f"custom hooks OK; compiled; live structured_response present (mode={lmode})"


def m10_semantic():
    """§ stretch (Phase 2) - long-term Store *semantic* search.

    Mock-safe: build an InMemoryStore with a vector index (keyless deterministic
    embedder in mock mode), put docs, and assert the query ranks the relevant
    docs above the unrelated one, with scores. Uses the configured provider's
    embeddings when `POCKET_EMBED_MODEL` is set."""
    from pocket_agent.semantic import make_embeddings, make_semantic_store
    mode, emb, dims = make_embeddings()
    store = make_semantic_store(emb, dims)
    for k, t in [("d1", "python programming language tutorial"),
                 ("d2", "italian pasta and pizza recipes"),
                 ("d3", "guide to the rust programming language")]:
        store.put(("docs",), k, {"text": t})
    res = store.search(("docs",), query="programming language", limit=3)
    assert res, "semantic search returned no results"
    assert all(getattr(r, "score", None) is not None for r in res), "results should be scored"
    top = res[0].key
    assert top in {"d1", "d3"}, f"expected a programming doc ranked first, got {top}"
    return f"semantic store ({mode} embeddings, dims={dims}): query ranked '{top}' first of {len(res)}"


def m11_delta():
    """§ stretch (Phase 2) - DeltaChannel (beta): diff-based checkpoint storage.

    Deterministic & mock-safe: (1) a DeltaChannel and an equivalent
    BinaryOperatorAggregate reconstruct the SAME accumulated value, but the
    DeltaChannel's checkpoint blob is a sentinel (constant size) while the binop
    stores the full growing list; (2) a graph using a DeltaChannel field
    accumulates correctly across steps under a checkpointer."""
    from pocket_agent.delta_demo import compare_channels, build_delta_demo_graph
    from langgraph.checkpoint.memory import InMemorySaver
    same, sentinel, full_len, n = compare_channels(8)
    assert same, "DeltaChannel must reconstruct the same value as full-snapshot"
    assert sentinel, "DeltaChannel checkpoint blob should be a sentinel, not the full list"
    g = build_delta_demo_graph(steps=5, checkpointer=InMemorySaver())
    out = g.invoke({"log": [], "n": 0}, {"configurable": {"thread_id": "m11"}})
    assert out["log"] == [f"step{i}" for i in range(5)], f"unexpected delta graph log: {out['log']}"
    return (f"DeltaChannel reconstructs == full snapshot over {n} writes; checkpoint "
            f"stores a sentinel (vs full list len {full_len}); graph accumulated 5 steps")


def m12_postgres():
    """§ Phase 5 - Postgres persistence.

    Default path is skip-aware: verify optional imports and helper shape, but do
    not require a running database. Set ``POCKET_POSTGRES_URI`` to exercise a
    real PostgresSaver/PostgresStore-backed graph.
    """
    from pocket_agent.persistence import open_postgres_graph, postgres_available

    if not postgres_available():
        return "live DB run skipped (install langgraph-checkpoint-postgres)"
    uri = os.getenv("POCKET_POSTGRES_URI")
    if not uri:
        return "Postgres helpers import; live DB run skipped (set POCKET_POSTGRES_URI)"
    with open_postgres_graph(
        uri,
        setup=os.getenv("POCKET_POSTGRES_SETUP") == "1",
    ) as (graph, _mode):
        cfg = {"configurable": {"thread_id": "m12-postgres"}}
        graph.invoke({"messages": [{"role": "user", "content": "my name is Ada"}]}, cfg)
        out = graph.invoke({"messages": [{"role": "user", "content": "what is my name?"}]}, cfg)
    assert "Ada" in str(out["messages"][-1].content)
    return "PostgresSaver/PostgresStore compiled and preserved thread memory"


def m13_cache():
    """§ Phase 5 - node caching."""
    from pocket_agent.cache_demo import cache_roundtrip

    first, second, calls = cache_roundtrip(5)
    assert first == [{"expensive": {"result": 10}}]
    assert second[-1].get("__metadata__", {}).get("cached") is True
    assert calls == 1, f"expected cached second call, saw {calls} node executions"
    return "CachePolicy + InMemoryCache reused the second node result"


def m14_stream_projection():
    """§ Phase 5 - custom v3 StreamTransformer projection."""
    from pocket_agent.stream_projection import collect_progress_events

    progress = collect_progress_events("ok")
    assert progress == [{"stage": "node", "text": "ok"}]
    return "StreamTransformer projected custom progress as custom:progress"


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
try:
    import langgraph_sdk  # noqa: F401
    _HAVE_SDK = True
except Exception:
    _HAVE_SDK = False
if _HAVE_SDK and pathlib.Path("langgraph.json").exists():
    record("M8 server graph (langgraph dev / Studio / SDK)", server_cfg, required=False)
else:
    skip("M8 server graph (langgraph dev / Studio / SDK)",
         "needs langgraph.json + langgraph-sdk (pip install 'langgraph-cli[inmem]')")
record("M9 middleware showcase + structured output", m9_middleware, required=False)
record("M10 Store semantic search", m10_semantic, required=False)
record("M11 DeltaChannel (beta) diff-based checkpoints", m11_delta, required=False)
record("M12 Postgres persistence/store", m12_postgres, required=False)
record("M13 node caching", m13_cache, required=False)
record("M14 custom StreamTransformer", m14_stream_projection, required=False)
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
        "langgraph-checkpoint-sqlite", "langgraph-sdk", "langgraph-cli",
        "langgraph-prebuilt", "langgraph-checkpoint-postgres", "psycopg",
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
lines.append("\n## Next steps\n")
if MODE == "mock":
    lines.append("- Provide a tool-calling model for *real* answers: set "
                 "`POCKET_USE_LMSTUDIO=1`, `ANTHROPIC_API_KEY`, or "
                 "`OPENAI_API_KEY` (or `POCKET_USE_OLLAMA=1` with `ollama serve` "
                 "+ a tool-capable model) and re-run.")
else:
    lines.append(f"- Live model mode is already active (`{MODE}`). Use "
                 "`POCKET_FORCE_MOCK=1` when you want deterministic keyless checks.")
if not os.getenv("POCKET_POSTGRES_URI"):
    lines.append("- Optional live Postgres check: set `POCKET_POSTGRES_URI` and "
                 "`POCKET_POSTGRES_SETUP=1` when you want the verifier to create "
                 "or migrate tables.")
lines.append("- Try it interactively: `python -m pocket_agent.cli`")
lines.append("- Optional Studio/server track: run `langgraph dev` from `pocket-agent/`.")
pathlib.Path("BUILD_REPORT.md").write_text("\n".join(lines) + "\n", encoding="utf-8")

print(f"\n=== {n_pass} passed / {n_fail} failed / {n_skip} skipped "
      f"(required failures: {req_fail}) ===")
print("report: BUILD_REPORT.md")
sys.exit(min(req_fail, 120))
