"""Tests for kaggle-hub. No network: the Kaggle CLI is replaced by a fake."""

import importlib.machinery
import importlib.util
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest import mock

HUB = str(Path(__file__).resolve().parent.parent / "kaggle-hub")

# The fake CLI answers from files in $FAKE_KAGGLE_DIR:
#   list.out / list.err / list.rc            for `kernels list ...`
#   status_<owner>__<slug>.out / .err / .rc  for `kernels status owner/slug`
# and appends every invocation to calls.log.
FAKE_CLI = r'''
import os, sys
d = os.environ["FAKE_KAGGLE_DIR"]
args = sys.argv[1:]
with open(os.path.join(d, "calls.log"), "a") as log:
    log.write(" ".join(args) + "\n")
if args[:2] == ["kernels", "list"]:
    name = "list"
elif args[:2] == ["kernels", "status"] and len(args) == 3:
    name = "status_" + args[2].replace("/", "__")
else:
    sys.stderr.write("fake kaggle: unexpected arguments\n")
    sys.exit(64)

def read(suffix):
    try:
        with open(os.path.join(d, name + suffix)) as handle:
            return handle.read()
    except FileNotFoundError:
        return ""

sys.stdout.write(read(".out"))
sys.stderr.write(read(".err"))
code = read(".rc").strip()
sys.exit(int(code) if code else 0)
'''

LISTED_FORMAT = "%Y-%m-%d %H:%M:%S.%f"


def hours_ago(hours):
    return datetime.now(timezone.utc) - timedelta(hours=hours)


def listed(moment):
    return moment.strftime(LISTED_FORMAT)


def to_epoch(text):
    return datetime.fromisoformat(text).replace(tzinfo=timezone.utc).timestamp()


class HubTestCase(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        root = Path(self._tmp.name)
        self.fake_dir = root / "fake"
        self.state_dir = root / "state"
        bin_dir = root / "bin"
        for path in (self.fake_dir, bin_dir):
            path.mkdir()
        (bin_dir / "fake_kaggle.py").write_text(FAKE_CLI)
        self.kaggle = bin_dir / "kaggle"
        self.kaggle.write_text(
            f'#!/bin/sh\nexec "{sys.executable}" "{bin_dir / "fake_kaggle.py"}" "$@"\n'
        )
        self.kaggle.chmod(0o755)
        self.env = dict(os.environ)
        self.env.update({
            "KAGGLE_CLI_PATH": str(self.kaggle),
            "KAGGLE_HUB_STATE_DIR": str(self.state_dir),
            "KAGGLE_HUB_MIN_INTERVAL": "0",
            "KAGGLE_HUB_NO_NOTIFY": "1",
            "FAKE_KAGGLE_DIR": str(self.fake_dir),
        })

    # -- fake CLI control --

    def write(self, name, text):
        (self.fake_dir / name).write_text(text)

    def set_list(self, rows, before="", after=""):
        payload = [
            {"ref": ref, "title": title, "lastRunTime": last_run}
            for ref, title, last_run in rows
        ]
        self.write("list.out", before + json.dumps(payload, indent=1) + after)

    def set_status(self, ref, status):
        name = "status_" + ref.replace("/", "__")
        self.write(name + ".out", f'{ref} has status "KernelWorkerStatus.{status}"\n')

    def calls(self):
        try:
            return (self.fake_dir / "calls.log").read_text().splitlines()
        except FileNotFoundError:
            return []

    def status_calls(self, ref):
        return [c for c in self.calls() if c == f"kernels status {ref}"]

    # -- running the hub --

    def run_hub(self, *args, env=None):
        return subprocess.run(
            [sys.executable, HUB, *args],
            capture_output=True, text=True, env=env or self.env, timeout=60,
        )

    def snapshot(self):
        proc = self.run_hub("monitor-snapshot")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stderr, "")
        self.assertEqual(proc.stdout.count("\n"), 1, "stdout must be one line")
        return json.loads(proc.stdout)

    def failing_snapshot(self):
        proc = self.run_hub("monitor-snapshot")
        self.assertEqual(proc.returncode, 2)
        self.assertEqual(proc.stdout, "")
        self.assertRegex(proc.stderr, r"^kaggle-hub: [^\n]+\n$")
        return proc.stderr


