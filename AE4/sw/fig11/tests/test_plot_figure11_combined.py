#!/usr/bin/env python3

from __future__ import annotations

import csv
import math
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


FIG11_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(FIG11_DIR))

from plot_figure11_combined import (  # noqa: E402
    compute_method_geomeans,
    load_combined_results,
    load_workload_results,
    make_plot,
    plt,
)


class CombinedFigure11TestCase(unittest.TestCase):
    METHODS = (
        (1, "cxl", "CXL-only"),
        (2, "cache", "CHMU-Cache"),
        (3, "cms", "CHMU-CMS"),
        (4, "adaptive", "Adaptive"),
    )

    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name)

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def write_summary(
        self,
        workload: str,
        values: dict[str, float],
        *,
        rows: tuple[tuple[int, str, str], ...] | None = None,
    ) -> Path:
        path = self.root / f"{workload}.csv"
        with path.open("w", encoding="utf-8", newline="") as output_file:
            writer = csv.writer(output_file)
            writer.writerow(
                ("order", "method", "label", "normalized_performance")
            )
            for order, method, label in rows or self.METHODS:
                writer.writerow((order, method, label, values[method]))
        return path

    def primary_inputs(self) -> list[str]:
        # The three non-CXL methods deliberately permute 2, 4, 8.  Their
        # cross-workload geometric means must therefore all be exactly 4.
        paths = {
            "bc_tw": self.write_summary(
                "bc_tw", {"cxl": 1.0, "cache": 2.0, "cms": 4.0, "adaptive": 8.0}
            ),
            "bfs_tw": self.write_summary(
                "bfs_tw", {"cxl": 1.0, "cache": 8.0, "cms": 2.0, "adaptive": 4.0}
            ),
            "pr_tw": self.write_summary(
                "pr_tw", {"cxl": 1.0, "cache": 4.0, "cms": 8.0, "adaptive": 2.0}
            ),
        }
        return [f"{workload}={paths[workload]}" for workload in paths]


