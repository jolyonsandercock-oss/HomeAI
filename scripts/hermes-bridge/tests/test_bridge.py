import sys, pathlib
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
import bridge

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
