#!/usr/bin/env python3

from __future__ import annotations

import csv
import hashlib
import os
import shlex
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


FIG11_DIR = Path(__file__).resolve().parents[1]
SW_DIR = FIG11_DIR.parent
ARTIFACT_DIR = SW_DIR.parent


class Figure11ShellIntegrationTest(unittest.TestCase):
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
                "cxl": ("baseline", 400000, 400000, 100.0),
                "cache": ("mig", 400000, 400000, 90.0),
                "cms": ("mig", 400001, 400001, 80.0),
                "adaptive": ("mig", 400000, 400001, 70.0),
            }
            for method, (mode, epoch_a, epoch_b, seconds) in methods.items():
                for repeat in range(1, 6):
                    tag = f"fig11_{method}_rep{repeat:02d}"
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
                    if method == "adaptive":
                        manager_log = run_dir / "migration_manager.log"
                        manager_log.write_text(
                            f"[ml-predict] loaded model override from {model_cfg}\n"
                            "[mode-switch] ML policy active: "
                            "mode0(epoch=400000) vs mode1(epoch=400001)\n",
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
            self.assertIn("plot_status=generated\n", metadata)

            # Data processing must remain usable without importing Matplotlib.
            png = result_dir / "figure11_normalized_performance.png"
            pdf = result_dir / "figure11_normalized_performance.pdf"
            png.unlink()
            pdf.unlink()
            skip_plot_result = subprocess.run(
                command + ["--skip-plot"],
                cwd=ARTIFACT_DIR,
                env=env,
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


if __name__ == "__main__":
    unittest.main()