class CombinedLoadingAndGeomeanTests(CombinedFigure11TestCase):
    def test_loads_exactly_three_primary_workloads_and_computes_geomean(self) -> None:
        results = load_combined_results(self.primary_inputs())

        self.assertEqual(
            [result.workload for result in results], ["bc_tw", "bfs_tw", "pr_tw"]
        )
        self.assertTrue(
            all(
                list(result.normalized) == ["cxl", "cache", "cms", "adaptive"]
                for result in results
            )
        )

        geomeans = compute_method_geomeans(results)
        self.assertEqual(set(geomeans), {"cxl", "cache", "cms", "adaptive"})
        self.assertAlmostEqual(geomeans["cxl"], 1.0)
        self.assertAlmostEqual(geomeans["cache"], 4.0)
        self.assertAlmostEqual(geomeans["cms"], 4.0)
        self.assertAlmostEqual(geomeans["adaptive"], 4.0)
        # Guard against accidentally using an arithmetic mean.
        self.assertNotAlmostEqual(geomeans["cache"], (2.0 + 8.0 + 4.0) / 3.0)

    def test_rejects_missing_or_duplicate_primary_workload_specs(self) -> None:
        inputs = self.primary_inputs()
        with self.assertRaisesRegex(ValueError, "bc_tw.*bfs_tw.*pr_tw|exactly"):
            load_combined_results(inputs[:2])

        duplicate = [inputs[0], inputs[0], inputs[2]]
        with self.assertRaisesRegex(ValueError, "duplicate.*bc_tw|bc_tw.*duplicate"):
            load_combined_results(duplicate)

    def test_rejects_missing_and_duplicate_methods_in_each_summary(self) -> None:
        values = {"cxl": 1.0, "cache": 2.0, "cms": 3.0, "adaptive": 4.0}

        missing = self.write_summary("missing", values, rows=self.METHODS[:-1])
        with self.assertRaisesRegex(ValueError, "exactly orders 1, 2, 3, 4"):
            load_workload_results("bc_tw", missing)

        duplicate_rows = self.METHODS + ((5, "cache", "CHMU-Cache duplicate"),)
        duplicate = self.write_summary("duplicate", values, rows=duplicate_rows)
        with self.assertRaisesRegex(ValueError, "duplicates method.*cache"):
            load_workload_results("bc_tw", duplicate)

    def test_rejects_malformed_or_nonpositive_normalized_values(self) -> None:
        malformed = self.root / "malformed.csv"
        malformed.write_text(
            "order,method,label,normalized_performance\n"
            "1,cxl,CXL-only,1.0\n"
            "2,cache,CHMU-Cache,not-a-number\n"
            "3,cms,CHMU-CMS,1.2\n"
            "4,adaptive,Adaptive,1.3\n",
            encoding="utf-8",
        )
        with self.assertRaisesRegex(ValueError, "invalid.*normalized_performance"):
            load_workload_results("bc_tw", malformed)

        for bad_value in (0.0, -1.0, math.inf, math.nan):
            with self.subTest(bad_value=bad_value):
                path = self.write_summary(
                    f"bad_{bad_value}",
                    {
                        "cxl": 1.0,
                        "cache": 2.0,
                        "cms": bad_value,
                        "adaptive": 4.0,
                    },
                )
                with self.assertRaisesRegex(ValueError, "positive and finite"):
                    load_workload_results("bc_tw", path)

    def test_cli_writes_png_and_pdf_for_three_workloads_plus_geomean(self) -> None:
        output_prefix = self.root / "figure11_primary_combined"
        command = [
            sys.executable,
            str(FIG11_DIR / "plot_figure11_combined.py"),
        ]
        for input_spec in self.primary_inputs():
            command.extend(("--input", input_spec))
        command.extend(
            (
                "--output-prefix",
                str(output_prefix),
                "--title",
                "Figure 11: primary GAPBS workloads",
                "--dpi",
                "72",
            )
        )

        completed = subprocess.run(
            command, check=False, capture_output=True, text=True
        )
        self.assertEqual(
            completed.returncode,
            0,
            msg=f"stdout:\n{completed.stdout}\nstderr:\n{completed.stderr}",
        )
        self.assertGreater(output_prefix.with_suffix(".png").stat().st_size, 0)
        self.assertGreater(output_prefix.with_suffix(".pdf").stat().st_size, 0)


class CombinedPlotLayoutTests(CombinedFigure11TestCase):
    def test_title_legend_axes_and_geomean_group_are_distinct(self) -> None:
        results = load_combined_results(self.primary_inputs())
        with patch.object(plt, "close") as mocked_close:
            png_path, pdf_path = make_plot(
                results,
                self.root / "combined_layout",
                "Figure 11: primary GAPBS workloads",
                72,
            )
            figure = plt.gcf()
            mocked_close.assert_called_once_with(figure)

        try:
            self.assertGreater(png_path.stat().st_size, 0)
            self.assertGreater(pdf_path.stat().st_size, 0)
            figure.canvas.draw()
            renderer = figure.canvas.get_renderer()
            self.assertIsNotNone(figure._suptitle)
            self.assertEqual(len(figure.legends), 1)

            title_box = figure._suptitle.get_window_extent(renderer)
            legend_box = figure.legends[0].get_window_extent(renderer)
            axes_box = figure.axes[0].get_window_extent(renderer)
            self.assertFalse(title_box.overlaps(legend_box))
            self.assertFalse(legend_box.overlaps(axes_box))

            axis = figure.axes[0]
            self.assertEqual(
                [tick.get_text() for tick in axis.get_xticklabels()],
                ["BC (Twitter)", "BFS (Twitter)", "PR (Twitter)", "GeoMean"],
            )
            self.assertEqual(len(axis.containers), 4)
            self.assertEqual([len(container) for container in axis.containers], [4] * 4)
            self.assertEqual(
                [container[-1].get_height() for container in axis.containers],
                [1.0, 4.0, 4.0, 4.0],
            )
        finally:
            plt.close(figure)


