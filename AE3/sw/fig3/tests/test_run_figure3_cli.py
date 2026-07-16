#!/usr/bin/env python3
"""Processing-only integration tests for the Figure 3 shell driver."""

from __future__ import annotations

import csv
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


SOURCE_FIG3 = Path(__file__).resolve().parents[1]
SOURCE_BENCHMARK = SOURCE_FIG3.parent / "benchmark"


class Figure3DriverTests(unittest.TestCase):
    maxDiff = None

    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name) / "AE3"
        self.fig3 = self.root / "sw" / "fig3"
        self.benchmark = self.root / "sw" / "benchmark"
        self.fig3.mkdir(parents=True)
        self.benchmark.mkdir(parents=True)

        for name in ("run_figure3.sh", "collect_results.py", "plot_figure3.py"):
            shutil.copy2(SOURCE_FIG3 / name, self.fig3 / name)
        shutil.copy2(
            SOURCE_BENCHMARK / "ae_reproduction_common.sh",
            self.benchmark / "ae_reproduction_common.sh",
        )
        self._write_complete_gapbs_sweep()

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def _write_complete_gapbs_sweep(self) -> None:
        points = (
            (16, 400000, "baseline", "fig3_baseline"),
            (16, 400000, "anb", "fig3_anb"),
            (16, 400000, "damon", "fig3_damon"),
            (16, 400000, "mig", "fig3_cache_th16"),
            (32, 400000, "mig", "fig3_cache_th32"),
            (64, 400000, "mig", "fig3_cache_th64"),
            (96, 400000, "mig", "fig3_cache_th96"),
            (16, 400001, "mig", "fig3_cms_th16"),
            (32, 400001, "mig", "fig3_cms_th32"),
            (64, 400001, "mig", "fig3_cms_th64"),
            (96, 400001, "mig", "fig3_cms_th96"),
        )
        runs = self.root / "results" / "figure3" / "gapbs" / "pr_twitter" / "runs"
        for index, (threshold, epoch, method, tag) in enumerate(points, start=1):
            run_name = (
                f"{threshold}_{epoch}_{epoch}_1_pr_twitter_{method}_{tag}"
            )
            run_directory = runs / run_name
            run_directory.mkdir(parents=True)
            trial_base = 10.0 + index
            trials = "".join(
                f"Trial Time: {trial_base + trial / 10:.1f}\n" for trial in range(10)
            )
            (run_directory / "pr_twitter.log").write_text(trials, encoding="utf-8")
            (run_directory / "runtime_summary.txt").write_text(
                "WORKLOAD_PID=100 rc=0\n"
                "MIGRATION_MANAGER_PID=NA rc=0 failed=0\n"
                "BACKGROUND_CONTROL_FAILED=0\n"
                "TRACKER_DISABLE_FAILED=0\n",
                encoding="utf-8",
            )

    def _run(self, *extra_arguments: str, env: dict[str, str] | None = None):
        command = [
            "bash",
            str(self.fig3 / "run_figure3.sh"),
            "gapbs",
            "pr",
            "twitter",
            "--skip-benchmark",
            *extra_arguments,
        ]
        return subprocess.run(
            command,
            cwd=self.root,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    def _prepare_fake_hardware_case(self) -> tuple[Path, Path]:
        generated = self.root / "set_default" / "generated"
        generated.mkdir(parents=True)
        (generated / "platform.env").write_text(
            "CXL_NODE=1\nBUFFER_NODE=0\nexport CXL_NODE BUFFER_NODE\n",
            encoding="utf-8",
        )

        gapbs_root = self.root / "fake-gapbs"
        gapbs_root.mkdir()
        gapbs_binary = gapbs_root / "pr"
        gapbs_binary.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        gapbs_binary.chmod(0o755)
        config = self.root / "sw" / "config"
        config.mkdir()
        (config / "benchmark_paths.env").write_text(
            f"GAPBS_ROOT={gapbs_root}\n",
            encoding="utf-8",
        )

        manager_dir = self.root / "sw" / "build_option_th16"
        manager_dir.mkdir()
        manager = manager_dir / "migration_manager"
        manager.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        manager.chmod(0o755)

        state_file = self.root / "fake-runner-count"
        fake_runner = self.benchmark / "run_gapbs.sh"
        fake_runner.write_text(
            "#!/usr/bin/env bash\n"
            "set -euo pipefail\n"
            "count=0\n"
            "[[ ! -r \"$FAKE_RUNNER_STATE\" ]] || read -r count < \"$FAKE_RUNNER_STATE\"\n"
            "count=$((count + 1))\n"
            "printf '%s\\n' \"$count\" > \"$FAKE_RUNNER_STATE\"\n"
            "if [[ \"${FAKE_RUNNER_MODE:-transient}\" == fatal ]]; then\n"
            "  echo 'ERROR: synthetic benchmark failure' >&2\n"
            "  exit 7\n"
            "fi\n"
            "if (( count <= ${FAKE_LOCK_FAILURES:-0} )); then\n"
            "  : > \"${ARC_LOCK_BUSY_MARKER:?}\"\n"
            "  echo 'ERROR: another ARC setup or benchmark command is active' >&2\n"
            "  exit 1\n"
            "fi\n"
            "threshold=$1; epoch_a=$2; epoch_b=$3; poll=$4\n"
            "benchmark=$5; database=$6; method=$7; tag=$8\n"
            "run_dir=\"${OUT_BASE_DIR}/${threshold}_${epoch_a}_${epoch_b}_${poll}_${benchmark}_${database}_${method}_${tag}\"\n"
            "mkdir -p \"$run_dir\"\n"
            "for trial in {1..10}; do echo 'Trial Time: 10.0'; done > \"$run_dir/${benchmark}_${database}.log\"\n"
            "cat > \"$run_dir/runtime_summary.txt\" <<'EOF'\n"
            "WORKLOAD_PID=100 rc=0\n"
            "MIGRATION_MANAGER_PID=NA rc=0 failed=0\n"
            "BACKGROUND_CONTROL_FAILED=0\n"
            "TRACKER_DISABLE_FAILED=0\n"
            "EOF\n",
            encoding="utf-8",
        )
        fake_runner.chmod(0o755)

        fake_bin = self.root / "fake-bin"
        fake_bin.mkdir()
        fake_sleep = fake_bin / "sleep"
        fake_sleep.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        fake_sleep.chmod(0o755)
        return state_file, fake_bin

    def _run_fake_hardware_case(self, **overrides: str):
        state_file, fake_bin = self._prepare_fake_hardware_case()
        environment = os.environ.copy()
        environment.update(
            {
                "PATH": f"{fake_bin}:{environment['PATH']}",
                "FAKE_RUNNER_STATE": str(state_file),
                "FIG3_LOCK_RETRY_INTERVAL_SEC": "2",
                "FIG3_LOCK_RETRY_TIMEOUT_SEC": "10",
                **overrides,
            }
        )
        completed = subprocess.run(
            [
                "bash",
                str(self.fig3 / "run_figure3.sh"),
                "gapbs",
                "pr",
                "twitter",
                "--case",
                "baseline",
                "--yes",
                "--skip-plot",
            ],
            cwd=self.root,
            env=environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        count = int(state_file.read_text(encoding="utf-8").strip())
        return completed, count

    def test_skip_plot_collects_full_deterministic_manifest_and_csv(self) -> None:
        completed = self._run("--skip-plot")
        self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)

        result_directory = self.root / "results" / "figure3" / "gapbs" / "pr_twitter"
        with (result_directory / "figure3_manifest.csv").open(
            encoding="utf-8", newline=""
        ) as manifest_file:
            manifest_rows = list(csv.DictReader(manifest_file))
        self.assertEqual(len(manifest_rows), 11)
        self.assertEqual(
            [row["label"] for row in manifest_rows],
            [
                "Baseline",
                "ANB",
                "DAMON",
                "Cache-16",
                "Cache-32",
                "Cache-64",
                "Cache-96",
                "CMS-16",
                "CMS-32",
                "CMS-64",
                "CMS-96",
            ],
        )
        with (result_directory / "figure3_results.csv").open(
            encoding="utf-8", newline=""
        ) as results_file:
            self.assertEqual(len(list(csv.DictReader(results_file))), 11)
        metadata = (result_directory / "run_metadata.txt").read_text(encoding="utf-8")
        self.assertIn("data_status=complete_full_sweep\n", metadata)
        self.assertIn("plot_status=skipped_by_option\n", metadata)

    def test_missing_matplotlib_is_success_after_csv_collection(self) -> None:
        real_python = shutil.which("python3")
        self.assertIsNotNone(real_python)
        fake_bin = self.root / "fake-bin"
        fake_bin.mkdir()
        fake_python = fake_bin / "python3"
        fake_python.write_text(
            "#!/bin/sh\n"
            "if [ \"${1:-}\" = -c ] && [ \"${2:-}\" = 'import matplotlib' ]; then\n"
            "    exit 1\n"
            "fi\n"
            f"exec {real_python} \"$@\"\n",
            encoding="utf-8",
        )
        fake_python.chmod(0o755)
        environment = os.environ.copy()
        environment["PATH"] = f"{fake_bin}:{environment['PATH']}"

        completed = self._run(env=environment)
        self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
        self.assertIn("only PNG/PDF plotting was skipped", completed.stderr)
        metadata = (
            self.root
            / "results"
            / "figure3"
            / "gapbs"
            / "pr_twitter"
            / "run_metadata.txt"
        ).read_text(encoding="utf-8")
        self.assertIn("plot_status=skipped_matplotlib_unavailable\n", metadata)

    def test_transient_host_lock_is_retried_without_repeating_completed_case(self) -> None:
        completed, count = self._run_fake_hardware_case(FAKE_LOCK_FAILURES="1")
        self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
        self.assertEqual(count, 2)
        self.assertEqual(completed.stderr.count("[lock retry]"), 1)
        self.assertIn("preserving completed results", completed.stderr)
        self.assertIn("Figure 3 case completed: baseline", completed.stdout)

    def test_non_lock_runner_failure_is_not_retried(self) -> None:
        completed, count = self._run_fake_hardware_case(FAKE_RUNNER_MODE="fatal")
        self.assertEqual(completed.returncode, 7, completed.stdout + completed.stderr)
        self.assertEqual(count, 1)
        self.assertNotIn("[lock retry]", completed.stderr)
        self.assertIn("synthetic benchmark failure", completed.stderr)

    def test_host_lock_retry_stops_at_configured_timeout(self) -> None:
        completed, count = self._run_fake_hardware_case(
            FAKE_LOCK_FAILURES="999",
            FIG3_LOCK_RETRY_TIMEOUT_SEC="4",
        )
        self.assertNotEqual(completed.returncode, 0)
        self.assertEqual(count, 3)
        self.assertEqual(completed.stderr.count("[lock retry]"), 2)
        self.assertIn("remained busy after 4 seconds", completed.stderr)
        self.assertIn("rerun this sweep with --resume", completed.stderr)


if __name__ == "__main__":
    unittest.main()
