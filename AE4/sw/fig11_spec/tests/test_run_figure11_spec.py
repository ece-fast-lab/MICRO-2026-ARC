#!/usr/bin/env python3

from __future__ import annotations

import csv
import hashlib
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


SPEC_FIG11_DIR = Path(__file__).resolve().parents[1]
SW_DIR = SPEC_FIG11_DIR.parent
ARTIFACT_DIR = SW_DIR.parent


class SpecFigure11ShellIntegrationTest(unittest.TestCase):
    def test_skip_benchmark_validates_collects_plots_and_freezes_cfg(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            results_root = Path(temporary_directory).resolve()
            result_dir = (
                results_root / "figure11_optional_spec" / "th16" / "502"
            )
            runs = result_dir / "runs"
            pretrained_cfg = (
                SW_DIR / "ml" / "pretrained" / "th16" / "spec" / "502.cfg"
            ).resolve()
            model_sha256 = hashlib.sha256(pretrained_cfg.read_bytes()).hexdigest()
            frozen_cfg = (
                result_dir / "configuration_snapshots" / f"502_{model_sha256}.cfg"
            )
            adaptive_manager_logs: list[Path] = []
            methods = {
                "cxl": ("baseline", 400000, 400000, 100.0),
                "cache": ("mig", 400000, 400000, 50.0),
                "cms": ("mig", 400001, 400001, 80.0),
                "adaptive": ("mig", 400000, 400001, 40.0),
            }
            for method, (mode, epoch_a, epoch_b, seconds) in methods.items():
                for repeat in range(1, 6):
                    tag = f"fig11spec_{method}_rep{repeat:02d}"
                    run_dir = runs / (
                        f"16_{epoch_a}_{epoch_b}_1_502_{mode}_{tag}"
                    )
                    run_dir.mkdir(parents=True)
                    (run_dir / "502.log").write_text(
                        "Run Complete\n"
                        "old result; 9999 total seconds elapsed\n"
                        f"runcpu finished; {seconds + repeat / 1000:.3f} "
                        "total seconds elapsed\n",
                        encoding="utf-8",
                    )
                    (run_dir / "runtime_summary.txt").write_text(
                        f"mode={mode} spec=502 copies=8\n"
                        "WORKLOAD_PID=123 rc=0\n"
                        "MIGRATION_MANAGER_PID=NA rc=0 failed=0\n"
                        "BACKGROUND_CONTROL_FAILED=0\n"
                        "TRACKER_DISABLE_FAILED=0\n",
                        encoding="utf-8",
                    )
                    if method == "adaptive":
                        manager_log = run_dir / "migration_manager.log"
                        manager_log.write_text(
                            f"[ml-predict] loaded model override from {frozen_cfg}\n"
                            "[mode-switch] ML policy active: "
                            "mode0(epoch=400000) vs mode1(epoch=400001)\n",
                            encoding="utf-8",
                        )
                        adaptive_manager_logs.append(manager_log)

            env = os.environ.copy()
            # A relative override must still be canonicalized before it is
            # embedded in the immutable cfg path and migration-manager log.
            env["AE4_RESULTS_ROOT"] = os.path.relpath(results_root, ARTIFACT_DIR)
            command = [
                "bash",
                str(SPEC_FIG11_DIR / "run_figure11_spec.sh"),
                "gcc",
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

            with (result_dir / "figure11_spec_results.csv").open(
                encoding="utf-8", newline=""
            ) as summary_file:
                rows = list(csv.DictReader(summary_file))
            self.assertEqual(
                [row["method"] for row in rows],
                ["cxl", "cache", "cms", "adaptive"],
            )
            self.assertTrue(all(row["selected_sample_count"] == "5" for row in rows))
            self.assertGreater(
                (result_dir / "figure11_spec_normalized_performance.png").stat().st_size,
                0,
            )
            self.assertGreater(
                (result_dir / "figure11_spec_normalized_performance.pdf").stat().st_size,
                0,
            )
            self.assertEqual(frozen_cfg.read_bytes(), pretrained_cfg.read_bytes())
            self.assertEqual(frozen_cfg.stat().st_mode & 0o777, 0o444)
            metadata = (result_dir / "run_metadata.txt").read_text(encoding="utf-8")
            self.assertIn(f"adaptive_cfg_snapshot={frozen_cfg}\n", metadata)
            self.assertIn(f"adaptive_cfg_sha256={model_sha256}\n", metadata)
            self.assertIn("selected_samples_per_method=5\n", metadata)

            different_copies_env = env.copy()
            different_copies_env["CHMU_SPEC_COPIES"] = "4"
            different_copies_result = subprocess.run(
                command,
                cwd=ARTIFACT_DIR,
                env=different_copies_env,
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(different_copies_result.returncode, 0)
            self.assertIn("canonical SPEC run is missing", different_copies_result.stderr)

            stale_log = adaptive_manager_logs[0]
            stale_log.write_text(
                stale_log.read_text(encoding="utf-8").replace(
                    str(frozen_cfg), str(pretrained_cfg)
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

    def test_generic_dispatcher_exposes_both_suites(self) -> None:
        dispatcher = SW_DIR / "run_figure11_benchmark.sh"
        completed = subprocess.run(
            ["bash", str(dispatcher), "--help"],
            cwd=ARTIFACT_DIR,
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(completed.returncode, 0)
        self.assertIn("gapbs", completed.stdout)
        self.assertIn("spec", completed.stdout)


if __name__ == "__main__":
    unittest.main()
