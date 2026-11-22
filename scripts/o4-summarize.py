#!/usr/bin/env python3
"""Summarize one O4 HPA run from loadgen and Kubernetes samples."""
import csv
import datetime as dt
import json
import re
import sys
from pathlib import Path


def timestamp(value):
    return dt.datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()


def load_rows(path):
    with path.open(newline="") as file:
        return list(csv.DictReader(file))


def main(path):
    run = Path(path)
    start = float((run / "start-epoch.txt").read_text())
    end = float((run / "end-epoch.txt").read_text())
    timeline = load_rows(run / "timeline.csv")
    steps = load_rows(run / "steps.csv")
    samples = [json.loads(line) for line in (run / "samples.jsonl").read_text().splitlines()]
    samples = [s for s in samples if "error" not in s]

    bad = []
    spans = []
    for row in timeline:
        sec = int(row["sec"])
        p99 = float(row["p99_ms"] or 0)
        if int(row["errors"]) > 0 or p99 > 200:
            bad.append(row)
            if not spans or sec > spans[-1][-1] + 1:
                spans.append([sec])
            else:
                spans[-1].append(sec)

    changes = []
    last = None
    for s in samples:
        hpa = s.get("hpa", {})
        deploy = s.get("deployment", {})
        state = (hpa.get("desired"), deploy.get("desired"), deploy.get("ready"))
        if state != last:
            cpu = hpa.get("metrics", [])
            util = None
            if cpu:
                util = cpu[0].get("resource", {}).get("current", {}).get("averageUtilization")
            changes.append((round(s["epoch"] - start, 1), *state, util))
            last = state

    pods = {}
    for s in samples:
        for p in s.get("pods", []):
            entry = pods.setdefault(p["name"], {
                "created": timestamp(p["created"]), "ready": None,
                "last_seen": s["epoch"], "restarts": 0,
            })
            entry["last_seen"] = s["epoch"]
            entry["restarts"] = max(entry["restarts"], p["restarts"])
            if p["ready"] == "True" and p.get("ready_transition"):
                t = timestamp(p["ready_transition"])
                entry["ready"] = t if entry["ready"] is None else min(entry["ready"], t)

    pod_seconds = 0
    for p in pods.values():
        # Last sample still sees the Pod: count to the load end. Otherwise
        # use the last observation as an approximate deletion bound.
        finish = end if p["last_seen"] >= end - 5 else p["last_seen"]
        pod_seconds += max(0, min(finish, end) - max(p["created"], start))

    total = {key: sum(int(row[key]) for row in timeline) for key in ("sent", "ok", "errors", "slow")}
    lines = [
        "# O4 HPA 汇总", "",
        f"负载 {len(timeline)} 秒；发出 {total['sent']}、成功 {total['ok']}、错误 {total['errors']}、慢成功 {total['slow']}；Pod·分钟 {pod_seconds / 60:.1f}。",
        "", "## 缺口", "",
        "| 起 | 止 | 秒数 | 发出 | 错误 | 慢成功 |", "|---:|---:|---:|---:|---:|---:|",
    ]
    for span in spans:
        rows = [row for row in bad if int(row["sec"]) in span]
        lines.append(f"| {span[0]} | {span[-1] + 1} | {len(span)} | {sum(int(r['sent']) for r in rows)} | {sum(int(r['errors']) for r in rows)} | {sum(int(r['slow']) for r in rows)} |")
    lines.extend(["", f"缺口总计 {len(bad)} 秒。", "", "## 阶段", "", "| 阶段 | 目标 RPS | 成功 RPS | 错误 | p99 ms |", "|---:|---:|---:|---:|---:|"])
    for row in steps:
        lines.append(f"| {row['step']} | {row['target_rps']} | {row['ok_rps']} | {int(row['http_err']) + int(row['timeout']) + int(row['net_err'])} | {row['p99_ms']} |")
    lines.extend(["", "## HPA / Deployment 变化（采样精度约 2 秒）", "", "| 秒 | HPA 期望 | Deployment 期望 | Ready | CPU 利用率 % |", "|---:|---:|---:|---:|---:|"])
    for sec, hpa, desired, ready, cpu in changes:
        lines.append(f"| {sec} | {hpa} | {desired} | {ready} | {cpu} |")
    lines.extend(["", "## Pod 生涯", "", "| Pod | 创建秒 | Ready 秒 | 重启 |", "|---|---:|---:|---:|"])
    for name, p in sorted(pods.items(), key=lambda kv: kv[1]["created"]):
        ready = f"{p['ready'] - start:.1f}" if p["ready"] is not None else "-"
        lines.append(f"| {name} | {p['created'] - start:.1f} | {ready} | {p['restarts']} |")
    metrics_files = sorted(run.glob("pod-metrics-*.txt"))
    if metrics_files:
        lines.extend(["", "## Pod 累计业务请求（压测后抓取）", "", "| Pod | 200 | 499 | 503 |", "|---|---:|---:|---:|"])
        for file in metrics_files:
            counters = {code: int(value) for code, value in re.findall(
                r'^http_requests_total\{route="/api/courses/\{id\}",code="([0-9]+)"\} ([0-9]+)$',
                file.read_text(), re.MULTILINE,
            )}
            lines.append(f"| {file.stem.removeprefix('pod-metrics-')} | {counters.get('200', 0)} | {counters.get('499', 0)} | {counters.get('503', 0)} |")
    output = "\n".join(lines) + "\n"
    (run / "summary.md").write_text(output)
    print(output)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: o4-summarize.py runs/o4-hpa")
    main(sys.argv[1])
