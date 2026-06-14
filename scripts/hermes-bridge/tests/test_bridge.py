import sys, pathlib
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
import bridge
import shutil, subprocess, sqlite3, os

LIVE_DB = os.path.expanduser("~/.hermes/mnemosyne/data/mnemosyne.db")
VENV_PY = os.path.expanduser("~/.hermes/hermes-agent/venv/bin/python")


def _copy_db(tmp_path):
    """Copy live DB into tmp_path/mnemosyne.db; return the directory path."""
    dst = tmp_path / "mnemosyne.db"
    shutil.copy(LIVE_DB, dst)
    return str(tmp_path)

def test_parse_memory_splits_frontmatter(tmp_path):
    f = tmp_path / "feedback_example.md"
    f.write_text(
        "---\n"
        "name: feedback-example\n"
        "description: a one-line summary\n"
        "metadata:\n  type: feedback\n"
        "---\n\n"
        "The actual fact body.\n"
    )
    m = bridge.parse_memory(f)
    assert m.slug == "feedback_example"      # slug derives from filename stem
    assert m.description == "a one-line summary"
    assert m.mtype == "feedback"
    assert m.body.strip() == "The actual fact body."


def test_select_excludes_manifest_and_index(tmp_path):
    memdir = tmp_path / "mem"; memdir.mkdir()
    for name in ["feedback_keep", "check_sprint_number_first", "MEMORY"]:
        (memdir / f"{name}.md").write_text(
            "---\nname: x\ndescription: d\nmetadata:\n  type: feedback\n---\nbody\n")
    manifest = {"exclude": ["check_sprint_number_first"], "soul": []}
    slugs = sorted(m.slug for m in bridge.select_memories(memdir, manifest))
    assert slugs == ["feedback_keep"]          # MEMORY.md skipped, excluded skipped


def test_store_then_find_by_slug(tmp_path):
    data_dir = _copy_db(tmp_path)
    adapter = bridge.Mnemosyne(data_dir=data_dir, venv_py=VENV_PY)
    rid = adapter.store(slug="probe-slug", content="probe body alpha", importance=0.6)
    assert rid                                   # got an id back
    found = adapter.find_by_slug("probe-slug")
    assert found and found["id"] == rid
    assert found["source"] == bridge.SOURCE_PREFIX + "probe-slug"
    assert found["author_type"] == "claude-code"  # stamped
    assert found["scope"] == "global"


def _count_inherit(data_dir):
    db = os.path.join(data_dir, "mnemosyne.db")
    with sqlite3.connect(db) as cx:
        return cx.execute("SELECT count(*) FROM working_memory "
                          "WHERE source LIKE 'claude-inherit:%' AND superseded_by IS NULL").fetchone()[0]


def _write_mem(memdir, slug, body):
    (memdir / f"{slug}.md").write_text(
        f"---\nname: {slug}\ndescription: d\nmetadata:\n  type: feedback\n---\n{body}\n")


def test_sync_idempotent(tmp_path):
    data_dir = _copy_db(tmp_path)
    memdir = tmp_path / "mem"; memdir.mkdir()
    _write_mem(memdir, "feedback_a", "body one")
    adapter = bridge.Mnemosyne(data_dir=data_dir, venv_py=VENV_PY)
    bridge.sync(memdir, {"exclude": [], "soul": []}, adapter)
    first = _count_inherit(data_dir)
    bridge.sync(memdir, {"exclude": [], "soul": []}, adapter)   # run again
    assert _count_inherit(data_dir) == first                    # no duplicates


def test_sync_supersedes_on_change(tmp_path):
    data_dir = _copy_db(tmp_path)
    memdir = tmp_path / "mem"; memdir.mkdir()
    _write_mem(memdir, "feedback_a", "body one")
    adapter = bridge.Mnemosyne(data_dir=data_dir, venv_py=VENV_PY)
    bridge.sync(memdir, {"exclude": [], "soul": []}, adapter)
    _write_mem(memdir, "feedback_a", "body two CHANGED")
    bridge.sync(memdir, {"exclude": [], "soul": []}, adapter)
    live = adapter.find_by_slug("feedback_a")
    assert "CHANGED" in live["content"]                         # newest wins
    assert _count_inherit(data_dir) == 1                        # old superseded, not duplicated


def test_sync_never_touches_hermes_rows(tmp_path):
    data_dir = _copy_db(tmp_path)
    db = os.path.join(data_dir, "mnemosyne.db")
    with sqlite3.connect(db) as cx:
        before = cx.execute("SELECT count(*), coalesce(sum(length(content)),0) FROM working_memory "
                            "WHERE source IS NULL OR source NOT LIKE 'claude-inherit:%'").fetchone()
    memdir = tmp_path / "mem"; memdir.mkdir()
    _write_mem(memdir, "feedback_a", "body one")
    bridge.sync(memdir, {"exclude": [], "soul": []}, bridge.Mnemosyne(data_dir=data_dir, venv_py=VENV_PY))
    with sqlite3.connect(db) as cx:
        after = cx.execute("SELECT count(*), coalesce(sum(length(content)),0) FROM working_memory "
                          "WHERE source IS NULL OR source NOT LIKE 'claude-inherit:%'").fetchone()
    assert before == after                                      # Hermes-authored rows byte-stable


def test_sync_recallable(tmp_path):
    data_dir = _copy_db(tmp_path)
    memdir = tmp_path / "mem"; memdir.mkdir()
    _write_mem(memdir, "feedback_uniqueword", "zticonium is the magic token")
    adapter = bridge.Mnemosyne(data_dir=data_dir, venv_py=VENV_PY)
    bridge.sync(memdir, {"exclude": [], "soul": []}, adapter)
    assert "zticonium" in adapter._cli("recall", "zticonium", "3")
