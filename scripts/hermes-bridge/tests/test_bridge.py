import sys, pathlib
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
import bridge
import soul_block
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
    assert "probe body alpha" in found["content"]


def _count_inherit(data_dir):
    import os, sqlite3
    with sqlite3.connect(os.path.join(data_dir, "mnemosyne.db")) as cx:
        return cx.execute("SELECT count(*) FROM memories WHERE source LIKE 'claude-inherit:%'").fetchone()[0]


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
    assert _count_inherit(data_dir) == 1                        # old hard-deleted, not duplicated


def test_sync_idempotent_across_consolidation(tmp_path):
    data_dir = _copy_db(tmp_path)
    memdir = tmp_path / "mem"; memdir.mkdir()
    _write_mem(memdir, "feedback_a", "body one")
    adapter = bridge.Mnemosyne(data_dir=data_dir, venv_py=VENV_PY)
    bridge.sync(memdir, {"exclude": [], "soul": []}, adapter)
    first = _count_inherit(data_dir)
    # simulate mnemosyne consolidation emptying the transient buffer
    import os, sqlite3
    with sqlite3.connect(os.path.join(data_dir, "mnemosyne.db")) as cx:
        cx.execute("DELETE FROM working_memory")
    bridge.sync(memdir, {"exclude": [], "soul": []}, adapter)   # must NOT duplicate
    assert _count_inherit(data_dir) == first == 1


def test_sync_never_touches_hermes_rows(tmp_path):
    data_dir = _copy_db(tmp_path)
    db = os.path.join(data_dir, "mnemosyne.db")
    with sqlite3.connect(db) as cx:
        before = cx.execute("SELECT count(*), coalesce(sum(length(content)),0) FROM memories "
                            "WHERE source IS NULL OR source NOT LIKE 'claude-inherit:%'").fetchone()
    memdir = tmp_path / "mem"; memdir.mkdir()
    _write_mem(memdir, "feedback_a", "body one")
    bridge.sync(memdir, {"exclude": [], "soul": []}, bridge.Mnemosyne(data_dir=data_dir, venv_py=VENV_PY))
    with sqlite3.connect(db) as cx:
        after = cx.execute("SELECT count(*), coalesce(sum(length(content)),0) FROM memories "
                          "WHERE source IS NULL OR source NOT LIKE 'claude-inherit:%'").fetchone()
    assert before == after                                      # Hermes-authored rows byte-stable


def test_sync_recallable(tmp_path):
    data_dir = _copy_db(tmp_path)
    memdir = tmp_path / "mem"; memdir.mkdir()
    _write_mem(memdir, "feedback_uniqueword", "zticonium is the magic token")
    adapter = bridge.Mnemosyne(data_dir=data_dir, venv_py=VENV_PY)
    bridge.sync(memdir, {"exclude": [], "soul": []}, adapter)
    assert "zticonium" in adapter._cli("recall", "zticonium", "3")


def test_sync_prunes_deselected(tmp_path):
    data_dir = _copy_db(tmp_path)
    memdir = tmp_path / "mem"; memdir.mkdir()
    _write_mem(memdir, "feedback_a", "body one")
    _write_mem(memdir, "feedback_b", "body two")
    adapter = bridge.Mnemosyne(data_dir=data_dir, venv_py=VENV_PY)
    bridge.sync(memdir, {"exclude": [], "soul": []}, adapter)
    assert _count_inherit(data_dir) == 2
    # now exclude feedback_b → it must be pruned from mnemosyne
    stats = bridge.sync(memdir, {"exclude": ["feedback_b"], "soul": []}, adapter)
    assert stats["pruned"] == 1
    assert _count_inherit(data_dir) == 1
    assert adapter.find_by_slug("feedback_b") is None
    assert adapter.find_by_slug("feedback_a") is not None


def test_soul_block_is_idempotent(tmp_path):
    soul = tmp_path / "SOUL.md"
    soul.write_text("# Hermes\n\nExisting contract.\n")
    soul_block.upsert_culture_block(soul)
    once = soul.read_text()
    soul_block.upsert_culture_block(soul)          # run again
    twice = soul.read_text()
    assert once == twice                           # block written exactly once
    assert "Build & working discipline (inherited from Claude Code)" in once
    assert "verify before declaring done" in once.lower()
    assert "Existing contract." in once            # original preserved


def test_sync_update_path_survives_store_dedup(tmp_path):
    """Regression: mnemosyne store() dedups by content. If stored content drifts
    from source (sanitisation) the bridge takes the update path; store() then
    dedups the re-sent content to the SAME id. Deleting that id would destroy the
    memory. The id-guard must treat this as unchanged, not delete it."""
    import os, sqlite3
    data_dir = _copy_db(tmp_path)
    memdir = tmp_path / "mem"; memdir.mkdir()
    _write_mem(memdir, "feedback_a", "body one survives")
    adapter = bridge.Mnemosyne(data_dir=data_dir, venv_py=VENV_PY)
    bridge.sync(memdir, {"exclude": [], "soul": []}, adapter)
    assert _count_inherit(data_dir) == 1
    # simulate mnemosyne having sanitised the stored content (so the bridge sees
    # "changed") while store() will still dedup the original re-sent content
    with sqlite3.connect(os.path.join(data_dir, "mnemosyne.db")) as cx:
        cx.execute("UPDATE memories SET content = content || ' [sanitised]' "
                   "WHERE source LIKE 'claude-inherit:%'")
    stats = bridge.sync(memdir, {"exclude": [], "soul": []}, adapter)
    assert _count_inherit(data_dir) == 1            # NOT deleted
    assert adapter.find_by_slug("feedback_a") is not None
    assert stats["updated"] == 0                    # dedup → treated as unchanged
