from __future__ import annotations

import csv
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path


ML_DIR = Path(__file__).resolve().parents[1]


def load_module(name: str, filename: str):
    spec = importlib.util.spec_from_file_location(name, ML_DIR / filename)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not load {filename}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


lobo = load_module("ae4_leave_one_benchmark_rf_cfg", "leave_one_benchmark_rf_cfg.py")


def trial_row(
    benchmark: str,
    trial_index: int,
    average_time: float,
    normalized_time: float,
    return_code=0,
):
    return lobo.TrialRow(
        benchmark=benchmark,
        trial_index=trial_index,
        average_time=average_time,
        normalized_time=normalized_time,
        seed_time=average_time / normalized_time,
        proposal_kind="seed" if trial_index == 1 else "rf-surrogate",
        return_code=return_code,
        params=lobo.normalize_model({}),
    )


class SuiteIsolationTests(unittest.TestCase):
    def test_filter_benchmarks_keeps_suites_disjoint(self) -> None:
        benchmarks = ["502", "505", "bc_twitter", "pr_web"]
        self.assertEqual(lobo.filter_benchmarks(benchmarks, "spec"), ["502", "505"])
        self.assertEqual(
            lobo.filter_benchmarks(benchmarks, "gap"),
            ["bc_twitter", "pr_web"],
        )
        self.assertEqual(
            lobo.filter_benchmarks(benchmarks, "pr_web,bc_twitter"),
            ["bc_twitter", "pr_web"],
        )
        with self.assertRaisesRegex(ValueError, "Unknown benchmark"):
            lobo.filter_benchmarks(benchmarks, "missing")

    def test_json_history_loader_never_crosses_suite_boundary(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            training = root / "ml_training"
            records = {
                "502": [(100.0, 1), (90.0, 2)],
                "bc_twitter": [(20.0, 1), (18.0, 2)],
            }
            for benchmark, values in records.items():
                directory = training / benchmark
                directory.mkdir(parents=True)
                history = []
                for average_time, index in values:
                    history.append(
                        json.dumps(
                            {
                                "trial_index": index,
                                "average_time": average_time,
                                "return_code": 0,
                                "proposal_kind": "seed",
                                "model": {},
                            }
                        )
                    )
                (directory / "history.jsonl").write_text("\n".join(history) + "\n")

            spec_benchmarks, spec_rows = lobo.load_trials(root, "spec")
            gap_benchmarks, gap_rows = lobo.load_trials(root, "gap")

        self.assertEqual(spec_benchmarks, ["502"])
        self.assertEqual({row.benchmark for row in spec_rows}, {"502"})
        self.assertEqual([row.normalized_time for row in spec_rows], [1.0, 0.9])
        self.assertEqual(gap_benchmarks, ["bc_twitter"])
        self.assertEqual({row.benchmark for row in gap_rows}, {"bc_twitter"})
        self.assertEqual([row.normalized_time for row in gap_rows], [1.0, 0.9])


class CsvLoaderTests(unittest.TestCase):
    def test_dataset_csv_round_trip_and_suite_filter(self) -> None:
        source_rows = [
            trial_row("502", 1, 100.0, 1.0, None),
            trial_row("505", 1, 200.0, 1.0, 0),
            trial_row("bc_twitter", 1, 20.0, 1.0, 0),
        ]
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "trials.csv"
            lobo.write_dataset(source_rows, path)
            spec_benchmarks, spec_rows = lobo.load_trials_csv(path, "spec")
            gap_benchmarks, gap_rows = lobo.load_trials_csv(path, "gap")

        self.assertEqual(spec_benchmarks, ["502", "505"])
        self.assertEqual([row.benchmark for row in spec_rows], ["502", "505"])
        self.assertIsNone(spec_rows[0].return_code)
        self.assertEqual(spec_rows[1].return_code, 0)
        self.assertEqual(gap_benchmarks, ["bc_twitter"])
        self.assertEqual([row.benchmark for row in gap_rows], ["bc_twitter"])
        self.assertEqual(set(spec_rows[0].params), set(lobo.PARAM_FIELDS))

    def test_csv_loader_rejects_empty_or_incomplete_input(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            empty = root / "empty.csv"
            empty.write_text("benchmark,trial_index\n")
            with self.assertRaisesRegex(ValueError, "no trial rows"):
                lobo.load_trials_csv(empty, "spec")

            incomplete = root / "incomplete.csv"
            with incomplete.open("w", newline="") as handle:
                writer = csv.DictWriter(
                    handle, fieldnames=["benchmark", "trial_index", "average_time"]
                )
                writer.writeheader()
                writer.writerow(
                    {"benchmark": "502", "trial_index": "1", "average_time": "1"}
                )
            with self.assertRaisesRegex(ValueError, "missing columns"):
                lobo.load_trials_csv(incomplete, "spec")


class ConfigurationSchemaTests(unittest.TestCase):
    def test_normalization_clamps_fields_and_preserves_vote_order(self) -> None:
        params = lobo.normalize_model(
            {
                "bw_scale": -1,
                "ipc_scale": 100,
                "consecutive_votes_required": 9,
                "consecutive_votes_required_weak": 1,
            }
        )
        self.assertEqual(params["bw_scale"], lobo.PARAM_BOUNDS["bw_scale"][0])
        self.assertEqual(params["ipc_scale"], lobo.PARAM_BOUNDS["ipc_scale"][1])
        self.assertEqual(params["consecutive_votes_required"], 5.0)
        self.assertEqual(params["consecutive_votes_required_weak"], 6.0)
        self.assertEqual(set(params), set(lobo.PARAM_FIELDS))

    def test_cfg_serialization_has_exact_manager_schema(self) -> None:
        params = lobo.normalize_model({"bias": 0.125, "score_margin": 0.375})
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "rank_01.cfg"
            lobo.write_cfg(path, params, "pr_twitter")
            lines = path.read_text().splitlines()

        entries = {}
        for line in lines:
            if not line or line.startswith("#"):
                continue
            key, value = line.split("=", 1)
            entries[key] = value
        self.assertEqual(
            set(entries),
            {"key", *lobo.FLOAT_FIELDS, *lobo.INT_FIELDS},
        )
        self.assertEqual(entries["key"], "pr_twitter")
        self.assertEqual(entries["bias"], "0.12500000")
        self.assertEqual(entries["score_margin"], "0.37500000")
        for field in lobo.INT_FIELDS:
            self.assertRegex(entries[field], r"^[0-9]+$")

    def test_row_matrix_contains_only_cfg_features_and_target(self) -> None:
        rows = [
            trial_row("502", 1, 100.0, 1.0),
            trial_row("bc_twitter", 1, 20.0, 0.8),
        ]
        matrix, target = lobo.row_matrix(rows)
        self.assertEqual(matrix.shape, (2, len(lobo.PARAM_FIELDS)))
        self.assertEqual(target.tolist(), [1.0, 0.8])


if __name__ == "__main__":
    unittest.main()

