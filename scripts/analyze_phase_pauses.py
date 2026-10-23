"""Read-only localization of phase-transition pauses and slow frame operations."""
import argparse
import csv
import json
import math
from pathlib import Path
from statistics import median


def rows(path):
    with path.open(encoding="utf-8-sig", newline="") as stream:
        return list(csv.DictReader(stream, delimiter="\t"))


def number(row, key):
    value = float(row.get(key, "nan"))
    return value if math.isfinite(value) else None


def difference(row, end, start):
    a, b = number(row, end), number(row, start)
    return a - b if a is not None and b is not None else None


def analyze(summary_path):
    summary_path = Path(summary_path)
    summary = json.loads(summary_path.read_text(encoding="utf-8-sig"))
    prefix = summary_path.name.removesuffix("_timing_summary.json")
    phases = rows(summary_path.with_name(prefix + "_timing.tsv"))
    frames = rows(summary_path.with_name(prefix + "_frames.tsv"))
    pauses = []
    checkpoints = [
        "flip_return_observed_s", "post_flip_policy_end_s",
        "post_flip_commit_end_s", "post_flip_close_event_end_s",
        "transition_finish_s", "run_after_transition_s", "run_iteration_end_s",
    ]
    for phase, following in zip(phases, phases[1:]):
        if phase["phase"] == "view_video":
            continue  # Video playback intentionally occurs after its first flip.
        entry = number(following, "transition_entry_s")
        if entry is None:
            entry = number(following, "transition_enter_s")
        observed = number(phase, "flip_return_observed_s")
        if observed is None or entry is None or entry - observed < 0.005:
            continue
        parts = []
        for start, end in zip(checkpoints, checkpoints[1:]):
            elapsed = difference(phase, end, start)
            if elapsed is not None:
                parts.append({"from": start, "to": end, "seconds": elapsed})
        last = number(phase, "run_iteration_end_s")
        if last is not None:
            parts.append({"from": "run_iteration_end_s", "to": "next_transition_entry_s", "seconds": entry - last})
        pauses.append({
            "phase": phase["phase"], "trial": int(float(phase["trial_index"])),
            "duration_s": number(phase, "actual_duration_s"),
            "duration_error_s": number(phase, "duration_error_s"),
            "post_flip_to_next_transition_s": entry - observed,
            "internal_checkpoints_available": bool(parts), "parts": parts,
            "next_draw_s": difference(following, "draw_end_s", "draw_start_s"),
        })
    video = {}
    for frame in frames:
        if frame["action"] != "1":
            continue
        trial = int(float(frame["trial_index"]))
        item = video.setdefault(trial, {"trial": trial, "scheduled_frames": 0, "dropped_frames": 0, "upload_times": [], "cache_times": []})
        item["scheduled_frames"] += 1
        item["dropped_frames"] += frame["displayed"] == "0"
        for key, start, end in [
            ("upload_times", "upload_start_s", "upload_end_s"),
            ("cache_times", "cache_read_start_s", "cache_read_end_s"),
        ]:
            elapsed = difference(frame, end, start)
            if elapsed is not None:
                item[key].append(elapsed)
    for item in video.values():
        for kind in ["upload", "cache"]:
            values = item.pop(kind + "_times")
            item[kind + "_median_s"] = median(values) if values else None
            item[kind + "_max_s"] = max(values) if values else None
    return {"summary_path": str(summary_path), "summary": summary, "phase_pauses": pauses, "video_trials": list(video.values())}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("summary", nargs="+", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    result = [analyze(path) for path in args.summary]
    data = json.dumps(result, indent=2, ensure_ascii=False, allow_nan=False)
    if args.output:
        args.output.write_text(data, encoding="utf-8")
    else:
        print(data)
