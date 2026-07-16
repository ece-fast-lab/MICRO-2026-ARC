#!/usr/bin/env python3

from __future__ import annotations

import csv
import hashlib
import os
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


FIG11_DIR = Path(__file__).resolve().parents[1]
SW_DIR = FIG11_DIR.parent
ARTIFACT_DIR = SW_DIR.parent


class Figure11ShellIntegrationTest(unittest.TestCase):
    def _prepare_fake_hardware_tree(
        self, temporary_directory: str
    ) -> tuple[Path, dict[str, str], Path, Path]:
        root = Path(temporary_directory) / "AE4"
        fig11 = root / "sw" / "fig11"
        benchmark_dir = root / "sw" / "benchmark"
        fig11.mkdir(parents=True)
        benchmark_dir.mkdir(parents=True)
        for name in (
            "run_figure11.sh",
            "collect_results.py",
            "plot_figure11.py",
        ):
            shutil.copy2(FIG11_DIR / name, fig11 / name)
        shutil.copy2(
            SW_DIR / "benchmark" / "ae_reproduction_common.sh",
            benchmark_dir / "ae_reproduction_common.sh",
        )

        model_dir = root / "sw" / "ml" / "pretrained" / "th16" / "gap"
        model_dir.mkdir(parents=True)
        shutil.copy2(
            SW_DIR / "ml" / "pretrained" / "th16" / "gap" / "bc_twitter.cfg",
            model_dir / "bc_twitter.cfg",
        )
        generated = root / "set_default" / "generated"
        generated.mkdir(parents=True)
        (generated / "platform.env").write_text(
            "CXL_NODE=1\nBUFFER_NODE=0\nexport CXL_NODE BUFFER_NODE\n",
            encoding="utf-8",
        )
        manager_dir = root / "sw" / "build_option_th16"
        manager_dir.mkdir()
        manager = manager_dir / "migration_manager"
        manager.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        manager.chmod(0o755)

        gapbs_root = root / "fake-gapbs"
        gapbs_root.mkdir()
        gapbs_binary = gapbs_root / "bc"
        gapbs_binary.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        gapbs_binary.chmod(0o755)
        config_dir = root / "sw" / "config"
        config_dir.mkdir()
        (config_dir / "benchmark_paths.env").write_text(
            f"GAPBS_ROOT={gapbs_root}\n",
            encoding="utf-8",
        )

        state_file = root / "fake-runner-count"
        fake_runner = benchmark_dir / "run_gapbs.sh"
        fake_runner.write_text(
            "#!/usr/bin/env bash\n"
            "set -euo pipefail\n"
            "count=0\n"
            "[[ ! -r \"$FAKE_RUNNER_STATE\" ]] || "
            "read -r count < \"$FAKE_RUNNER_STATE\"\n"
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
            "benchmark=$5; database=$6; mode=$7; tag=$8\n"
            "run_dir=\"${OUT_BASE_DIR}/${threshold}_${epoch_a}_${epoch_b}_${poll}_${benchmark}_${database}_${mode}_${tag}\"\n"
            "mkdir -p \"$run_dir\"\n"
            "for trial in {1..10}; do echo 'Trial Time: 10.0'; done "
            "> \"$run_dir/${benchmark}_${database}.log\"\n"
            "cat > \"$run_dir/runtime_summary.txt\" <<'EOF'\n"
            "WORKLOAD_PID=100 rc=0\n"
            "MIGRATION_MANAGER_PID=NA rc=0 failed=0\n"
            "BACKGROUND_CONTROL_FAILED=0\n"
            "TRACKER_DISABLE_FAILED=0\n"
            "EOF\n",
            encoding="utf-8",
        )
        fake_runner.chmod(0o755)

        fake_bin = root / "fake-bin"
        fake_bin.mkdir()
        sleep_log = root / "fake-sleep.log"
        fake_sleep = fake_bin / "sleep"
        fake_sleep.write_text(
            "#!/bin/sh\nprintf '%s\\n' \"$1\" >> \"$FAKE_SLEEP_LOG\"\n",
            encoding="utf-8",
        )
        fake_sleep.chmod(0o755)
        fake_numactl = fake_bin / "numactl"
        fake_numactl.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        fake_numactl.chmod(0o755)

        environment = os.environ.copy()
        environment.update(
            {
                "PATH": f"{fake_bin}:{environment['PATH']}",
                "FAKE_RUNNER_STATE": str(state_file),
                "FAKE_SLEEP_LOG": str(sleep_log),
                "FIG11_CASE_INTERVAL_SEC": "30",
                "FIG11_LOCK_RETRY_INTERVAL_SEC": "2",
                "FIG11_LOCK_RETRY_TIMEOUT_SEC": "10",
            }
        )
        return root, environment, state_file, sleep_log

    def test_skip_benchmark_validates_collects_and_plots(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            results_root = Path(temporary_directory)
            result_dir = results_root / "figure11" / "th16" / "bc_twitter"
            runs = result_dir / "runs"
            pretrained_model_cfg = (
                SW_DIR / "ml" / "pretrained" / "th16" / "gap" / "bc_twitter.cfg"
            ).resolve()
            model_sha256 = hashlib.sha256(pretrained_model_cfg.read_bytes()).hexdigest()
            model_cfg = (
                result_dir
                / "configuration_snapshots"
                / f"bc_twitter_{model_sha256}.cfg"
            )
            adaptive_manager_logs: list[Path] = []
            methods = {
                "cxl": ("baseline", 400000, 400000, "cxl", 100.0),
                "cache": ("mig", 400000, 400000, "cache", 90.0),
                "cms": ("mig", 400001, 400001, "cms", 80.0),
                # Make the reverse direction faster so this integration test
                # proves that the final Adaptive bar is selected from both
                # complete five-repeat candidates rather than always using
                # the legacy forward direction.
                "adaptive_400000_400001": (
                    "mig", 400000, 400001, "adaptive", 70.0
                ),
                "adaptive_400001_400000": (
                    "mig", 400001, 400000, "adaptive_400001_400000", 60.0
                ),
            }
            for method, (
                mode,
                epoch_a,
                epoch_b,
                tag_method,
                seconds,
            ) in methods.items():
                for repeat in range(1, 6):
                    tag = f"fig11_{tag_method}_rep{repeat:02d}"
                    run_dir = runs / (
                        f"16_{epoch_a}_{epoch_b}_1_bc_twitter_{mode}_{tag}"
                    )
                    run_dir.mkdir(parents=True)
                    (run_dir / "bc_twitter.log").write_text(
                        "\n".join(
                            f"Trial Time: {seconds + trial / 1000:.3f}"
                            for trial in range(1, 11)
                        )
                        + "\n",
                        encoding="utf-8",
                    )
                    (run_dir / "runtime_summary.txt").write_text(
                        "WORKLOAD_PID=123 rc=0\n"
                        "MIGRATION_MANAGER_PID=NA rc=0 failed=0\n"
                        "BACKGROUND_CONTROL_FAILED=0\n"
                        "TRACKER_DISABLE_FAILED=0\n",
                        encoding="utf-8",
                    )
                    if method.startswith("adaptive_"):
                        manager_log = run_dir / "migration_manager.log"
                        manager_log.write_text(
                            f"[ml-predict] loaded model override from {model_cfg}\n"
                            "[mode-switch] ML policy active: "
                            f"mode0(epoch={epoch_a}) vs mode1(epoch={epoch_b})\n",
                            encoding="utf-8",
                        )
                        adaptive_manager_logs.append(manager_log)

            env = os.environ.copy()
            env["AE4_RESULTS_ROOT"] = os.path.relpath(results_root, ARTIFACT_DIR)
            command = [
                "bash",
                str(FIG11_DIR / "run_figure11.sh"),
                "bc_tw",
                "--threshold",
                "16",
                "--skip-benchmark",
            ]
            completed = subprocess.run(
                command,
                cwd=ARTIFACT_DIR,
                env=env,
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                completed.returncode,
                0,
                msg=f"stdout:\n{completed.stdout}\nstderr:\n{completed.stderr}",
            )

            with (result_dir / "figure11_results.csv").open(
                newline="", encoding="utf-8"
            ) as summary_file:
                rows = list(csv.DictReader(summary_file))
            self.assertEqual(
                [row["method"] for row in rows],
                ["cxl", "cache", "cms", "adaptive"],
            )
            self.assertTrue(
                all(row["selected_sample_count"] == "25" for row in rows)
            )
            adaptive_row = next(row for row in rows if row["method"] == "adaptive")
            self.assertEqual(
                adaptive_row["selected_adaptive_direction"],
                "adaptive_400001_400000",
            )
            self.assertLess(
                float(adaptive_row["adaptive_400001_400000_geomean_seconds"]),
                float(adaptive_row["adaptive_400000_400001_geomean_seconds"]),
            )
            with (result_dir / "figure11_manifest.csv").open(
                newline="", encoding="utf-8"
            ) as manifest_file:
                manifest_rows = list(csv.DictReader(manifest_file))
            for direction in (
                "adaptive_400000_400001",
                "adaptive_400001_400000",
            ):
                self.assertEqual(
                    sum(row["method"] == direction for row in manifest_rows), 5
                )
            with (result_dir / "figure11_selected_samples.csv").open(
                newline="", encoding="utf-8"
            ) as samples_file:
                sample_rows = list(csv.DictReader(samples_file))
            self.assertEqual(
                sum(
                    row["method"] == "adaptive_400000_400001"
                    and row["selected_for_adaptive_bar"] == "no"
                    for row in sample_rows
                ),
                25,
            )
            self.assertEqual(
                sum(
                    row["method"] == "adaptive_400001_400000"
                    and row["selected_for_adaptive_bar"] == "yes"
                    for row in sample_rows
                ),
                25,
            )
            self.assertGreater(
                (result_dir / "figure11_normalized_performance.png").stat().st_size,
                0,
            )
            self.assertGreater(
                (result_dir / "figure11_normalized_performance.pdf").stat().st_size,
                0,
            )
            self.assertEqual(model_cfg.read_bytes(), pretrained_model_cfg.read_bytes())
            self.assertEqual(model_cfg.stat().st_mode & 0o777, 0o444)
            metadata = (result_dir / "run_metadata.txt").read_text(encoding="utf-8")
            self.assertIn(f"adaptive_cfg_snapshot={model_cfg}\n", metadata)
            self.assertIn(f"adaptive_cfg_sha256={model_sha256}\n", metadata)
            self.assertIn("adaptive_repetitions_per_direction=5\n", metadata)
            self.assertIn(
                "adaptive_candidate_directions=400000/400001,400001/400000\n",
                metadata,
            )
            self.assertIn(
                "adaptive_selection=lower_25_sample_geomean_seconds\n",
                metadata,
            )
            self.assertIn("plot_status=generated\n", metadata)

            # Data processing must remain usable without importing Matplotlib.
            png = result_dir / "figure11_normalized_performance.png"
            pdf = result_dir / "figure11_normalized_performance.pdf"
            png.unlink()
            pdf.unlink()
            fake_sleep_bin = results_root / "fake-sleep-bin"
            fake_sleep_bin.mkdir()
            processing_sleep_log = results_root / "processing-sleep.log"
            fake_sleep = fake_sleep_bin / "sleep"
            fake_sleep.write_text(
                "#!/bin/sh\nprintf '%s\\n' \"$1\" >> \"$PROCESSING_SLEEP_LOG\"\n",
                encoding="utf-8",
            )
            fake_sleep.chmod(0o755)
            processing_env = env.copy()
            processing_env["PATH"] = (
                f"{fake_sleep_bin}:{processing_env.get('PATH', '')}"
            )
            processing_env["PROCESSING_SLEEP_LOG"] = str(processing_sleep_log)
            skip_plot_result = subprocess.run(
                command + ["--skip-plot"],
                cwd=ARTIFACT_DIR,
                env=processing_env,
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                skip_plot_result.returncode,
                0,
                msg=(
                    f"stdout:\n{skip_plot_result.stdout}\n"
                    f"stderr:\n{skip_plot_result.stderr}"
                ),
            )
            self.assertFalse(png.exists())
            self.assertFalse(pdf.exists())
            self.assertFalse(processing_sleep_log.exists())
            metadata = (result_dir / "run_metadata.txt").read_text(encoding="utf-8")
            self.assertIn("plot_status=skipped_by_request\n", metadata)

            # A broken Matplotlib installation must be reported only after the
            # standard-library collector has successfully regenerated its CSVs.
            fake_bin = results_root / "fake-bin"
            fake_bin.mkdir()
            fake_python = fake_bin / "python3"
            fake_python.write_text(
                "#!/usr/bin/env bash\n"
                "if [[ \"${1:-}\" == -c && \"${2:-}\" == "
                "'import matplotlib' ]]; then exit 1; fi\n"
                f"exec {shlex.quote(sys.executable)} \"$@\"\n",
                encoding="utf-8",
            )
            fake_python.chmod(0o755)
            no_matplotlib_env = env.copy()
            no_matplotlib_env["PATH"] = f"{fake_bin}:{env.get('PATH', '')}"
            no_matplotlib_result = subprocess.run(
                command,
                cwd=ARTIFACT_DIR,
                env=no_matplotlib_env,
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                no_matplotlib_result.returncode,
                0,
                msg=(
                    f"stdout:\n{no_matplotlib_result.stdout}\n"
                    f"stderr:\n{no_matplotlib_result.stderr}"
                ),
            )
            self.assertIn("Matplotlib is unavailable", no_matplotlib_result.stderr)
            self.assertTrue((result_dir / "figure11_results.csv").is_file())
            metadata = (result_dir / "run_metadata.txt").read_text(encoding="utf-8")
            self.assertIn("plot_status=skipped_matplotlib_unavailable\n", metadata)

            # A mutable pretrained path must not validate as the frozen cfg.
            stale_log = adaptive_manager_logs[0]
            stale_log.write_text(
                stale_log.read_text(encoding="utf-8").replace(
                    str(model_cfg), str(pretrained_model_cfg)
                ),
                encoding="utf-8",
            )
            stale_result = subprocess.run(
                command,
                cwd=ARTIFACT_DIR,
                env=env,
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(stale_result.returncode, 0)
            self.assertIn("did not load the requested adaptive cfg", stale_result.stderr)

    def test_method_guards_and_new_wrappers(self) -> None:
        local_without_guard = subprocess.run(
            [
                "bash",
                str(FIG11_DIR / "run_figure11.sh"),
                "bc_tw",
                "--method",
                "local",
            ],
            cwd=ARTIFACT_DIR,
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(local_without_guard.returncode, 0)
        self.assertIn("requires --include-local", local_without_guard.stderr)

        processing_one_method = subprocess.run(
            [
                "bash",
                str(FIG11_DIR / "run_figure11.sh"),
                "bc_tw",
                "--method",
                "cxl",
                "--skip-benchmark",
            ],
            cwd=ARTIFACT_DIR,
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(processing_one_method.returncode, 0)
        self.assertIn("requires --method all", processing_one_method.stderr)

        for wrapper in (
            "run_fig11_case.sh",
            "run_fig11_all_yes.sh",
            "plot_fig11.sh",
            "run_all_primary_th16.sh",
        ):
            completed = subprocess.run(
                ["bash", str(FIG11_DIR / wrapper), "--help"],
                cwd=ARTIFACT_DIR,
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(completed.returncode, 0, msg=wrapper)

    def test_lock_retry_and_intervals_preserve_completed_repetitions(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root, environment, state_file, sleep_log = \
                self._prepare_fake_hardware_tree(temporary_directory)
            environment["FAKE_LOCK_FAILURES"] = "1"
            command = [
                "bash",
                str(root / "sw" / "fig11" / "run_figure11.sh"),
                "bc_tw",
                "--method",
                "cxl",
                "--yes",
                "--skip-plot",
            ]
            completed = subprocess.run(
                command,
                cwd=root,
                env=environment,
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                completed.returncode,
                0,
                msg=f"stdout:\n{completed.stdout}\nstderr:\n{completed.stderr}",
            )
            self.assertEqual(state_file.read_text(encoding="utf-8").strip(), "6")
            self.assertEqual(completed.stderr.count("[lock retry]"), 1)
            self.assertIn(
                "ERROR: another ARC setup or benchmark command is active",
                completed.stderr,
            )
            self.assertEqual(
                sleep_log.read_text(encoding="utf-8").splitlines(),
                ["2", "30", "30", "30", "30"],
            )

            resumed = subprocess.run(
                command + ["--resume"],
                cwd=root,
                env=environment,
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                resumed.returncode,
                0,
                msg=f"stdout:\n{resumed.stdout}\nstderr:\n{resumed.stderr}",
            )
            self.assertEqual(state_file.read_text(encoding="utf-8").strip(), "6")
            self.assertEqual(
                sleep_log.read_text(encoding="utf-8").splitlines(),
                ["2", "30", "30", "30", "30"],
            )
            self.assertEqual(resumed.stdout.count("reuse valid"), 5)

    def test_non_lock_failure_is_not_retried(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root, environment, state_file, sleep_log = \
                self._prepare_fake_hardware_tree(temporary_directory)
            environment["FAKE_RUNNER_MODE"] = "fatal"
            completed = subprocess.run(
                [
                    "bash",
                    str(root / "sw" / "fig11" / "run_figure11.sh"),
                    "bc_tw",
                    "--method",
                    "cxl",
                    "--yes",
                    "--skip-plot",
                ],
                cwd=root,
                env=environment,
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(completed.returncode, 7)
            self.assertEqual(state_file.read_text(encoding="utf-8").strip(), "1")
            self.assertFalse(sleep_log.exists())
            self.assertNotIn("[lock retry]", completed.stderr)
            self.assertIn("synthetic benchmark failure", completed.stderr)

    def test_lock_retry_stops_at_configured_timeout(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root, environment, state_file, sleep_log = \
                self._prepare_fake_hardware_tree(temporary_directory)
            environment["FAKE_LOCK_FAILURES"] = "999"
            environment["FIG11_LOCK_RETRY_TIMEOUT_SEC"] = "4"
            completed = subprocess.run(
                [
                    "bash",
                    str(root / "sw" / "fig11" / "run_figure11.sh"),
                    "bc_tw",
                    "--method",
                    "cxl",
                    "--yes",
                    "--skip-plot",
                ],
                cwd=root,
                env=environment,
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(completed.returncode, 0)
            self.assertEqual(state_file.read_text(encoding="utf-8").strip(), "3")
            self.assertEqual(completed.stderr.count("[lock retry]"), 2)
            self.assertIn("remained busy after 4 seconds", completed.stderr)
            self.assertIn("rerun with --resume", completed.stderr)
            self.assertEqual(
                sleep_log.read_text(encoding="utf-8").splitlines(), ["2", "2"]
            )

    def test_multi_workload_wrapper_waits_only_after_new_final_unit(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            fig11 = Path(temporary_directory) / "fig11"
            fig11.mkdir()
            shutil.copy2(
                FIG11_DIR / "run_all_primary_th16.sh",
                fig11 / "run_all_primary_th16.sh",
            )
            fake_all = fig11 / "run_fig11_all_yes.sh"
            fake_all.write_text(
                "#!/usr/bin/env bash\n"
                "set -euo pipefail\n"
                "printf '%s\\n' \"$1\" >> \"$FAKE_WORKLOAD_LOG\"\n"
                "if [[ \"$1\" == bc_tw ]]; then\n"
                "  : > \"${FIG11_FINAL_EXECUTION_MARKER:?}\"\n"
                "fi\n",
                encoding="utf-8",
            )
            fake_all.chmod(0o755)
            fake_bin = Path(temporary_directory) / "fake-bin"
            fake_bin.mkdir()
            sleep_log = Path(temporary_directory) / "sleep.log"
            fake_sleep = fake_bin / "sleep"
            fake_sleep.write_text(
                "#!/bin/sh\nprintf '%s\\n' \"$1\" >> \"$FAKE_SLEEP_LOG\"\n",
                encoding="utf-8",
            )
            fake_sleep.chmod(0o755)
            workload_log = Path(temporary_directory) / "workloads.log"
            environment = os.environ.copy()
            environment.update(
                {
                    "PATH": f"{fake_bin}:{environment['PATH']}",
                    "FAKE_SLEEP_LOG": str(sleep_log),
                    "FAKE_WORKLOAD_LOG": str(workload_log),
                }
            )
            completed = subprocess.run(
                ["bash", str(fig11 / "run_all_primary_th16.sh"), "--resume"],
                env=environment,
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                completed.returncode,
                0,
                msg=f"stdout:\n{completed.stdout}\nstderr:\n{completed.stderr}",
            )
            self.assertEqual(
                workload_log.read_text(encoding="utf-8").splitlines(),
                ["bc_tw", "bfs_tw", "pr_tw"],
            )
            self.assertEqual(sleep_log.read_text(encoding="utf-8").splitlines(), ["30"])


if __name__ == "__main__":
    unittest.main()
