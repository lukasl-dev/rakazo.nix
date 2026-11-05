import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parent.parent / ".github" / "scripts" / "publish-update.sh"


class PublicationTests(unittest.TestCase):
    temporary: tempfile.TemporaryDirectory[str]
    repo: Path
    remote: Path
    base: str

    def run_command(self, *args: str, check: bool = True, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
        return subprocess.run(args, cwd=self.repo, env=env, text=True, capture_output=True, check=check)

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="rakazo-publish-")
        self.addCleanup(self.temporary.cleanup)
        root = Path(self.temporary.name)
        self.repo = root / "checkout"
        self.remote = root / "origin.git"
        self.repo.mkdir()
        _ = self.run_command("git", "init", "--bare", str(self.remote))
        _ = self.run_command("git", "init", "-b", "main")
        _ = self.run_command("git", "config", "user.name", "Test")
        _ = self.run_command("git", "config", "user.email", "test@example.invalid")
        self.metadata("0.7.0")
        _ = self.run_command("git", "add", "VERSION.json")
        _ = self.run_command("git", "commit", "-m", "Initial fixture")
        _ = self.run_command("git", "remote", "add", "origin", str(self.remote))
        _ = self.run_command("git", "push", "origin", "HEAD:main")
        self.base = self.run_command("git", "rev-parse", "HEAD").stdout.strip()

    def metadata(self, version: str) -> None:
        _ = (self.repo / "VERSION.json").write_text(json.dumps({"version": version}) + "\n")

    def publish(self, action: str = "publish") -> subprocess.CompletedProcess[str]:
        env = os.environ.copy()
        env.update(BASE=self.base, BRANCH="main")
        return self.run_command("bash", str(SCRIPT), action, check=False, env=env)

    def test_publish_and_tag(self) -> None:
        self.metadata("0.8.0")
        result = self.publish()
        self.assertEqual(result.returncode, 0, result.stderr)
        head = self.run_command("git", "rev-parse", "HEAD").stdout.strip()
        self.assertEqual(self.run_command("git", "rev-parse", "HEAD^").stdout.strip(), self.base)
        self.assertIn(head, self.run_command("git", "ls-remote", "origin", "refs/heads/main").stdout)
        self.assertIn(head, self.run_command("git", "ls-remote", "origin", "refs/tags/v0.8.0^{}").stdout)

    def test_no_change(self) -> None:
        self.assertEqual(self.publish().returncode, 0)
        self.assertEqual(self.run_command("git", "rev-parse", "HEAD").stdout.strip(), self.base)

    def test_unexpected_file(self) -> None:
        self.metadata("0.8.0")
        _ = (self.repo / "unexpected\nfile").write_text("not metadata")
        self.assertNotEqual(self.publish("check").returncode, 0)
        self.assertEqual(self.run_command("git", "rev-parse", "HEAD").stdout.strip(), self.base)

    def test_changed_local_head(self) -> None:
        _ = self.run_command("git", "commit", "--allow-empty", "-m", "Concurrent local change")
        self.metadata("0.8.0")
        self.assertNotEqual(self.publish().returncode, 0)
        self.assertIn(self.base, self.run_command("git", "ls-remote", "origin", "refs/heads/main").stdout)

    def test_remote_moved(self) -> None:
        _ = self.run_command("git", "commit", "--allow-empty", "-m", "Concurrent remote change")
        newer = self.run_command("git", "rev-parse", "HEAD").stdout.strip()
        _ = self.run_command("git", "push", "origin", "HEAD:main")
        _ = self.run_command("git", "reset", "--hard", self.base)
        self.metadata("0.8.0")
        self.assertNotEqual(self.publish().returncode, 0)
        self.assertIn(newer, self.run_command("git", "ls-remote", "origin", "refs/heads/main").stdout)


if __name__ == "__main__":
    unittest.main()