class CombinedPlotWrapperTests(unittest.TestCase):
    WRAPPER = FIG11_DIR / "plot_fig11_primary_combined.sh"

    def test_help_and_argument_validation(self) -> None:
        help_result = subprocess.run(
            ["bash", str(self.WRAPPER), "--help"],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(help_result.returncode, 0)
        self.assertIn("bc_tw, bfs_tw, pr_tw, and GeoMean", help_result.stdout)
        self.assertIn("processing-only", help_result.stdout)

        for arguments, expected in (
            (("--threshold", "15"), "--threshold must be"),
            (("--dpi", "0"), "--dpi must be"),
        ):
            with self.subTest(arguments=arguments):
                completed = subprocess.run(
                    ["bash", str(self.WRAPPER), *arguments],
                    check=False,
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(completed.returncode, 2)
                self.assertIn(expected, completed.stderr)

    def test_wrapper_processes_all_three_summaries_without_benchmarking(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            artifact = Path(temporary_directory) / "AE4"
            fig11 = artifact / "sw" / "fig11"
            fig11.mkdir(parents=True)
            shutil.copy2(self.WRAPPER, fig11 / self.WRAPPER.name)
            shutil.copy2(
                FIG11_DIR / "plot_figure11_combined.py",
                fig11 / "plot_figure11_combined.py",
            )

            call_log = artifact / "processing_calls.log"
            fake_runner = fig11 / "run_figure11.sh"
            fake_runner.write_text(
                "#!/usr/bin/env bash\n"
                "set -euo pipefail\n"
                "workload=$1; shift\n"
                "printf '%s' \"$workload\" >> \"$CALL_LOG\"\n"
                "printf ' %s' \"$@\" >> \"$CALL_LOG\"\n"
                "printf '\\n' >> \"$CALL_LOG\"\n"
                "threshold=\n"
                "arguments=(\"$@\")\n"
                "for ((i=0; i<${#arguments[@]}; i++)); do\n"
                "  if [[ ${arguments[$i]} == --threshold ]]; then "
                "threshold=${arguments[$((i + 1))]}; fi\n"
                "done\n"
                "case $workload in\n"
                "  bc_tw) key=bc_twitter; cache=2; cms=4; adaptive=8 ;;\n"
                "  bfs_tw) key=bfs_twitter; cache=8; cms=2; adaptive=4 ;;\n"
                "  pr_tw) key=pr_twitter; cache=4; cms=8; adaptive=2 ;;\n"
                "  *) exit 91 ;;\n"
                "esac\n"
                "destination=\"$AE4_RESULTS_ROOT/figure11/th${threshold}/${key}\"\n"
                "mkdir -p \"$destination\"\n"
                "{\n"
                "  printf 'order,method,label,normalized_performance\\n'\n"
                "  printf '1,cxl,CXL-only,1\\n'\n"
                "  printf '2,cache,CHMU-Cache,%s\\n' \"$cache\"\n"
                "  printf '3,cms,CHMU-CMS,%s\\n' \"$cms\"\n"
                "  printf '4,adaptive,Adaptive,%s\\n' \"$adaptive\"\n"
                "} > \"$destination/figure11_results.csv\"\n",
                encoding="utf-8",
            )
            fake_runner.chmod(0o755)

            results_root = artifact / "results"
            environment = os.environ.copy()
            environment.update(
                {
                    "AE4_RESULTS_ROOT": str(results_root),
                    "CALL_LOG": str(call_log),
                }
            )
            completed = subprocess.run(
                [
                    "bash",
                    str(fig11 / self.WRAPPER.name),
                    "--threshold",
                    "32",
                    "--dpi",
                    "72",
                ],
                cwd=artifact,
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

            calls = call_log.read_text(encoding="utf-8").splitlines()
            self.assertEqual([call.split()[0] for call in calls], ["bc_tw", "bfs_tw", "pr_tw"])
            for call in calls:
                self.assertIn("--threshold 32", call)
                self.assertIn("--method all", call)
                self.assertIn("--skip-benchmark", call)
                self.assertIn("--skip-plot", call)

            output_prefix = (
                results_root
                / "figure11"
                / "th32"
                / "figure11_primary_combined_normalized_performance"
            )
            self.assertGreater(output_prefix.with_suffix(".png").stat().st_size, 0)
            self.assertGreater(output_prefix.with_suffix(".pdf").stat().st_size, 0)


if __name__ == "__main__":
    unittest.main()
