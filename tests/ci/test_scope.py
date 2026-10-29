import os
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "scripts"))
import ci_scope  # noqa: E402


class Repo:
    def __init__(self, path):
        self.path = path
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.email", "t@example.com")
        self.git("config", "user.name", "t")
        self.git("config", "commit.gpgsign", "false")

    def git(self, *args):
        return subprocess.run(
            ["git", "-C", self.path, *args], check=True, capture_output=True, text=True
        ).stdout.strip()

    def commit(self, files=None, remove=(), move=None):
        for name, text in (files or {}).items():
            full = os.path.join(self.path, name)
            os.makedirs(os.path.dirname(full), exist_ok=True)
            with open(full, "w") as handle:
                handle.write(text)
        for name in remove:
            self.git("rm", "-q", name)
        if move:
            os.makedirs(os.path.dirname(os.path.join(self.path, move[1])), exist_ok=True)
            self.git("mv", move[0], move[1])
        self.git("add", "-A")
        self.git("commit", "-q", "--allow-empty", "-m", "c")
        return self.git("rev-parse", "HEAD")


def run(sha, event="push", conclusion="success"):
    return {"head_sha": sha, "event": event, "conclusion": conclusion}


class ScopeTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.repo = Repo(self._tmp.name)
        self.base = self.repo.commit(
            {"src/lib.rs": "a", "docs/a.md": "a", "README.md": "r"}
        )

    def decide(self, head, runs, event="push", ref=""):
        return ci_scope.decide(self.repo.path, event, ref, head, runs)[0]

    def test_docs_only_skips(self):
        head = self.repo.commit({"docs/b.md": "b", "docs/a.md": "changed"})
        self.assertFalse(self.decide(head, [run(self.base)]))

    def test_pull_request_docs_only_skips(self):
        head = self.repo.commit({"docs/b.md": "b"})
        self.assertFalse(self.decide(head, [run(self.base)], event="pull_request"))

    def test_docs_deletion_skips(self):
        head = self.repo.commit(remove=["docs/a.md"])
        self.assertFalse(self.decide(head, [run(self.base)]))

    def test_mixed_runs_full(self):
        head = self.repo.commit({"docs/b.md": "b", "src/lib.rs": "new"})
        self.assertTrue(self.decide(head, [run(self.base)]))

    def test_root_file_runs_full(self):
        head = self.repo.commit({"README.md": "new", "docs/b.md": "b"})
        self.assertTrue(self.decide(head, [run(self.base)]))

    def test_docs_to_code_rename_runs_full(self):
        head = self.repo.commit(move=("docs/a.md", "src/a.md"))
        self.assertTrue(self.decide(head, [run(self.base)]))

    def test_code_to_docs_rename_runs_full(self):
        head = self.repo.commit(move=("src/lib.rs", "docs/lib.rs"))
        self.assertTrue(self.decide(head, [run(self.base)]))

    def test_no_change_runs_full(self):
        self.assertTrue(self.decide(self.base, [run(self.base)]))

    def test_non_ancestor_baseline_runs_full(self):
        self.repo.git("checkout", "-q", "-b", "other")
        other = self.repo.commit({"docs/x.md": "x"})
        self.repo.git("checkout", "-q", "main")
        head = self.repo.commit({"docs/b.md": "b"})
        self.assertTrue(self.decide(head, [run(other)]))

    def test_missing_baseline_object_runs_full(self):
        head = self.repo.commit({"docs/b.md": "b"})
        self.assertTrue(self.decide(head, [run("f" * 40)]))

    def test_no_runs_or_api_failure_runs_full(self):
        head = self.repo.commit({"docs/b.md": "b"})
        self.assertTrue(self.decide(head, []))
        self.assertTrue(self.decide(head, None))
        self.assertTrue(self.decide(head, "garbage"))
        self.assertTrue(self.decide(head, [None, {"head_sha": 3}]))

    def test_unsuccessful_or_non_push_runs_filtered(self):
        head = self.repo.commit({"docs/b.md": "b"})
        for bad in (
            run(self.base, conclusion="failure"),
            run(self.base, conclusion=None),
            run(self.base, conclusion="skipped"),
            run(self.base, event="pull_request"),
            run(self.base[:10]),
        ):
            self.assertTrue(self.decide(head, [bad]), bad)

    def test_valid_run_found_after_filtered_ones(self):
        head = self.repo.commit({"docs/b.md": "b"})
        runs = [run(self.base, conclusion="failure"), run(self.base)]
        self.assertFalse(self.decide(head, runs))

    def test_unvalidated_code_change_runs_full(self):
        unvalidated = self.repo.commit({"src/lib.rs": "new"})
        head = self.repo.commit({"docs/b.md": "b"})
        self.assertTrue(self.decide(head, [run(self.base, conclusion="failure")]))
        self.assertFalse(self.decide(head, [run(unvalidated)]))

    def test_pr_merge_with_new_base_code_runs_full(self):
        self.repo.git("checkout", "-q", "-b", "pr")
        pr_head = self.repo.commit({"docs/pr.md": "p"})
        self.repo.git("checkout", "-q", "main")
        self.repo.commit({"src/lib.rs": "base moved"})
        self.repo.git("merge", "-q", "--no-ff", "-m", "merge", "pr")
        merge = self.repo.git("rev-parse", "HEAD")
        self.assertTrue(self.decide(merge, [run(self.base)], event="pull_request"))
        self.assertNotEqual(merge, pr_head)

    def test_forced_full_runs(self):
        head = self.repo.commit({"docs/b.md": "b"})
        runs = [run(self.base)]
        self.assertTrue(self.decide(head, runs, ref="task/upstream-candidate"))
        self.assertTrue(self.decide(head, runs, event="workflow_dispatch"))
        self.assertTrue(self.decide(head, runs, event="workflow_call"))
        self.assertTrue(self.decide(head, runs, event="schedule"))
        self.assertTrue(self.decide(head, runs, event=""))


if __name__ == "__main__":
    unittest.main()
