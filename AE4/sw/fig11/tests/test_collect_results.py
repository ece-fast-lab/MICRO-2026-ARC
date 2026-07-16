#!/usr/bin/env python3

from __future__ import annotations

import csv
import math
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


FIG11_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(FIG11_DIR))

from collect_results import (  # noqa: E402
    CollectionError,
    collect_results,
    parse_gapbs_log,
)
from plot_figure11 import PlotRow, load_results, make_plot  # noqa: E402
from plot_figure11 import plt  # noqa: E402


class Figure11TestCase(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name)

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def write_log(
        self, name: str, selected_value: float, warmup_value: float = 999.0
    ) -> Path:
        path = self.root / name
        values = [warmup_value] * 5 + [selected_value] * 5
        path.write_text(
            "GAPBS header\n"
            + "\n".join(f"Trial Time: {value}" for value in values)
            + "\nGAPBS footer\n",
            encoding="utf-8",
        )
        return path

    def build_manifest(
        self,
        methods: list[tuple[int, str, str, float]],
        omit: tuple[str, int] | None = None,
        duplicate: tuple[str, int] | None = None,
    ) -> Path:
        rows = []
        for order, method, label, seconds in methods:
            for repeat in range(1, 6):
                if omit == (method, repeat):
                    continue
                log_name = f"{method}_rep{repeat}.log"
                self.write_log(log_name, seconds, warmup_value=seconds * 100)
                rows.append((order, repeat, method, label, log_name))
            if duplicate is not None and duplicate[0] == method:
                repeat = duplicate[1]
                log_name = f"{method}_duplicate_rep{repeat}.log"
                self.write_log(log_name, seconds)
                rows.append((order, repeat, method, label, log_name))

        manifest = self.root / "manifest.csv"
        with manifest.open("w", encoding="utf-8", newline="") as output_file:
            writer = csv.writer(output_file)
            writer.writerow(("order", "repeat", "method", "label", "log_path"))
            # Reverse physical row order to prove that numeric method order wins.
            writer.writerows(reversed(rows))
        return manifest

    @staticmethod
    def default_methods() -> list[tuple[int, str, str, float]]:
        return [
            (1, "cxl", "CXL-only", 100.0),
            (2, "cache", "CHMU-Cache", 50.0),
            (3, "cms", "CHMU-CMS", 80.0),
            (
                4,
                "adaptive_400000_400001",
                "Adaptive 400000/400001",
                40.0,
            ),
            (
                5,
                "adaptive_400001_400000",
                "Adaptive 400001/400000",
                60.0,
            ),
        ]


class LogParserTests(Figure11TestCase):
    def test_selects_positions_six_through_ten(self) -> None:
        log = self.root / "positioned.log"
        values = list(range(1, 11))
        log.write_text(
            "\n".join(f"Trial Time: {value}" for value in values) + "\n",
            encoding="utf-8",
        )
        parsed = parse_gapbs_log(log)
        self.assertEqual(tuple(float(value) for value in values), parsed.trial_values)
        self.assertEqual((6.0, 7.0, 8.0, 9.0, 10.0), parsed.selected_values)

    def test_rejects_fewer_or_extra_trials(self) -> None:
        for count in (9, 11):
            with self.subTest(count=count):
                log = self.root / f"count_{count}.log"
                log.write_text(
                    "\n".join("Trial Time: 1" for _ in range(count)) + "\n",
                    encoding="utf-8",
                )
                with self.assertRaisesRegex(CollectionError, "exactly 10"):
                    parse_gapbs_log(log)

    def test_rejects_zero_and_negative_trials(self) -> None:
        for bad_value in (0, -1):
            with self.subTest(bad_value=bad_value):
                log = self.root / f"nonpositive_{bad_value}.log"
                values = [1] * 9 + [bad_value]
                log.write_text(
                    "\n".join(f"Trial Time: {value}" for value in values) + "\n",
                    encoding="utf-8",
                )
                with self.assertRaisesRegex(CollectionError, "positive and finite"):
                    parse_gapbs_log(log)


