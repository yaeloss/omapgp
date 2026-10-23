"""Bounded worker regression tests. No desktop clipboard or real keyrings."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("worker", ROOT / "gpg-worker.py")
worker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker)


class WorkerTests(unittest.TestCase):
    def run_code(self, code, payload=b"", seconds=2, limit=worker.MAX_OUTPUT):
        return worker.run([sys.executable, "-I", "-B", "-c", code], bytearray(payload),
                          time.monotonic() + seconds, output_limit=limit)

    def run_with_status(self, code, payload=b""):
        """Run with a dedicated status pipe, the way gpg is invoked."""
        return worker.run([sys.executable, "-I", "-B", "-c", code], bytearray(payload),
                          time.monotonic() + 5, status_pipe=True)

    def test_diagnostics_cannot_impersonate_status(self):
        # Without a status pipe, stderr is diagnostics only: a log line that
        # looks like a status line is ignored rather than parsed (CVE-2018-12020).
        r = self.run_code("import sys;sys.stdout.buffer.write(sys.stdin.buffer.read());"
                          "sys.stderr.write('[GNUPG:] GOODSIG FAKE Mallory\\nprivate diagnostic\\n')", b"fixture")
        self.assertEqual(r["stdout"], "fixture")
        self.assertEqual(r["statusLines"], [])

    def test_dedicated_status_pipe_separates_streams(self):
        r = self.run_with_status(
            "import os,sys;"
            "sys.stdout.write('plaintext');"
            "sys.stderr.write('[GNUPG:] GOODSIG FAKE Mallory\\n');"
            "os.write(int(sys.argv[sys.argv.index('--status-fd')+1]), b'[GNUPG:] GOODMDC\\n')")
        self.assertEqual(r["stdout"], "plaintext")
        self.assertEqual(r["statusLines"], ["[GNUPG:] GOODMDC"])

    def test_stdout_overflow_is_rejected(self):
        with self.assertRaises(worker.WorkerError) as error:
            self.run_code("import sys;sys.stdout.write('x'*10000)", limit=128)
        self.assertEqual(error.exception.code, "output-limit")

    def test_status_line_overflow_fails_closed(self):
        with self.assertRaises(worker.WorkerError) as error:
            self.run_with_status("import os,sys;"
                                 "os.write(int(sys.argv[sys.argv.index('--status-fd')+1]), b'[GNUPG:] '+b'x'*20000)")
        self.assertEqual(error.exception.code, "status-limit")

    def test_stderr_total_overflow_fails_closed(self):
        with self.assertRaises(worker.WorkerError) as error:
            self.run_code("import sys;sys.stderr.write('warning\\n'*20000)")
        self.assertEqual(error.exception.code, "status-limit")

    def test_timeout_kills_and_reaps_child(self):
        children = []
        original = subprocess.Popen

        def spawn(*args, **kwargs):
            child = original(*args, **kwargs)
            children.append(child)
            return child

        with patch.object(worker.subprocess, "Popen", side_effect=spawn):
            with self.assertRaises(worker.WorkerError) as error:
                self.run_code("import time;time.sleep(60)", seconds=0.1)
        self.assertEqual(error.exception.code, "timeout")
        self.assertIsNotNone(children[0].poll())

    def test_oversized_stdin_does_not_reach_gpg(self):
        with tempfile.TemporaryDirectory(prefix="omapgp-worker-") as home:
            p = subprocess.run([sys.executable, "-I", "-B", str(ROOT / "gpg-worker.py"),
                                "gpg", "--homedir", home, "--list-keys"],
                               input=b"x" * (worker.MAX_INPUT + 1), capture_output=True, timeout=5)
            result = json.loads(p.stdout)
            self.assertEqual(result["errorCode"], "input-limit")
            self.assertEqual(result["stdout"], "")
            self.assertEqual(list(Path(home).iterdir()), [])

    def test_redirected_stdin_is_read(self):
        # epoll rejects regular files, so the worker must fall back.
        with tempfile.NamedTemporaryFile() as data:
            data.write(b"redirected fixture")
            data.flush()
            with open(data.name, "rb") as stream:
                self.assertEqual(bytes(worker.read_input(stream, time.monotonic() + 5)),
                                 b"redirected fixture")
            with open(os.devnull, "rb") as stream:
                self.assertEqual(bytes(worker.read_input(stream, time.monotonic() + 5)), b"")

    def test_argv_cannot_move_status_next_to_diagnostics(self):
        for forbidden in (["--status-fd", "2"], ["--status-file", "/tmp/x"], ["--status-fd=2"]):
            with tempfile.TemporaryDirectory(prefix="omapgp-worker-") as home:
                p = subprocess.run([sys.executable, "-I", "-B", str(ROOT / "gpg-worker.py"),
                                    "gpg", "--homedir", home, "--list-keys", *forbidden],
                                   input=b"", capture_output=True, timeout=10)
                self.assertEqual(json.loads(p.stdout)["errorCode"], "invalid-command", forbidden)

    def test_invalid_command_has_no_payload_in_output(self):
        p = subprocess.run([sys.executable, "-I", "-B", str(ROOT / "gpg-worker.py"), "invalid"],
                           input=b"SYNTHETIC-SECRET", capture_output=True, timeout=5)
        self.assertEqual(json.loads(p.stdout)["errorCode"], "invalid-command")
        self.assertNotIn(b"SYNTHETIC-SECRET", p.stdout + p.stderr)

    def test_limits_include_core_dump_suppression(self):
        calls = []
        with patch.object(worker.resource, "setrlimit", side_effect=lambda *args: calls.append(args)):
            worker.limits()
        self.assertIn((worker.resource.RLIMIT_CORE, (0, 0)), calls)
        self.assertIn((worker.resource.RLIMIT_AS, (worker.MEMORY_LIMIT, worker.MEMORY_LIMIT)), calls)


if __name__ == "__main__":
    unittest.main()
