from __future__ import annotations

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


validator = load_module(
    "ae4_validate_training_histories", "validate_training_histories.py"
)


class StrictHistoryValidationTests(unittest.TestCase):
    def make_history(self, root: Path, **overrides) -> Path:
        run_dir = root / "runs" / "trial_0001"
        run_dir.mkdir(parents=True)
        workload_log = run_dir / "bc_twitter.log"
        manager_log = run_dir / "migration_manager.log"
        workload_log.write_text("Trial Time: 1.0\n")
        manager_log.write_text("manager complete\n")
        model = {field: 1.0 for field in validator.MODEL_FIELDS}
        model["key"] = "bc_twitter"
        model["consecutive_votes_required"] = 2
        model["consecutive_votes_required_weak"] = 3
        record = {
            "trial_index": 1,
            "return_code": 0,
            "suite": "gapbs",
            "benchmark": "bc",
            "db": "twitter",
            "th": 16,
            "input_epoch_a": 400000,
            "input_epoch_b": 400001,
            "mode0_epoch": 400000,
            "mode1_epoch": 400001,
            "order_swapped": False,
            "poll_ms": 1,
            "predictor_interval_ms": 10,
            "average_time": 1.0,
            "model": model,
            "hostname": "spr1",
            "kernel_release": "6.11.0-mig-offload+",
            "output_dir": str(run_dir),
            "workload_log": str(workload_log),
            "manager_log": str(manager_log),
        }
        record.update(overrides)
        history = root / "history.jsonl"
        history.write_text(json.dumps(record) + "\n")
        return history

    def test_accepts_complete_current_system_row(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            history = self.make_history(Path(tmp))
            identity = validator.validate_history(
                history, "gapbs", "bc_twitter", "bc", "twitter", 16, 1
            )
        self.assertEqual(identity, ("spr1", "6.11.0-mig-offload+"))

    def test_rejects_missing_provenance_and_wrong_epoch_order(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            history = self.make_history(Path(tmp), hostname="")
            with self.assertRaisesRegex(ValueError, "provenance is missing"):
                validator.validate_history(
                    history, "gapbs", "bc_twitter", "bc", "twitter", 16, 1
                )
        with tempfile.TemporaryDirectory() as tmp:
            history = self.make_history(Path(tmp), mode0_epoch=400001)
            with self.assertRaisesRegex(ValueError, "epoch order"):
                validator.validate_history(
                    history, "gapbs", "bc_twitter", "bc", "twitter", 16, 1
                )


if __name__ == "__main__":
    unittest.main()
