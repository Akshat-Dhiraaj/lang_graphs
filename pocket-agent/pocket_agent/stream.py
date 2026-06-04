"""M4 - drive a run. Tries the v3 event-streaming API first, then falls back
to the stable stream_mode / invoke path. Returns (final_text, path_used)."""


def drive(graph, user_input, config=None):
    payload = {"messages": [{"role": "user", "content": user_input}]}

    # --- preferred: v3 typed-projection event streaming -------------------
    try:
        stream = graph.stream_events(payload, config=config, version="v3")
        parts = []
        for message in stream.messages:
            txt = getattr(message, "text", "")
            if isinstance(txt, str):
                parts.append(txt)
            else:
                try:
                    for tok in txt:
                        parts.append(tok)
                except TypeError:
                    parts.append(str(txt))
        final = "".join(parts).strip()
        if not final:
            raise RuntimeError("v3 produced no text")
        return final, "v3"
    except Exception:
        pass

    # --- stable fallback: stream_mode then a definitive invoke ------------
    try:
        for _ in graph.stream(payload, config, stream_mode="updates"):
            pass
        res = graph.invoke(payload, config)
        return str(res["messages"][-1].content), "stream_mode+invoke"
    except Exception:
        res = graph.invoke(payload, config)
        return str(res["messages"][-1].content), "invoke"
