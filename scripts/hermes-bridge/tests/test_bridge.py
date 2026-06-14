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
