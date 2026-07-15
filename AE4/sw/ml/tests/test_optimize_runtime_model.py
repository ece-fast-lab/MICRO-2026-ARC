from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import math
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ML_DIR = Path(__file__).resolve().parents[1]


def load_module(name: str, filename: str):
    spec = importlib.util.spec_from_file_location(name, ML_DIR / filename)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not load {filename}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


optimize = load_module("ae4_optimize_runtime_model", "optimize_runtime_model.py")


class EpochAndObjectiveTests(unittest.TestCase):
    def test_epoch_order_alternates_only_when_requested(self) -> None:
        expected = [
            (400000, 400001, False),
            (400001, 400000, True),
            (400000, 400001, False),
            (400001, 400000, True),
        ]
        actual = [
            optimize.resolve_epoch_order(400000, 400001, index, True)
            for index in range(1, 5)
        ]
        self.assertEqual(actual, expected)
        self.assertEqual(
            optimize.resolve_epoch_order(400000, 400001, 2, False),
            (400000, 400001, False),
        )

    def test_workload_and_study_helpers(self) -> None:
        self.assertEqual(optimize.build_workload_key("spec", "502", ""), "502")
        self.assertEqual(
            optimize.build_workload_key("gapbs", "pr", "twitter"),
            "pr_twitter",
        )
        self.assertEqual(
            optimize.resolve_study_name("pr_twitter", 400001, 400000),
            ("pr_twitter", "pr_twitter"),
        )
        self.assertEqual(
            optimize.resolve_study_name("pr_twitter", 800001, 800000),
            ("pr_twitter_800000_800001", "pr_twitter_800000_800001"),
        )

    def test_objective_parsers_select_the_final_result(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            gap_log = root / "pr_twitter.log"
            gap_log.write_text(
                "Trial Time: 7.0\nAverage Time: 8.5\nAverage Time: 7.25\n"
            )
            spec_log = root / "502.log"
            spec_log.write_text(
                "first; 700 total seconds elapsed\n"
                "runcpu finished; 650 total seconds elapsed\n"
            )

            self.assertEqual(optimize.parse_gapbs_average_time(gap_log), 7.25)
            self.assertEqual(optimize.parse_spec_total_seconds(spec_log), 650.0)
            self.assertEqual(
                optimize.parse_objective_value(gap_log, "gapbs"), 7.25
            )
            self.assertEqual(optimize.parse_objective_value(spec_log, "spec"), 650.0)

    def test_objective_parsers_reject_missing_target(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "incomplete.log"
            path.write_text("benchmark did not finish\n")
            with self.assertRaisesRegex(RuntimeError, "Average Time not found"):
                optimize.parse_gapbs_average_time(path)
            with self.assertRaisesRegex(RuntimeError, "total seconds elapsed not found"):
                optimize.parse_spec_total_seconds(path)


class HistoryValidationTests(unittest.TestCase):
    @staticmethod
    def record(index: int = 1, **overrides):
        record = {
            "trial_index": index,
            "return_code": 0,
            "suite": "gapbs",
            "benchmark": "bc",
            "db": "twitter",
            "th": 16,
            "average_time": 10.0,
            "model": optimize.load_model_template("bc_twitter"),
        }
        record.update(overrides)
        return record

    def validate(self, history) -> None:
        optimize.validate_existing_history(history, "gapbs", "bc", "twitter", 16)

    def test_valid_contiguous_success_history_is_accepted(self) -> None:
        self.validate([self.record(1), self.record(2), self.record(3)])

    def test_failed_history_is_rejected(self) -> None:
        with self.assertRaisesRegex(RuntimeError, "failed trial 1"):
            self.validate([self.record(return_code=1)])

    def test_noncontiguous_history_is_rejected(self) -> None:
        with self.assertRaisesRegex(RuntimeError, "contiguous from 1"):
            self.validate([self.record(1), self.record(3)])

    def test_workload_suite_database_and_threshold_mismatches_are_rejected(self) -> None:
        cases = [
            ({"suite": "spec"}, "workload mismatch"),
            ({"benchmark": "bfs"}, "workload mismatch"),
            ({"db": "web"}, "graph database mismatch"),
            ({"th": 32}, "threshold mismatch"),
        ]
        for overrides, message in cases:
            with self.subTest(overrides=overrides):
                with self.assertRaisesRegex(RuntimeError, message):
                    self.validate([self.record(**overrides)])

    def test_invalid_objective_or_missing_model_is_rejected(self) -> None:
        cases = [
            {"average_time": 0.0},
            {"average_time": -1.0},
            {"average_time": math.nan},
            {"model": None},
        ]
        for overrides in cases:
            with self.subTest(overrides=overrides):
                record = self.record(**overrides)
                if overrides == {"model": None}:
                    record.pop("model")
                with self.assertRaisesRegex(RuntimeError, "valid objective/model"):
                    self.validate([record])


class ConfigurationAndLogValidationTests(unittest.TestCase):
    def test_model_file_round_trip_has_complete_runtime_schema(self) -> None:
        model = optimize.load_model_template("pr_twitter")
        model["bw_scale"] = 3210.125
        model["consecutive_votes_required"] = 4
        model["consecutive_votes_required_weak"] = 4

        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "model.cfg"
            optimize.write_model_file(path, model)
            loaded = optimize.parse_model_file(path, "generic")
            lines = [line for line in path.read_text().splitlines() if line]

        expected_keys = {"key", *optimize.FLOAT_FIELDS, *optimize.INT_FIELDS}
        serialized_keys = {
            line.split("=", 1)[0] for line in lines if not line.startswith("#")
        }
        self.assertEqual(serialized_keys, expected_keys)
        self.assertEqual(len(lines), 2 + len(optimize.FLOAT_FIELDS) + len(optimize.INT_FIELDS))
        self.assertEqual(loaded["key"], "pr_twitter")
        self.assertAlmostEqual(loaded["bw_scale"], 3210.125)
        self.assertEqual(loaded["consecutive_votes_required"], 4)
        self.assertEqual(loaded["consecutive_votes_required_weak"], 5)
        self.assertEqual(
            len(optimize.vectorize_model(loaded)),
            len(optimize.FLOAT_FIELDS) + len(optimize.INT_FIELDS),
        )

    def test_runtime_summary_and_adaptive_log_validation(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            run_dir = Path(tmp)
            model_path = run_dir / "model.cfg"
            model_path.write_text("key=bc_twitter\n")
            (run_dir / "runtime_summary.txt").write_text(
                "WORKLOAD_PID=123 rc=0\n"
                "MIGRATION_MANAGER_PID=456 rc=0 failed=0\n"
                "BACKGROUND_CONTROL_FAILED=0\n"
                "TRACKER_DISABLE_FAILED=0\n"
            )
            manager_log = run_dir / "migration_manager.log"
            manager_log.write_text(
                f"[ml-predict] loaded model override from {model_path}\n"
                "[mode-switch] ML policy active: mode0(epoch=400000) "
                "vs mode1(epoch=400001)\n"
            )

            optimize.validate_runtime_summary(run_dir)
            optimize.validate_adaptive_manager_log(
                manager_log, model_path, 400000, 400001
            )

            manager_log.write_text(
                f"[ml-predict] loaded model override from {model_path}\n"
                "[mode-switch] ML policy active: mode0(epoch=400001) "
                "vs mode1(epoch=400000)\n"
            )
            with self.assertRaisesRegex(RuntimeError, "adaptive policy"):
                optimize.validate_adaptive_manager_log(
                    manager_log, model_path, 400000, 400001
                )


class TargetTrialSemanticsTests(unittest.TestCase):
    def test_target_already_met_does_not_call_hardware_runner(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            artifact = root / "AE4"
            benchmark_dir = artifact / "sw" / "benchmark"
            benchmark_dir.mkdir(parents=True)
            (benchmark_dir / "run_gapbs.sh").write_text("#!/usr/bin/env bash\n")

            output_root = root / "training"
            study = output_root / "th16" / "gapbs" / "bc_twitter"
            history_path = study / "history.jsonl"
            history_path.parent.mkdir(parents=True)
            record = {
                "trial_index": 1,
                "proposal_kind": "seed",
                "average_time": 10.0,
                "return_code": 0,
                "suite": "gapbs",
                "benchmark": "bc",
                "db": "twitter",
                "copies": 8,
                "th": 16,
                "input_epoch_a": 400000,
                "input_epoch_b": 400001,
                "mode0_epoch": 400000,
                "mode1_epoch": 400001,
                "order_swapped": False,
                "poll_ms": 1,
                "predictor_interval_ms": 10,
                "seed_model_path": "",
                "model_path": "models/trial_0001.cfg",
                "output_dir": "runs/trial_0001",
                "workload_log": "runs/trial_0001/bc_twitter.log",
                "manager_log": "runs/trial_0001/migration_manager.log",
                "feature_trace": "",
                "model": optimize.load_model_template("bc_twitter"),
            }
            history_path.write_text(json.dumps(record) + "\n")

            argv = [
                "optimize_runtime_model.py",
                "--artifact-dir",
                str(artifact),
                "--output-root",
                str(output_root),
                "--suite",
                "gapbs",
                "--benchmark",
                "bc",
                "--db",
                "twitter",
                "--threshold",
                "16",
                "--target-trials",
                "1",
            ]
            with mock.patch.object(sys, "argv", argv), mock.patch.object(
                optimize, "maybe_import_sklearn", return_value=object()
            ), mock.patch.object(
                optimize,
                "run_trial",
                side_effect=AssertionError("hardware runner must not be called"),
            ) as run_trial, contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(optimize.main(), 0)

            run_trial.assert_not_called()
            self.assertEqual(len(history_path.read_text().splitlines()), 1)


if __name__ == "__main__":
    unittest.main()

