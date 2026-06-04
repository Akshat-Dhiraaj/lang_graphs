"""M3 - deterministic, local, side-effect-tiny tools. No network, no model."""
import ast
import os
import pathlib
import datetime
import operator as _op
from langchain_core.tools import tool

# ---- safe arithmetic (no eval) ---------------------------------------------
_ALLOWED = {
    ast.Add: _op.add, ast.Sub: _op.sub, ast.Mult: _op.mul, ast.Div: _op.truediv,
    ast.Pow: _op.pow, ast.Mod: _op.mod, ast.FloorDiv: _op.floordiv,
    ast.USub: _op.neg, ast.UAdd: _op.pos,
}


def _eval(node):
    if isinstance(node, ast.Constant) and isinstance(node.value, (int, float)):
        return node.value
    if isinstance(node, ast.BinOp) and type(node.op) in _ALLOWED:
        return _ALLOWED[type(node.op)](_eval(node.left), _eval(node.right))
    if isinstance(node, ast.UnaryOp) and type(node.op) in _ALLOWED:
        return _ALLOWED[type(node.op)](_eval(node.operand))
    raise ValueError("unsupported expression")


@tool
def calculator(expression: str) -> str:
    """Evaluate a basic arithmetic expression, e.g. '47 * 89'."""
    try:
        return str(_eval(ast.parse(expression, mode="eval").body))
    except Exception as e:  # noqa: BLE001 - tools should not raise
        return f"error: {e}"


@tool
def get_time() -> str:
    """Return the current local time as an ISO-8601 string."""
    return datetime.datetime.now().isoformat(timespec="seconds")


def _notes_path() -> pathlib.Path:
    return pathlib.Path(os.getenv("POCKET_NOTES_PATH", "notes.json"))


@tool
def save_note(text: str) -> str:
    """Append a note to the local notes file. Returns a confirmation."""
    p = _notes_path()
    notes = []
    if p.exists():
        try:
            notes = __import__("json").loads(p.read_text(encoding="utf-8"))
        except Exception:
            notes = []
    notes.append(text)
    p.write_text(__import__("json").dumps(notes, indent=2), encoding="utf-8")
    return f"saved note #{len(notes)}: {text!r}"


@tool
def read_notes() -> str:
    """Return all saved notes, newest last."""
    p = _notes_path()
    if not p.exists():
        return "(no notes yet)"
    try:
        notes = __import__("json").loads(p.read_text(encoding="utf-8"))
    except Exception:
        return "(notes file unreadable)"
    return "\n".join(f"{i+1}. {n}" for i, n in enumerate(notes)) or "(no notes yet)"


ALL_TOOLS = [calculator, get_time, save_note, read_notes]
