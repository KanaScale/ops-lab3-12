#!/usr/bin/env python3
"""Sample HPA, Deployment and Pod state during an O4 loadgen run."""
import json
import subprocess
import sys
import time
from pathlib import Path


def snapshot():
    raw = subprocess.check_output(
        ["k3s", "kubectl", "get", "hpa,deploy,pods", "-n", "lab3-o4", "-o", "json"],
        timeout=15,
    )
    items = json.loads(raw)["items"]
    row = {"epoch": time.time()}
    for item in items:
        kind = item["kind"]
        status = item.get("status", {})
        if kind == "HorizontalPodAutoscaler":
            row["hpa"] = {
                "desired": status.get("desiredReplicas"),
                "current": status.get("currentReplicas"),
                "metrics": status.get("currentMetrics", []),
                "conditions": status.get("conditions", []),
            }
        elif kind == "Deployment":
            row["deployment"] = {
                "desired": item.get("spec", {}).get("replicas"),
                "replicas": status.get("replicas", 0),
                "ready": status.get("readyReplicas", 0),
                "available": status.get("availableReplicas", 0),
            }
        elif kind == "Pod":
            ready = next((c for c in status.get("conditions", []) if c["type"] == "Ready"), {})
            container = next(iter(status.get("containerStatuses", [])), {})
            row.setdefault("pods", []).append({
                "name": item["metadata"]["name"],
                "created": item["metadata"].get("creationTimestamp"),
                "phase": status.get("phase"),
                "ready": ready.get("status"),
                "ready_transition": ready.get("lastTransitionTime"),
                "started": container.get("state", {}).get("running", {}).get("startedAt"),
                "restarts": container.get("restartCount", 0),
            })
    return row


def main(out, stopfile):
    with Path(out).open("w", buffering=1) as file:
        while not Path(stopfile).exists():
            try:
                file.write(json.dumps(snapshot(), separators=(",", ":")) + "\n")
            except (subprocess.SubprocessError, json.JSONDecodeError) as exc:
                file.write(json.dumps({"epoch": time.time(), "error": str(exc)}) + "\n")
            time.sleep(2)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("usage: o4-watch.py samples.jsonl stopfile")
    main(sys.argv[1], sys.argv[2])
