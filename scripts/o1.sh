#!/usr/bin/env bash
# O1: paired A3 runs with and without the Go soft memory limit.
set -euo pipefail
cd "$(dirname "$0")/.."

die() { echo "O1: $*" >&2; exit 1; }
for tool in curl python3 systemctl systemd-run taskset; do
  command -v "$tool" >/dev/null || die "缺少 $tool"
done
[ -x bin/enrolld ] && [ -x bin/promsteps ] || die "请先 make build test"
[ ! -e runs/o1-control ] && [ ! -e runs/o1-memlimit ] || die "O1 目录已存在，请先检查已有结果；脚本不覆盖结果"
if pgrep -x scaler >/dev/null || pgrep -x loadgen >/dev/null || pgrep -x enrolld >/dev/null; then
  die "实验机上仍有 scaler/loadgen/enrolld，请与组员确认空闲并停止旧实验"
fi
curl -fsS --max-time 3 http://127.0.0.1:9090/-/ready >/dev/null || die "Prometheus 未就绪"
curl -fsS --max-time 3 http://127.0.0.1:9100/metrics >/dev/null || die "node_exporter 未启动"
sudo -v
mkdir -p data
scratch=$(mktemp -d "$PWD/data/o1-XXXXXX")
service_started=0
sampler_pid=""
cleanup() {
  [ -z "$sampler_pid" ] || { kill "$sampler_pid" 2>/dev/null || true; wait "$sampler_pid" 2>/dev/null || true; }
  [ "$service_started" -eq 0 ] || sudo systemctl stop lab3-a.service
}
trap cleanup EXIT

cat > "$scratch/prediction.md" <<'PREDICTION'
# O1 测前预测

保持 A3 的 MemoryMax=200M、MemorySwapMax=0、10/20/30 请求每秒、每阶段 20 秒以及未限制报表并发的条件。对照组 GOMEMLIMIT=off，实验组 170MiB，两组 GOGC=100。

预计软限制会使 Go 更积极地回收垃圾，降低内存峰值，可能推迟或避免原先 20 请求/秒阶段的 OOM。代价可能是更多 GC 及 CPU 开销。高负载下仍需保留正在使用的内存，30 请求/秒仍可能 OOM。无法保证软限制一定防止进程被杀。比较相同负载阶段的成功率、内存峰值、GC 次数和 GC CPU 时间。
PREDICTION
date -Iseconds > "$scratch/prediction-written-at.txt"

cat > "$scratch/sample.py" <<'PY'
import csv
import sys
import time
import urllib.request

names = ['go_gc_cycles_total', 'go_gc_cpu_seconds_total', 'process_cpu_seconds_total',
         'process_resident_memory_bytes', 'cgroup_memory_current_bytes']
with open(sys.argv[1], 'w', newline='') as handle:
    writer = csv.writer(handle)
    writer.writerow(['unix_time'] + names)
    while True:
        try:
            with urllib.request.urlopen('http://127.0.0.1:8081/metrics', timeout=0.4) as response:
                lines = response.read().decode().splitlines()
            values = {}
            for line in lines:
                parts = line.split()
                if len(parts) == 2 and parts[0] in names:
                    values[parts[0]] = parts[1]
            writer.writerow([time.time()] + [values.get(name, '') for name in names])
            handle.flush()
        except Exception:
            pass
        time.sleep(0.5)
PY

for name in o1-control o1-memlimit; do
  limit=off
  [ "$name" != o1-memlimit ] || limit=170MiB
  sudo systemctl reset-failed lab3-a.service 2>/dev/null || true
  start_time=$(date -Iseconds)
  sudo systemd-run --unit=lab3-a \
    -p MemoryMax=200M -p MemorySwapMax=0 \
    --setenv="GOMEMLIMIT=$limit" --setenv=GOGC=100 \
    "$PWD/bin/enrolld" -addr 127.0.0.1:8081 -data "$PWD/data/a"
  service_started=1
  ready=0
  for attempt in {1..20}; do
    if curl -fsS --max-time 1 http://127.0.0.1:8081/config >/dev/null; then ready=1; break; fi
    sleep 1
  done
  [ "$ready" -eq 1 ] || die "服务启动失败"
  # Allow multiple Prometheus scrapes before starting the load.
  sleep 10
  sudo systemctl show lab3-a.service \
    -p Environment -p MemoryMax -p MemorySwapMax -p ExecStart > "$scratch/$name-config.txt"
  python3 "$scratch/sample.py" "$scratch/$name-samples.csv" &
  sampler_pid=$!
  status=0
  GEN_CPUS=0 scripts/run.sh "$name" \
    -url 'http://127.0.0.1:8081/api/report?mb=8&ms=500' \
    -rates 10,20,30 -step 20s || status=$?
  kill "$sampler_pid" 2>/dev/null || true
  wait "$sampler_pid" 2>/dev/null || true
  sampler_pid=""
  [ -d "runs/$name" ] || die "压测未创建结果目录，辅助证据位于 $scratch"
  cp "$scratch/prediction.md" "$scratch/prediction-written-at.txt" "runs/$name/"
  cp "$scratch/$name-config.txt" "runs/$name/service-config.txt"
  cp "$scratch/$name-samples.csv" "runs/$name/runtime-samples.csv"
  echo "$status" > "runs/$name/run-exit-code.txt"
  sudo systemctl show lab3-a.service -p ActiveState -p Result -p ExecMainStatus > "runs/$name/systemd-result.txt"
  sudo journalctl -u lab3-a.service --since "$start_time" --no-pager > "runs/$name/journal.txt"
  cat > "runs/$name/gc-queries.txt" <<'QUERIES'
gc_cycles_observed increase(go_gc_cycles_total{job="enrolld"}[${window}])
gc_cpu_s_per_s rate(go_gc_cpu_seconds_total{job="enrolld"}[${window}])
process_cpu_s_per_s rate(process_cpu_seconds_total{job="enrolld"}[${window}])
QUERIES
  bin/promsteps -steps "runs/$name/steps.csv" -prom http://127.0.0.1:9090 \
    -queries "runs/$name/gc-queries.txt" > "runs/$name/gc.csv"
  sudo systemctl stop lab3-a.service
  service_started=0
  echo "已完成 $name，run.sh 退出码 $status，OOM 与指标证据已保存。"
done
echo "两轮完成。请保留 runs/o1-control 和 runs/o1-memlimit，辅助原件在 $scratch。"