class SnapshotTests(HubTestCase):
    def test_shape_and_content(self):
        running, queued, complete = hours_ago(1), hours_ago(0.5), hours_ago(3)
        self.set_list([
            ("alice/running-nb", "Running notebook", listed(running)),
            ("alice/queued-nb", "Queued notebook", listed(queued)),
            ("alice/done-nb", "Done notebook", listed(complete)),
        ])
        self.set_status("alice/running-nb", "RUNNING")
        self.set_status("alice/queued-nb", "QUEUED")
        self.set_status("alice/done-nb", "COMPLETE")

        before = datetime.now(timezone.utc).timestamp()
        result = self.snapshot()

        self.assertEqual(
            set(result), {"activeRuns", "notebooksChecked", "unavailableCount", "checkedAt"}
        )
        self.assertIsInstance(result["notebooksChecked"], int)
        self.assertEqual(result["notebooksChecked"], 3)
        self.assertEqual(result["unavailableCount"], 0)
        self.assertIsInstance(result["checkedAt"], float)
        self.assertGreaterEqual(result["checkedAt"], before - 1)

        runs = {run["ref"]: run for run in result["activeRuns"]}
        self.assertEqual(set(runs), {"alice/running-nb", "alice/queued-nb"})
        for run in runs.values():
            self.assertEqual(set(run), {"ref", "title", "status", "lastRunAt", "project", "accelerator"})
            self.assertRegex(run["lastRunAt"], r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{6}$")
            self.assertIsNone(run["project"])
            self.assertIsNone(run["accelerator"])
        self.assertEqual(runs["alice/running-nb"]["status"], "RUNNING")
        self.assertEqual(runs["alice/running-nb"]["title"], "Running notebook")
        self.assertEqual(runs["alice/queued-nb"]["status"], "QUEUED")
        self.assertEqual(
            runs["alice/running-nb"]["lastRunAt"], running.strftime("%Y-%m-%dT%H:%M:%S.%f")
        )

    def test_list_command_line(self):
        self.set_list([])
        self.snapshot()
        self.assertEqual(
            self.calls(),
            ["kernels list --mine --sort-by dateRun --page-size 100 --format json"],
        )

    def test_empty_and_not_found_lists_are_idle(self):
        for text in ("", "Not found\n", "[]"):
            with self.subTest(text=text):
                self.write("list.out", text)
                result = self.snapshot()
                self.assertEqual(result["activeRuns"], [])
                self.assertEqual(result["notebooksChecked"], 0)

    def test_finished_notebook_is_not_rechecked(self):
        self.set_list([
            ("alice/running-nb", "R", listed(hours_ago(1))),
            ("alice/done-nb", "D", listed(hours_ago(3))),
        ])
        self.set_status("alice/running-nb", "RUNNING")
        self.set_status("alice/done-nb", "COMPLETE")
        self.snapshot()
        second = self.snapshot()
        self.assertEqual(len(self.status_calls("alice/done-nb")), 1)
        self.assertEqual(len(self.status_calls("alice/running-nb")), 2)
        self.assertEqual([r["ref"] for r in second["activeRuns"]], ["alice/running-nb"])

    def test_changed_last_run_time_triggers_recheck(self):
        self.set_list([("alice/nb", "N", listed(hours_ago(5)))])
        self.set_status("alice/nb", "COMPLETE")
        self.assertEqual(self.snapshot()["activeRuns"], [])
        self.assertEqual(len(self.status_calls("alice/nb")), 1)

        self.snapshot()
        self.assertEqual(len(self.status_calls("alice/nb")), 1)

        self.set_list([("alice/nb", "N", listed(hours_ago(0.1)))])
        self.set_status("alice/nb", "RUNNING")
        result = self.snapshot()
        self.assertEqual(len(self.status_calls("alice/nb")), 2)
        self.assertEqual([r["status"] for r in result["activeRuns"]], ["RUNNING"])

    def test_repushed_running_notebook_with_old_listed_time_stays_checked(self):
        # A re-push keeps Kaggle's old lastRunTime; the hub saw it active an hour ago.
        old = listed(hours_ago(20))
        self.state_dir.mkdir(mode=0o700)
        now = datetime.now(timezone.utc).timestamp()
        (self.state_dir / "state.json").write_text(json.dumps({
            "notebooks": {"alice/repushed": {
                "status": "RUNNING", "checked_at": now - 60,
                "listed": old, "first_active": now - 3600,
            }},
            "tracked": {},
        }))
        self.set_list([("alice/repushed", "R", old)])
        self.set_status("alice/repushed", "RUNNING")
        result = self.snapshot()
        self.assertEqual(len(self.status_calls("alice/repushed")), 1)
        self.assertEqual([r["ref"] for r in result["activeRuns"]], ["alice/repushed"])
        started = to_epoch(result["activeRuns"][0]["lastRunAt"])
        self.assertAlmostEqual(started, now - 3600, delta=2)

    def test_old_notebook_is_never_checked(self):
        self.set_list([("alice/old", "O", listed(hours_ago(72)))])
        result = self.snapshot()
        self.assertEqual(result["activeRuns"], [])
        self.assertEqual(self.status_calls("alice/old"), [])

    def test_noise_around_list_json_is_tolerated(self):
        self.set_list(
            [("alice/nb", "N", listed(hours_ago(1)))],
            before="Warning: outdated client (server 1.7 / client 1.6)\n",
            after="\nDone.\n",
        )
        self.set_status("alice/nb", "RUNNING")
        self.assertEqual([r["ref"] for r in self.snapshot()["activeRuns"]], ["alice/nb"])

    def test_bracketed_noise_before_the_json_is_tolerated(self):
        self.set_list(
            [("alice/nb", "N", listed(hours_ago(1)))],
            before="[warn] something odd\n",
        )
        self.set_status("alice/nb", "RUNNING")
        self.assertEqual([r["ref"] for r in self.snapshot()["activeRuns"]], ["alice/nb"])

    def test_cancel_requested_is_running(self):
        self.set_list([("alice/nb", "N", listed(hours_ago(1)))])
        self.set_status("alice/nb", "CANCEL_REQUESTED")
        self.assertEqual([r["status"] for r in self.snapshot()["activeRuns"]], ["RUNNING"])

    def test_new_script_recent_is_queued(self):
        self.set_list([("alice/nb", "N", listed(hours_ago(0.2)))])
        self.set_status("alice/nb", "NEW_SCRIPT")
        result = self.snapshot()
        self.assertEqual([(r["ref"], r["status"]) for r in result["activeRuns"]],
                         [("alice/nb", "QUEUED")])

    def test_new_script_old_is_not_active(self):
        self.set_list([("alice/nb", "N", listed(hours_ago(5)))])
        self.set_status("alice/nb", "NEW_SCRIPT")
        result = self.snapshot()
        self.assertEqual(result["activeRuns"], [])
        self.assertEqual(result["notebooksChecked"], 1)

    def test_unavailable_notebook_is_counted_not_fatal(self):
        self.set_list([
            ("alice/gone", "G", listed(hours_ago(1))),
            ("alice/live", "L", listed(hours_ago(1))),
        ])
        self.write("status_alice__gone.err", "403 Client Error: Forbidden\n")
        self.write("status_alice__gone.rc", "1")
        self.set_status("alice/live", "RUNNING")
        result = self.snapshot()
        self.assertEqual(result["unavailableCount"], 1)
        self.assertEqual([r["ref"] for r in result["activeRuns"]], ["alice/live"])

    def test_unrecognized_status_is_an_error(self):
        self.set_list([("alice/nb", "N", listed(hours_ago(1)))])
        self.set_status("alice/nb", "SOMETHING_NEW")
        self.assertIn("SOMETHING_NEW", self.failing_snapshot())

    def test_list_with_only_unusable_rows_is_an_error(self):
        self.write("list.out", json.dumps([{"ref": "nonsense", "title": "x"}, {"title": "y"}]))
        self.failing_snapshot()

    def test_unusable_rows_are_skipped_and_counted(self):
        self.write("list.out", json.dumps([
            {"ref": "nonsense", "title": "x"},
            {"ref": "alice/nb", "title": "N", "lastRunTime": listed(hours_ago(1))},
        ]))
        self.set_status("alice/nb", "RUNNING")
        result = self.snapshot()
        self.assertEqual([r["ref"] for r in result["activeRuns"]], ["alice/nb"])
        self.assertEqual(result["unavailableCount"], 1)

    def test_missing_cli_is_reported(self):
        empty = Path(self._tmp.name) / "empty-path"
        empty.mkdir()
        env = dict(self.env, PATH=str(empty))
        del env["KAGGLE_CLI_PATH"]
        proc = self.run_hub("monitor-snapshot", env=env)
        self.assertEqual(proc.returncode, 2)
        self.assertEqual(
            proc.stderr,
            "kaggle-hub: The Kaggle CLI is not installed or is missing from PATH.\n",
        )


class ErrorMessageTests(HubTestCase):
    def fail_list_with(self, stderr, stdout=""):
        self.write("list.err", stderr)
        self.write("list.out", stdout)
        self.write("list.rc", "1")
        return self.failing_snapshot()

    def test_rate_limit_sets_cooldown_and_fails_fast(self):
        self.fail_list_with("HTTPError: 429 Client Error: Too Many Requests\n")
        self.assertEqual(len(self.calls()), 1)

        stderr = self.failing_snapshot()
        match = re.fullmatch(r"kaggle-hub: Kaggle rate limit: retry in (\d+) seconds\.\n", stderr)
        self.assertIsNotNone(match, stderr)
        self.assertTrue(0 < int(match.group(1)) <= 300)
        self.assertEqual(len(self.calls()), 1, "fail-fast must not call the CLI")

    def test_rate_limit_message_on_first_failure(self):
        stderr = self.fail_list_with("429 rate limit exceeded\n")
        self.assertRegex(stderr, r"^kaggle-hub: Kaggle rate limit: retry in \d+ seconds\.\n$")

    def test_traceback_message_comes_from_the_last_exception_line(self):
        long_frame = "/Users/someone/" + "very-long-directory/" * 12 + "site-packages/kaggle/api.py"
        traceback = (
            "Traceback (most recent call last):\n"
            f'  File "{long_frame}", line 1234, in kernels_list\n'
            "    response = self.process_response(self.kernels_list_with_http_info(**kwargs))\n"
            f'  File "{long_frame}", line 99, in request\n'
            "    raise ConnectionError(e)\n"
            "requests.exceptions.ConnectionError: Max retries exceeded\n"
        )
        stderr = self.fail_list_with(traceback)
        self.assertEqual(
            stderr, "kaggle-hub: requests.exceptions.ConnectionError: Max retries exceeded\n"
        )

    def test_traceback_without_exception_line_uses_last_other_line(self):
        stderr = self.fail_list_with(
            'Traceback (most recent call last):\n  File "/x/y.py", line 1, in <module>\n'
            "The connection dropped\n"
            '  File "/x/z.py", line 2, in <module>\n'
        )
        self.assertEqual(stderr, "kaggle-hub: The connection dropped\n")

    def test_only_traceback_lines_say_the_cli_crashed(self):
        stderr = self.fail_list_with(
            'Traceback (most recent call last):\n  File "/x/y.py", line 1, in <module>\n'
            "    return session.request(\n"
            "           ^^^^^^^^^^^^^^^^\n"
        )
        self.assertEqual(stderr, "kaggle-hub: The Kaggle CLI crashed without an error message.\n")

    def test_failure_without_output_falls_back_to_exit_status(self):
        stderr = self.fail_list_with("")
        self.assertEqual(stderr, "kaggle-hub: Kaggle CLI exited with status 1.\n")

    def test_message_is_capped_and_redacted(self):
        secret_line = (
            "ValueError: bad credentials Bearer abc123def KGAT_deadbeef01 "
            "api_key=hunter2 token: 's3cr3t' " + "x" * 400
        )
        stderr = self.fail_list_with(secret_line + "\n")
        for leaked in ("abc123def", "deadbeef01", "hunter2", "s3cr3t"):
            self.assertNotIn(leaked, stderr)
        self.assertIn("[redacted]", stderr)
        self.assertLessEqual(len(stderr.strip()) - len("kaggle-hub: "), 300)

    def test_timeout_message(self):
        loader = importlib.machinery.SourceFileLoader("kaggle_hub_under_test", HUB)
        spec = importlib.util.spec_from_loader(loader.name, loader)
        module = importlib.util.module_from_spec(spec)
        previous = sys.dont_write_bytecode
        sys.dont_write_bytecode = True
        try:
            loader.exec_module(module)
        finally:
            sys.dont_write_bytecode = previous

        hub = module.Hub(str(self.state_dir), "kaggle", 0.0)
        self.state_dir.mkdir(exist_ok=True)
        expired = subprocess.TimeoutExpired(cmd="kaggle", timeout=60)
        with mock.patch.object(module.subprocess, "run", side_effect=expired) as run:
            with self.assertRaises(module.HubError) as caught:
                hub.call_cli("kernels", "list")
        self.assertEqual(str(caught.exception), "Kaggle CLI timed out after 60 seconds.")
        self.assertEqual(run.call_args.kwargs["timeout"], 60)


class TrackTests(HubTestCase):
    def test_track_sets_last_run_at_to_track_time(self):
        started = hours_ago(3)
        self.set_list([("alice/nb", "N", listed(started))])
        self.set_status("alice/nb", "RUNNING")

        first = self.snapshot()
        self.assertEqual(first["activeRuns"][0]["lastRunAt"],
                         started.strftime("%Y-%m-%dT%H:%M:%S.%f"))

        proc = self.run_hub("track", "alice/nb", "--project", "demo")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        tracked = json.loads(proc.stdout)
        self.assertEqual(set(tracked), {"ref", "trackedAt"})
        self.assertEqual(tracked["ref"], "alice/nb")

        before = len(self.status_calls("alice/nb"))
        run = self.snapshot()["activeRuns"][0]
        self.assertGreater(len(self.status_calls("alice/nb")), before)
        self.assertAlmostEqual(to_epoch(run["lastRunAt"]), tracked["trackedAt"], places=5)
        self.assertEqual(run["project"], "demo")

    def test_track_records_the_accelerator(self):
        self.set_list([("alice/gpu", "G", listed(hours_ago(1))), ("alice/tpu", "T", listed(hours_ago(2))),
                       ("alice/plain", "P", listed(hours_ago(3)))])
        for ref in ("alice/gpu", "alice/tpu", "alice/plain"):
            self.set_status(ref, "RUNNING")
        self.assertEqual(self.run_hub("track", "alice/gpu", "--accelerator", "NvidiaTeslaT4").returncode, 0)
        self.assertEqual(self.run_hub("track", "alice/tpu", "--accelerator", "TpuV6E8").returncode, 0)
        runs = {run["ref"]: run for run in self.snapshot()["activeRuns"]}
        self.assertEqual(runs["alice/gpu"]["accelerator"], "GPU")
        self.assertEqual(runs["alice/tpu"]["accelerator"], "TPU")
        self.assertIsNone(runs["alice/plain"]["accelerator"])

    def test_track_rejects_an_unknown_accelerator(self):
        proc = self.run_hub("track", "alice/nb", "--accelerator", "abacus")
        self.assertEqual(proc.returncode, 2)
        self.assertEqual(proc.stdout, "")
        self.assertRegex(proc.stderr, r"^kaggle-hub: Unknown accelerator: abacus\. [^\n]+\n$")

    def test_track_accepts_a_notebook_url(self):
        proc = self.run_hub("track", "https://www.kaggle.com/code/alice/nb")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(json.loads(proc.stdout)["ref"], "alice/nb")

    def test_track_rejects_a_bad_reference(self):
        proc = self.run_hub("track", "not a ref")
        self.assertEqual(proc.returncode, 2)
        self.assertEqual(proc.stdout, "")
        self.assertRegex(proc.stderr, r"^kaggle-hub: [^\n]+\n$")

    def test_tracked_notebook_missing_from_the_list_is_checked(self):
        self.set_list([])
        self.set_status("alice/fresh", "QUEUED")
        proc = self.run_hub("track", "alice/fresh")
        tracked = json.loads(proc.stdout)
        result = self.snapshot()
        self.assertEqual([(r["ref"], r["status"]) for r in result["activeRuns"]],
                         [("alice/fresh", "QUEUED")])
        self.assertAlmostEqual(to_epoch(result["activeRuns"][0]["lastRunAt"]),
                               tracked["trackedAt"], places=5)


if __name__ == "__main__":
    unittest.main()
