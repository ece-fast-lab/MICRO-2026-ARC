#!/usr/bin/env python3

from __future__ import annotations

import csv
import math
import sys
import tempfile
import unittest
from pathlib import Path


SPEC_FIG11_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SPEC_FIG11_DIR))

from collect_spec_results import (  # noqa: E402
    CollectionError,
    collect_results,
    parse_spec_log,
)


class SpecCollectorTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name)

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def write_log(
        self, name: str, final_seconds: float, earlier_seconds: float = 9999.0
    ) -> Path:
        path = self.root / name
        path.write_text(
            "SPEC header\n"
            "Run Complete\n"
            f"earlier result; {earlier_seconds} total seconds elapsed\n"
            f"runcpu finished; {final_seconds} total seconds elapsed\n",
            encoding="utf-8",
        )
        return path

    def build_manifest(self) -> Path:
        methods = (
            (1, "cxl", "CXL-only", 100.0),
            (2, "cache", "CHMU-Cache", 50.0),
            (3, "cms", "CHMU-CMS", 80.0),
            (4, "adaptive", "Adaptive", 40.0),
        )
        rows = []
        for order, method, label, seconds in methods:
            for repeat in range(1, 6):
                log_name = f"{method}_{repeat}.log"
                self.write_log(log_name, seconds)
                rows.append((order, repeat, method, label, log_name))
        manifest = self.root / "manifest.csv"
        with manifest.open("w", encoding="utf-8", newline="") as output:
            writer = csv.writer(output)
            writer.writerow(("order", "repeat", "method", "label", "log_path"))
            writer.writerows(reversed(rows))
        return manifest

    def test_parser_selects_final_anchored_runtime(self) -> None:
        log = self.root / "502.log"
        log.write_text(
            "Run Complete\n"
            "first; 999 total seconds elapsed\n"
            "not selected; 888 total seconds elapsed trailing text\n"
            "runcpu finished; 12.5 total seconds elapsed\n",
            encoding="utf-8",
        )
        parsed = parse_spec_log(log)
        self.assertEqual(parsed.runtime_values, (999.0, 12.5))
        self.assertEqual(parsed.selected_value, 12.5)

    def test_parser_requires_completion_and_positive_runtime(self) -> None:
        missing_complete = self.root / "missing_complete.log"
        missing_complete.write_text(
            "runcpu finished; 1 total seconds elapsed\n", encoding="utf-8"
        )
        with self.assertRaisesRegex(CollectionError, "Run Complete"):
            parse_spec_log(missing_complete)

        negative = self.root / "negative.log"
        negative.write_text(
            "Run Complete\nruncpu finished; -1 total seconds elapsed\n",
            encoding="utf-8",
        )
        with self.assertRaisesRegex(CollectionError, "positive and finite"):
            parse_spec_log(negative)

    def test_collects_five_final_samples_and_normalizes(self) -> None:
        manifest = self.build_manifest()
        summary = self.root / "summary.csv"
        samples = self.root / "samples.csv"
        self.assertEqual(collect_results(manifest, summary, samples), 4)

        with summary.open(encoding="utf-8", newline="") as summary_file:
            rows = list(csv.DictReader(summary_file))
        with samples.open(encoding="utf-8", newline="") as samples_file:
            sample_rows = list(csv.DictReader(samples_file))

        self.assertEqual(
            [row["method"] for row in rows], ["cxl", "cache", "cms", "adaptive"]
        )
        self.assertEqual(len(sample_rows), 20)
        self.assertTrue(all(row["selected_sample_count"] == "5" for row in rows))
        self.assertTrue(
            all(row["total_runtime_match_count"] == "10" for row in rows)
        )
        self.assertTrue(
            all(row["selected_runtime_match_position"] == "2" for row in sample_rows)
        )
        by_method = {row["method"]: row for row in rows}
        self.assertTrue(
            math.isclose(float(by_method["cxl"]["normalized_performance"]), 1.0)
        )
        self.assertTrue(
            math.isclose(float(by_method["cache"]["normalized_performance"]), 2.0)
        )
        self.assertTrue(
            math.isclose(float(by_method["cms"]["normalized_performance"]), 1.25)
        )
        self.assertTrue(
            math.isclose(
                float(by_method["adaptive"]["normalized_performance"]), 2.5
            )
        )


if __name__ == "__main__":
    unittest.main()