class CollectionTests(Figure11TestCase):
    def test_collects_twenty_five_samples_per_method_and_normalizes(self) -> None:
        manifest = self.build_manifest(self.default_methods())
        summary = self.root / "summary.csv"
        samples = self.root / "samples.csv"

        self.assertEqual(collect_results(manifest, summary, samples), 4)
        with summary.open("r", encoding="utf-8", newline="") as summary_file:
            summary_rows = list(csv.DictReader(summary_file))
        with samples.open("r", encoding="utf-8", newline="") as samples_file:
            sample_rows = list(csv.DictReader(samples_file))

        self.assertEqual(
            [row["method"] for row in summary_rows],
            ["cxl", "cache", "cms", "adaptive"],
        )
        self.assertEqual(len(sample_rows), 125)
        self.assertTrue(
            all(int(row["selected_sample_count"]) == 25 for row in summary_rows)
        )
        self.assertTrue(all(int(row["total_trial_count"]) == 50 for row in summary_rows))
        self.assertEqual(
            {int(row["trial_position"]) for row in sample_rows}, {6, 7, 8, 9, 10}
        )
        self.assertFalse(any(float(row["seconds"]) >= 1000 for row in sample_rows))

        by_method = {row["method"]: row for row in summary_rows}
        self.assertAlmostEqual(float(by_method["cxl"]["geomean_seconds"]), 100.0)
        self.assertAlmostEqual(
            float(by_method["cxl"]["normalized_performance"]), 1.0
        )
        self.assertAlmostEqual(
            float(by_method["cache"]["normalized_performance"]), 2.0
        )
        self.assertAlmostEqual(
            float(by_method["cms"]["normalized_performance"]), 1.25
        )
        self.assertAlmostEqual(
            float(by_method["adaptive"]["normalized_performance"]), 2.5
        )
        self.assertEqual(
            by_method["adaptive"]["selected_adaptive_direction"],
            "adaptive_400000_400001",
        )
        self.assertAlmostEqual(
            float(
                by_method["adaptive"][
                    "adaptive_400000_400001_geomean_seconds"
                ]
            ),
            40.0,
        )
        self.assertAlmostEqual(
            float(
                by_method["adaptive"][
                    "adaptive_400001_400000_geomean_seconds"
                ]
            ),
            60.0,
        )
        adaptive_samples = [
            row for row in sample_rows if row["method"].startswith("adaptive_")
        ]
        self.assertEqual(len(adaptive_samples), 50)
        self.assertEqual(
            {
                row["method"]
                for row in adaptive_samples
                if row["selected_for_adaptive_bar"] == "yes"
            },
            {"adaptive_400000_400001"},
        )
        self.assertEqual(
            {
                row["method"]
                for row in adaptive_samples
                if row["selected_for_adaptive_bar"] == "no"
            },
            {"adaptive_400001_400000"},
        )

    def test_geomean_is_over_all_twenty_five_selected_samples(self) -> None:
        methods = self.default_methods()
        manifest = self.build_manifest(methods)
        # Give each CXL repeat a different selected value: five samples per value.
        cxl_values = [10.0, 20.0, 40.0, 80.0, 160.0]
        for repeat, value in enumerate(cxl_values, start=1):
            self.write_log(f"cxl_rep{repeat}.log", value)

        summary = self.root / "summary.csv"
        collect_results(manifest, summary, self.root / "samples.csv")
        with summary.open("r", encoding="utf-8", newline="") as summary_file:
            rows = {row["method"]: row for row in csv.DictReader(summary_file)}
        expected = math.exp(sum(math.log(value) for value in cxl_values) / 5)
        self.assertAlmostEqual(float(rows["cxl"]["geomean_seconds"]), expected)

    def test_reverse_adaptive_direction_wins_when_its_geomean_is_lower(self) -> None:
        methods = self.default_methods()
        methods[-2] = (
            4,
            "adaptive_400000_400001",
            "Adaptive 400000/400001",
            70.0,
        )
        methods[-1] = (
            5,
            "adaptive_400001_400000",
            "Adaptive 400001/400000",
            35.0,
        )
        manifest = self.build_manifest(methods)
        summary = self.root / "summary.csv"
        samples = self.root / "samples.csv"
        collect_results(manifest, summary, samples)

        with summary.open("r", encoding="utf-8", newline="") as summary_file:
            adaptive = next(
                row for row in csv.DictReader(summary_file)
                if row["method"] == "adaptive"
            )
        self.assertEqual(
            adaptive["selected_adaptive_direction"],
            "adaptive_400001_400000",
        )
        self.assertAlmostEqual(float(adaptive["geomean_seconds"]), 35.0)
        self.assertAlmostEqual(float(adaptive["normalized_performance"]), 100 / 35)

        with samples.open("r", encoding="utf-8", newline="") as samples_file:
            sample_rows = list(csv.DictReader(samples_file))
        chosen = {
            row["method"]
            for row in sample_rows
            if row["selected_for_adaptive_bar"] == "yes"
        }
        self.assertEqual(chosen, {"adaptive_400001_400000"})

    def test_adaptive_tie_deterministically_selects_forward_direction(self) -> None:
        methods = self.default_methods()
        methods[-1] = (
            5,
            "adaptive_400001_400000",
            "Adaptive 400001/400000",
            40.0,
        )
        manifest = self.build_manifest(methods)
        summary = self.root / "summary.csv"
        collect_results(manifest, summary, self.root / "samples.csv")
        with summary.open("r", encoding="utf-8", newline="") as summary_file:
            adaptive = next(
                row for row in csv.DictReader(summary_file)
                if row["method"] == "adaptive"
            )
        self.assertEqual(
            adaptive["selected_adaptive_direction"],
            "adaptive_400000_400001",
        )

    def test_rejects_missing_repeat(self) -> None:
        manifest = self.build_manifest(
            self.default_methods(), omit=("adaptive_400001_400000", 5)
        )
        with self.assertRaisesRegex(CollectionError, "repeats 1..5"):
            collect_results(manifest, self.root / "summary.csv", self.root / "samples.csv")

    def test_rejects_duplicate_repeat(self) -> None:
        manifest = self.build_manifest(
            self.default_methods(), duplicate=("cms", 3)
        )
        with self.assertRaisesRegex(CollectionError, "duplicate repeat 3"):
            collect_results(manifest, self.root / "summary.csv", self.root / "samples.csv")

    def test_optional_local_method_and_plot(self) -> None:
        methods = [(1, "local", "Local-only", 30.0)] + [
            (order + 1, method, label, seconds)
            for order, method, label, seconds in self.default_methods()
        ]
        manifest = self.build_manifest(methods)
        summary = self.root / "summary.csv"
        collect_results(manifest, summary, self.root / "samples.csv")

        rows = load_results(summary)
        self.assertEqual(
            [row.method for row in rows],
            ["local", "cxl", "cache", "cms", "adaptive"],
        )
        png_path, pdf_path = make_plot(
            rows, self.root / "figure11", "Synthetic Figure 11", 72
        )
        self.assertGreater(png_path.stat().st_size, 0)
        self.assertGreater(pdf_path.stat().st_size, 0)


