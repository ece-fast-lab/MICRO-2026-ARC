#!/usr/bin/env python3

from __future__ import annotations

import csv
import math
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


FIG3_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(FIG3_DIR))

from collect_results import (  # noqa: E402
    CollectionError,
    collect_results,
    parse_gapbs_log,
    parse_spec_log,
)
from plot_figure3 import PlotRow, load_results, make_plot, plt  # noqa: E402


class LogParserTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name)

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def write_log(self, name: str, contents: str) -> Path:
        path = self.root / name
        path.write_text(contents, encoding="utf-8")
        return path

    def test_gapbs_uses_geomean_of_last_five_trials(self) -> None:
        values = [1, 2, 3, 4, 5, 10, 20, 40, 80, 160]
        log = self.write_log(
            "gap.log",
            "header\n"
            + "\n".join(f"Trial Time: {value}" for value in values)
            + "\nfooter\n",
        )
        parsed = parse_gapbs_log(log)
        expected = math.exp(sum(math.log(value) for value in values[-5:]) / 5)
        self.assertAlmostEqual(parsed.seconds, expected)
        self.assertEqual(tuple(values), parsed.trial_values)
        self.assertEqual(tuple(values[-5:]), parsed.selected_trial_values)

    def test_gapbs_requires_exactly_ten_anchored_trials(self) -> None:
        log = self.write_log(
            "gap_bad.log",
            "\n".join(["prefix Trial Time: 99"] + ["Trial Time: 1"] * 9),
        )
        with self.assertRaisesRegex(CollectionError, "exactly 10"):
            parse_gapbs_log(log)

    def test_gapbs_rejects_nonpositive_trial(self) -> None:
        log = self.write_log(
            "gap_zero.log",
            "\n".join(["Trial Time: 1"] * 9 + ["Trial Time: 0"]),
        )
        with self.assertRaisesRegex(CollectionError, "positive and finite"):
            parse_gapbs_log(log)

    def test_spec_requires_completion_and_one_elapsed_marker(self) -> None:
        valid = self.write_log(
            "spec.log",
            "SPEC output\nRun Complete\n"
            "runcpu finished at now; 650 total seconds elapsed\n",
        )
        self.assertEqual(parse_spec_log(valid).seconds, 650.0)

        incomplete = self.write_log(
            "spec_incomplete.log", "runcpu; 650 total seconds elapsed\n"
        )
        with self.assertRaisesRegex(CollectionError, "Run Complete"):
            parse_spec_log(incomplete)

        duplicate = self.write_log(
            "spec_duplicate.log",
            "Run Complete\na; 1 total seconds elapsed\nb; 2 total seconds elapsed\n",
        )
        with self.assertRaisesRegex(CollectionError, "exactly one"):
            parse_spec_log(duplicate)


class CollectionTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name)

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def _gap_log(self, name: str, seconds: float) -> Path:
        path = self.root / name
        path.write_text(
            "\n".join(f"Trial Time: {seconds}" for _ in range(10)) + "\n",
            encoding="utf-8",
        )
        return path

    def test_collect_normalizes_to_the_single_baseline(self) -> None:
        self._gap_log("baseline.log", 100.0)
        self._gap_log("cache.log", 50.0)
        manifest = self.root / "manifest.csv"
        manifest.write_text(
            "order,suite,benchmark,dataset,method,policy,threshold,epoch_a,"
            "epoch_b,log_path,label\n"
            "2,gapbs,pr,twitter,mig,cache,32,400000,400000,cache.log,Cache-32\n"
            "1,gapbs,pr,twitter,baseline,baseline,16,400000,400000,"
            "baseline.log,Baseline\n",
            encoding="utf-8",
        )
        output = self.root / "results.csv"

        self.assertEqual(collect_results("gapbs", manifest, output), 2)
        with output.open("r", encoding="utf-8", newline="") as output_file:
            rows = list(csv.DictReader(output_file))

        self.assertEqual([row["policy"] for row in rows], ["baseline", "cache"])
        self.assertEqual(float(rows[0]["normalized_performance"]), 1.0)
        self.assertEqual(float(rows[1]["normalized_performance"]), 2.0)
        self.assertEqual(float(rows[1]["normalized_runtime"]), 0.5)
        self.assertEqual(rows[1]["selected_trial_values_seconds"], "50|50|50|50|50")
        self.assertEqual(len(rows[1]["log_sha256"]), 64)
        self.assertEqual(rows[1]["manifest_log_path"], "cache.log")
        self.assertTrue(Path(rows[1]["resolved_log_path"]).is_absolute())

        png_path, pdf_path = make_plot(
            load_results(output), self.root / "figure3", "Unit test", 72
        )
        self.assertGreater(png_path.stat().st_size, 0)
        self.assertGreater(pdf_path.stat().st_size, 0)

    def test_collect_requires_exactly_one_baseline(self) -> None:
        self._gap_log("cache.log", 50.0)
        manifest = self.root / "manifest.csv"
        manifest.write_text(
            "order,suite,benchmark,dataset,method,policy,threshold,epoch_a,"
            "epoch_b,log_path,label\n"
            "1,gapbs,pr,twitter,mig,cache,32,400000,400000,cache.log,Cache-32\n",
            encoding="utf-8",
        )
        with self.assertRaisesRegex(CollectionError, "exactly one baseline"):
            collect_results("gapbs", manifest, self.root / "out.csv")


class PlotLayoutTests(unittest.TestCase):
    def test_title_legend_and_axes_have_separate_vertical_regions(self) -> None:
        rows = [
            PlotRow(1, "Baseline", "baseline", 16, 1.00),
            PlotRow(2, "ANB", "anb", 16, 1.10),
            PlotRow(3, "DAMON", "damon", 16, 1.20),
            PlotRow(4, "Cache-16", "cache", 16, 1.30),
            PlotRow(5, "Cache-32", "cache", 32, 1.40),
            PlotRow(6, "Cache-64", "cache", 64, 1.50),
            PlotRow(7, "Cache-96", "cache", 96, 1.60),
            PlotRow(8, "CMS-16", "cms", 16, 1.70),
            PlotRow(9, "CMS-32", "cms", 32, 1.80),
            PlotRow(10, "CMS-64", "cms", 64, 1.90),
            PlotRow(11, "CMS-96", "cms", 96, 2.00),
        ]

        with tempfile.TemporaryDirectory() as temporary_directory:
            with patch.object(plt, "close") as mocked_close:
                make_plot(
                    rows,
                    Path(temporary_directory) / "figure3_layout",
                    "Figure 3: GAPBS pr (twitter)",
                    72,
                )
                figure = plt.gcf()
                mocked_close.assert_called_once_with(figure)

            try:
                figure.canvas.draw()
                renderer = figure.canvas.get_renderer()
                self.assertIsNotNone(figure._suptitle)
                self.assertEqual(len(figure.legends), 1)
                title_box = figure._suptitle.get_window_extent(renderer)
                legend_box = figure.legends[0].get_window_extent(renderer)
                axes_box = figure.axes[0].get_window_extent(renderer)
                self.assertFalse(title_box.overlaps(legend_box))
                self.assertFalse(legend_box.overlaps(axes_box))
            finally:
                plt.close(figure)


if __name__ == "__main__":
    unittest.main()
