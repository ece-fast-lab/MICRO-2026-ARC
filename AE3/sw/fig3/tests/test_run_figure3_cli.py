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


if __name__ == "__main__":
    unittest.main()