class PlotLayoutTests(unittest.TestCase):
    @staticmethod
    def rows() -> list[PlotRow]:
        return [
            PlotRow(1, "local", "Local-only", 1.40),
            PlotRow(2, "cxl", "CXL-only", 1.00),
            PlotRow(3, "cache", "CHMU-Cache", 1.25),
            PlotRow(4, "cms", "CHMU-CMS", 1.30),
            PlotRow(5, "adaptive", "Adaptive", 1.50),
        ]

    def test_title_legend_and_axes_have_separate_vertical_regions(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            with patch.object(plt, "close") as mocked_close:
                png_path, pdf_path = make_plot(
                    self.rows(),
                    Path(temporary_directory) / "figure11_layout",
                    "Figure 11: GAPBS pr (twitter), threshold 16",
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
            finally:
                plt.close(figure)

    def test_legend_stays_clear_of_axes_without_title(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            with patch.object(plt, "close"):
                make_plot(
                    self.rows()[1:],
                    Path(temporary_directory) / "figure11_no_title",
                    None,
                    72,
                )
                figure = plt.gcf()

            try:
                figure.canvas.draw()
                renderer = figure.canvas.get_renderer()
                self.assertIsNone(figure._suptitle)
                self.assertEqual(len(figure.legends), 1)
                legend_box = figure.legends[0].get_window_extent(renderer)
                axes_box = figure.axes[0].get_window_extent(renderer)
                self.assertFalse(legend_box.overlaps(axes_box))
            finally:
                plt.close(figure)


if __name__ == "__main__":
    unittest.main()
