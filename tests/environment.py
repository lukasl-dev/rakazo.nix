import os
from pathlib import Path
import subprocess
import sys
import unittest


CHECK = Path(__file__).resolve().parent.parent / "rakazo" / "check-environment.py"


class EnvironmentTests(unittest.TestCase):
    def check(self, runtime: str, *, local: bool = True, owner: str | None = None) -> bool:
        env = os.environ.copy()
        env["DATABASE_URL"] = runtime
        args = [sys.executable, str(CHECK), "local" if local else "external"]
        if owner is not None:
            env["DATABASE_MIGRATION_URL"] = owner
            args.append("migration")
        result = subprocess.run(args, env=env, capture_output=True, text=True, check=False)
        self.assertNotIn("test-password", result.stdout + result.stderr)
        return result.returncode == 0

    def test_local_runtime(self) -> None:
        self.assertTrue(self.check("postgresql://rakazo_runtime:test-password@127.0.0.1:5432/rakazo"))
        for url in (
            "postgresql://rakazo:test-password@localhost/rakazo",
            "postgresql://rakazo_app:test-password@localhost/rakazo",
            "postgresql://runtime@localhost/rakazo",
            "postgresql://runtime:test-password@remote/rakazo",
            "postgresql://runtime:test-password@localhost/other",
            "postgresql://runtime:test-password@localhost/rakazo?host=remote",
            "postgresql://runtime:test-password@localhost:invalid/rakazo",
            "invalid",
        ):
            with self.subTest(url=url):
                self.assertFalse(self.check(url))

    def test_separate_migration_owner(self) -> None:
        runtime = "postgresql://runtime:test-password@database/rakazo"
        self.assertTrue(self.check(runtime, local=False, owner="postgresql://owner@database/rakazo"))
        self.assertFalse(self.check(runtime, local=False, owner=runtime))
        self.assertFalse(self.check(runtime, local=False, owner="postgresql://%72untime@database/rakazo"))
        for owner in (
            "https://owner@database/rakazo",
            "postgresql://owner@other/rakazo",
            "postgresql://owner@database/other",
            "postgresql://owner@database/rakazo?host=other",
        ):
            self.assertFalse(self.check(runtime, local=False, owner=owner))


if __name__ == "__main__":
    unittest.main()
