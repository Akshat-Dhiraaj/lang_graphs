import os
import pathlib
import datetime

os.environ.setdefault("POCKET_NOTES_PATH",
                      str(pathlib.Path(".build_tmp") / "test_notes.json"))
pathlib.Path(".build_tmp").mkdir(exist_ok=True)

from pocket_agent.tools import calculator, get_time, save_note, read_notes


def test_calculator_mul():
    assert calculator.invoke({"expression": "47 * 89"}) == "4183"


def test_calculator_div():
    assert calculator.invoke({"expression": "10 / 4"}) == "2.5"


def test_calculator_rejects_code():
    assert calculator.invoke({"expression": "__import__('os')"}).startswith("error")


def test_get_time_is_iso():
    datetime.datetime.fromisoformat(get_time.invoke({}))


def test_notes_roundtrip():
    p = pathlib.Path(os.environ["POCKET_NOTES_PATH"])
    if p.exists():
        p.unlink()
    save_note.invoke({"text": "alpha"})
    save_note.invoke({"text": "beta"})
    out = read_notes.invoke({})
    assert "alpha" in out and "beta" in out
