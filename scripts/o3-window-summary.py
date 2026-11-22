#!/usr/bin/env python3
"""Summarize matching time windows from the O3 per-second client CSVs."""

import csv
import sys
from pathlib import Path


def main() -> None:
    writer = csv.writer(sys.stdout, lineterminator="\n")
    writer.writerow(["run", "start_sec", "end_sec_exclusive", "sent", "ok", "errors", "slow", "ok_rps", "error_rate"])
    for name in sys.argv[1:]:
        with (Path("runs") / name / "timeline.csv").open(newline="", encoding="utf-8") as handle:
            rows = list(csv.DictReader(handle))
        for start, end in ((50, 135), (135, 150), (150, 200), (151, 200)):
            window = [row for row in rows if start <= int(row["sec"]) < end]
            sent = sum(int(row["sent"]) for row in window)
            ok = sum(int(row["ok"]) for row in window)
            errors = sum(int(row["errors"]) for row in window)
            slow = sum(int(row["slow"]) for row in window)
            writer.writerow([name, start, end, sent, ok, errors, slow, f"{ok / (end - start):.2f}", f"{errors / sent:.4f}"])


if __name__ == "__main__":
    main()
