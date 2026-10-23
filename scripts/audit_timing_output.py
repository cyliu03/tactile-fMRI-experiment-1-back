"""Read-only consistency checks for a new timing summary and its adjacent logs."""
import argparse
import csv
import json
import math
from pathlib import Path


def read_rows(path):
    with path.open(encoding="utf-8-sig", newline="") as stream:
        return list(csv.DictReader(stream, delimiter="\t"))


def audit(summary_path):
    summary_path = Path(summary_path)
    summary = json.loads(summary_path.read_text(encoding="utf-8-sig"))
    prefix = summary_path.name.removesuffix("_timing_summary.json")
    phases = read_rows(summary_path.with_name(prefix + "_timing.tsv"))
    frames = read_rows(summary_path.with_name(prefix + "_frames.tsv"))
    if not phases:
        assert summary["aborted"]
        return {"summary": str(summary_path), "aborted_before_first_phase": True}
    shown = [row for row in phases if row["phase"] != "run_end"]
    for row in shown:
        start = float(row["vbl_s"])
        end = float(row["actual_end_s"])
        duration = float(row["actual_duration_s"])
        assert math.isfinite(duration) and duration >= 0
        assert abs(end - start - duration) < 1e-6
        assert abs(duration - float(row["planned_duration_s"]) - float(row["duration_error_s"])) < 1e-6
    for previous, following in zip(shown, shown[1:]):
        assert abs(float(previous["actual_end_s"]) - float(following["vbl_s"])) < 1e-6
    if summary["end_measured_by_flip"]:
        assert phases[-1]["phase"] == "run_end"
        assert abs(float(phases[-1]["vbl_s"]) - summary["actual_seconds"]) < 1e-6
    assert abs(float(shown[-1]["actual_end_s"]) - summary["actual_seconds"]) < 1e-6
    assert abs(sum(float(r["actual_duration_s"]) for r in shown)
               + float(shown[0]["vbl_s"]) - summary["actual_seconds"]) < 1e-6
    dropped = sum(float(r["action"]) == 1 and float(r["displayed"]) == 0 for r in frames)
    assert dropped == summary["dropped_video_frames"]
    late = sum(float(r["late_onset"]) > 0 for r in phases)
    assert late == summary["late_phase_count"]
    return {
        "summary": str(summary_path),
        "backend": summary["backend"],
        "planned_seconds": summary["planned_seconds"],
        "actual_seconds": summary["actual_seconds"],
        "schedule_extension_s": summary["schedule_extension_s"],
        "late_phases": late,
        "dropped_video_frames": dropped,
        "timing_valid": summary["timing_valid"],
        "phase_coverage_consistent": True,
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("summary", type=Path, nargs="+")
    args = parser.parse_args()
    for item in args.summary:
        print(json.dumps(audit(item), ensure_ascii=False))
